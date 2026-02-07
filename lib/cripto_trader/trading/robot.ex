defmodule CriptoTrader.Trading.Robot do
  @moduledoc """
  Polling-based Binance Spot trading runner.

  The robot fetches candles per symbol, evaluates one strategy function per
  candle event, and routes resulting orders through an injected executor
  (default: `CriptoTrader.OrderManager`). It defaults to paper mode and uses
  finite iterations for deterministic runs in tests and CI.
  """

  require Logger

  alias CriptoTrader.MarketData.Candles
  alias CriptoTrader.OrderManager

  @default_iterations 1
  @default_limit 1
  @default_poll_ms 0
  @default_initial_balance 10_000.0
  @epsilon 1.0e-12

  @type candle :: map()
  @type order_request :: map() | keyword()
  @type strategy_state :: term()
  @type strategy_response ::
          {[order_request()], strategy_state()} | {:ok, [order_request()], strategy_state()}
  @type strategy_fun :: (map(), strategy_state() -> strategy_response())
  @type candles_fetch_fun :: (keyword() -> {:ok, %{String.t() => [candle()]}} | {:error, term()})
  @type order_executor :: (map(), keyword() -> {:ok, map()} | {:error, term()})

  @type run_opts :: [
          {:symbols, [String.t()]},
          {:interval, String.t()},
          {:iterations, pos_integer()},
          {:poll_ms, non_neg_integer()},
          {:limit, pos_integer()},
          {:initial_balance, number()},
          {:start_time, non_neg_integer() | nil},
          {:end_time, non_neg_integer() | nil},
          {:trading_mode, :paper | :live | String.t()},
          {:strategy_fun, strategy_fun()},
          {:strategy_state, strategy_state()},
          {:candles_fetch_fun, candles_fetch_fun()},
          {:order_executor, order_executor()},
          {:order_executor_opts, keyword()},
          {:sleep_fun, (non_neg_integer() -> term())},
          {:include_trade_log, boolean()}
        ]

  @spec run(run_opts()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    with {:ok, symbols} <- validate_symbols(Keyword.get(opts, :symbols, [])),
         {:ok, interval} <- validate_interval(Keyword.get(opts, :interval)),
         {:ok, iterations} <-
           validate_pos_int(Keyword.get(opts, :iterations, @default_iterations)),
         {:ok, poll_ms} <- validate_non_neg_int(Keyword.get(opts, :poll_ms, @default_poll_ms)),
         {:ok, limit} <- validate_pos_int(Keyword.get(opts, :limit, @default_limit)),
         {:ok, initial_balance} <-
           validate_positive_number(Keyword.get(opts, :initial_balance, @default_initial_balance)),
         {:ok, start_time, end_time} <-
           validate_range(Keyword.get(opts, :start_time), Keyword.get(opts, :end_time)),
         {:ok, trading_mode} <- validate_trading_mode(Keyword.get(opts, :trading_mode, :paper)),
         {:ok, strategy_fun} <-
           validate_strategy_fun(Keyword.get(opts, :strategy_fun, &default_strategy/2)),
         {:ok, candles_fetch_fun} <-
           validate_candles_fetch_fun(Keyword.get(opts, :candles_fetch_fun, &Candles.fetch/1)),
         {:ok, order_executor} <-
           validate_order_executor(Keyword.get(opts, :order_executor, &default_order_executor/2)),
         {:ok, sleep_fun} <- validate_sleep_fun(Keyword.get(opts, :sleep_fun, &:timer.sleep/1)) do
      include_trade_log = Keyword.get(opts, :include_trade_log, true)
      strategy_state = Keyword.get(opts, :strategy_state, %{})

      order_executor_opts =
        opts
        |> Keyword.get(:order_executor_opts, [])
        |> Keyword.put_new(:trading_mode, trading_mode)

      initial_state = %{
        initial_balance: initial_balance,
        cash: initial_balance,
        positions: %{},
        last_prices: %{},
        peak_equity: initial_balance,
        max_drawdown_pct: 0.0,
        events_processed: 0,
        accepted_orders: 0,
        rejected_orders: 0,
        trade_log_rev: [],
        last_open_time_by_symbol: %{}
      }

      loop_opts = %{
        symbols: symbols,
        interval: interval,
        iterations: iterations,
        poll_ms: poll_ms,
        limit: limit,
        start_time: start_time,
        end_time: end_time,
        strategy_fun: strategy_fun,
        candles_fetch_fun: candles_fetch_fun,
        order_executor: order_executor,
        order_executor_opts: order_executor_opts,
        sleep_fun: sleep_fun,
        include_trade_log: include_trade_log,
        trading_mode: trading_mode
      }

      run_iterations(1, strategy_state, initial_state, loop_opts)
      |> case do
        {:ok, final_strategy_state, final_state} ->
          {:ok, finalize(final_strategy_state, final_state, loop_opts)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp default_strategy(_event, state), do: {[], state}
  defp default_order_executor(params, opts), do: OrderManager.place_order(params, opts)

  defp run_iterations(iteration, strategy_state, state, %{iterations: total_iterations})
       when iteration > total_iterations do
    {:ok, strategy_state, state}
  end

  defp run_iterations(iteration, strategy_state, state, loop_opts) do
    with {:ok, next_strategy_state, next_state} <-
           run_iteration(strategy_state, state, loop_opts),
         :ok <- maybe_sleep(iteration, loop_opts) do
      run_iterations(iteration + 1, next_strategy_state, next_state, loop_opts)
    end
  end

  defp run_iteration(strategy_state, state, loop_opts) do
    with {:ok, candles_by_symbol} <- fetch_iteration_candles(state, loop_opts),
         {:ok, normalized_by_symbol} <-
           normalize_iteration_candles(loop_opts.symbols, candles_by_symbol, state) do
      process_iteration_symbols(
        loop_opts.symbols,
        normalized_by_symbol,
        strategy_state,
        state,
        loop_opts
      )
    end
  end

  defp fetch_iteration_candles(state, loop_opts) do
    max_concurrency = max(length(loop_opts.symbols), 1)

    loop_opts.symbols
    |> Task.async_stream(
      fn symbol ->
        {symbol, fetch_symbol_candles(symbol, state, loop_opts)}
      end,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {symbol, {:ok, candles}}}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, symbol, candles)}}

      {:ok, {_symbol, {:error, reason}}}, _acc ->
        {:halt, {:error, reason}}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:market_data_fetch_task_failed, reason}}}
    end)
  end

  defp normalize_iteration_candles(symbols, candles_by_symbol, state) do
    Enum.reduce_while(symbols, {:ok, %{}}, fn symbol, {:ok, acc} ->
      candles = Map.fetch!(candles_by_symbol, symbol)

      case normalize_symbol_candles(symbol, candles, state) do
        {:ok, normalized} ->
          {:cont, {:ok, Map.put(acc, symbol, normalized)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp process_iteration_symbols(symbols, candles_by_symbol, strategy_state, state, loop_opts) do
    Enum.reduce_while(symbols, {:ok, strategy_state, state}, fn symbol,
                                                                {:ok, strategy_acc, state_acc} ->
      normalized = Map.fetch!(candles_by_symbol, symbol)

      case process_symbol_events(symbol, normalized, strategy_acc, state_acc, loop_opts) do
        {:ok, next_strategy_state, next_state} ->
          {:cont, {:ok, next_strategy_state, next_state}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_symbol_candles(symbol, state, loop_opts) do
    fetch_opts =
      [
        symbols: [symbol],
        interval: loop_opts.interval,
        limit: loop_opts.limit,
        start_time: symbol_start_time(symbol, state, loop_opts),
        end_time: loop_opts.end_time
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case loop_opts.candles_fetch_fun.(fetch_opts) do
      {:ok, %{^symbol => candles}} when is_list(candles) ->
        {:ok, candles}

      {:ok, _payload} ->
        {:error, {:invalid_candle_payload, symbol}}

      {:error, reason} ->
        {:error, {:market_data, symbol, reason}}
    end
  end

  defp process_symbol_events(symbol, candles, strategy_state, state, loop_opts) do
    Enum.reduce_while(candles, {:ok, strategy_state, state}, fn candle,
                                                                {:ok, strategy_acc, state_acc} ->
      event = build_event(symbol, loop_opts.interval, candle)
      priced_state = mark_market_price(state_acc, symbol, candle.close)

      with {:ok, orders, next_strategy_state} <-
             evaluate_strategy(loop_opts.strategy_fun, event, strategy_acc),
           :ok <- log_strategy_decision(event, orders, loop_opts.trading_mode),
           {:ok, next_state} <-
             execute_orders(orders, event, priced_state, loop_opts.order_executor, loop_opts) do
        updated_state = %{
          refresh_risk_state(next_state)
          | events_processed: next_state.events_processed + 1,
            last_open_time_by_symbol:
              Map.put(next_state.last_open_time_by_symbol, symbol, candle.open_time)
        }

        {:cont, {:ok, next_strategy_state, updated_state}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_orders([], _event, state, _order_executor, _loop_opts), do: {:ok, state}

  defp execute_orders(orders, event, state, order_executor, loop_opts) do
    Enum.reduce_while(orders, {:ok, state}, fn order_request, {:ok, state_acc} ->
      case execute_order(order_request, event, state_acc, order_executor, loop_opts) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_order(order_request, event, state, order_executor, loop_opts) do
    with {:ok, order} <- normalize_order(order_request, event.symbol, event.candle),
         :ok <- validate_spot_position(order, state),
         {:ok, executor_opts} <- build_executor_opts(order, state, loop_opts.order_executor_opts) do
      case order_executor.(
             Map.take(order, [:symbol, :side, :type, :quantity, :price]),
             executor_opts
           ) do
        {:ok, response} ->
          {:ok, mark_order_accepted(state, event, order, response, loop_opts.include_trade_log)}

        {:error, reason} ->
          {:ok,
           mark_order_rejected(state, event, order_request, reason, loop_opts.include_trade_log)}

        other ->
          {:error, {:invalid_order_executor_response, other}}
      end
    else
      {:reject, reason} ->
        {:ok,
         mark_order_rejected(state, event, order_request, reason, loop_opts.include_trade_log)}

      {:error, reason} ->
        {:ok,
         mark_order_rejected(state, event, order_request, reason, loop_opts.include_trade_log)}
    end
  end

  defp evaluate_strategy(strategy_fun, event, strategy_state) do
    case strategy_fun.(event, strategy_state) do
      {orders, next_strategy_state} when is_list(orders) ->
        {:ok, orders, next_strategy_state}

      {:ok, orders, next_strategy_state} when is_list(orders) ->
        {:ok, orders, next_strategy_state}

      other ->
        {:error, {:invalid_strategy_response, other}}
    end
  end

  defp normalize_symbol_candles(symbol, candles, state) do
    last_open_time = Map.get(state.last_open_time_by_symbol, symbol)

    candles
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {candle, index}, {:ok, acc} ->
      case normalize_candle(candle) do
        {:ok, normalized} -> {:cont, {:ok, [{normalized, index} | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_candle, symbol, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        filtered =
          normalized
          |> Enum.filter(fn candle ->
            {normalized_candle, _index} = candle
            is_nil(last_open_time) or normalized_candle.open_time > last_open_time
          end)
          |> Enum.sort_by(fn {normalized_candle, index} ->
            {normalized_candle.open_time, index}
          end)
          |> Enum.map(&elem(&1, 0))

        {:ok, filtered}

      error ->
        error
    end
  end

  defp normalize_candle(candle) when is_map(candle) do
    with {:ok, open_time} <- parse_non_neg_int(field(candle, :open_time, "open_time")),
         {:ok, close} <- parse_positive_number(field(candle, :close, "close")) do
      {:ok, %{open_time: open_time, close: close, raw: candle}}
    end
  end

  defp normalize_candle(_), do: {:error, :candle_must_be_map}

  defp normalize_order(order_request, default_symbol, candle) do
    params =
      case order_request do
        %{} = map -> map
        list when is_list(list) -> Enum.into(list, %{})
        _ -> %{}
      end

    symbol = field(params, :symbol, "symbol") || default_symbol

    if is_binary(symbol) do
      with {:ok, side} <- parse_side(field(params, :side, "side")),
           {:ok, quantity} <- parse_positive_number(field(params, :quantity, "quantity") || 1.0),
           {:ok, price} <-
             parse_positive_number(
               field(params, :price, "price") || field(candle, :close, "close")
             ) do
        {:ok,
         %{
           symbol: symbol,
           side: side,
           type: normalize_type(field(params, :type, "type")),
           quantity: quantity,
           price: price
         }}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_order_symbol}
    end
  end

  defp build_executor_opts(order, state, order_executor_opts) do
    context =
      order_executor_opts
      |> Keyword.get(:context, %{})
      |> to_map()
      |> Map.put(:order_quote, order.quantity * order.price)
      |> Map.put(:drawdown_pct, current_drawdown_pct(state))

    {:ok, Keyword.put(order_executor_opts, :context, context)}
  end

  defp mark_order_accepted(state, event, order, response, include_trade_log) do
    log_entry = %{
      status: "filled",
      symbol: order.symbol,
      side: order.side,
      quantity: order.quantity,
      price: order.price,
      open_time: event.open_time,
      order_response: response
    }

    %{
      apply_fill(state, order)
      | accepted_orders: state.accepted_orders + 1,
        trade_log_rev: maybe_append_log(state.trade_log_rev, log_entry, include_trade_log)
    }
  end

  defp mark_order_rejected(state, event, order_request, reason, include_trade_log) do
    log_entry = %{
      status: "rejected",
      reason: reason,
      open_time: event.open_time,
      order_request: order_request
    }

    %{
      state
      | rejected_orders: state.rejected_orders + 1,
        trade_log_rev: maybe_append_log(state.trade_log_rev, log_entry, include_trade_log)
    }
  end

  defp maybe_append_log(log, _entry, false), do: log
  defp maybe_append_log(log, entry, true), do: [entry | log]

  defp validate_spot_position(%{side: "SELL", symbol: symbol, quantity: quantity}, state) do
    position_qty =
      state.positions
      |> Map.get(symbol, %{qty: 0.0})
      |> Map.get(:qty, 0.0)

    if position_qty + @epsilon < quantity do
      {:reject, :insufficient_position}
    else
      :ok
    end
  end

  defp validate_spot_position(_order, _state), do: :ok

  defp log_strategy_decision(event, orders, trading_mode) do
    Logger.info(fn ->
      payload = %{
        event: "strategy_decision",
        runner: "trading_robot",
        symbol: event.symbol,
        interval: event.interval,
        open_time: event.open_time,
        orders: length(orders),
        trading_mode: output_mode(trading_mode)
      }

      "trading_event " <> Jason.encode!(payload)
    end)

    :ok
  end

  defp build_event(symbol, interval, candle) do
    %{
      symbol: symbol,
      interval: interval,
      open_time: candle.open_time,
      candle: Map.put(candle.raw, :close, candle.close)
    }
  end

  defp maybe_sleep(_iteration, %{poll_ms: 0}), do: :ok

  defp maybe_sleep(iteration, %{iterations: iterations}) when iteration >= iterations, do: :ok

  defp maybe_sleep(_iteration, %{poll_ms: poll_ms, sleep_fun: sleep_fun}) do
    _ = sleep_fun.(poll_ms)
    :ok
  end

  defp symbol_start_time(symbol, state, loop_opts) do
    case Map.get(state.last_open_time_by_symbol, symbol) do
      open_time when is_integer(open_time) -> open_time + 1
      nil -> loop_opts.start_time
    end
  end

  defp finalize(final_strategy_state, state, loop_opts) do
    final_equity = equity(state)

    %{
      symbols: loop_opts.symbols,
      interval: loop_opts.interval,
      mode: output_mode(loop_opts.trading_mode),
      iterations: loop_opts.iterations,
      summary: %{
        events_processed: state.events_processed,
        accepted_orders: state.accepted_orders,
        rejected_orders: state.rejected_orders,
        pnl: Float.round(final_equity - state.initial_balance, 8),
        max_drawdown_pct: Float.round(state.max_drawdown_pct, 8)
      },
      last_open_time_by_symbol: state.last_open_time_by_symbol,
      strategy_state: final_strategy_state,
      trade_log: Enum.reverse(state.trade_log_rev)
    }
  end

  defp validate_symbols(symbols) when is_list(symbols) do
    symbols =
      symbols
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.upcase/1)
      |> Enum.uniq()

    if symbols == [], do: {:error, :symbols_required}, else: {:ok, symbols}
  end

  defp validate_symbols(_), do: {:error, :symbols_required}

  defp validate_interval(interval) when is_binary(interval) do
    interval = String.trim(interval)
    if interval == "", do: {:error, :interval_required}, else: {:ok, interval}
  end

  defp validate_interval(_), do: {:error, :interval_required}

  defp validate_pos_int(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_pos_int(_), do: {:error, :invalid_positive_integer}

  defp validate_non_neg_int(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp validate_non_neg_int(_), do: {:error, :invalid_non_neg_integer}
  defp validate_positive_number(value) when is_number(value) and value > 0, do: {:ok, value * 1.0}
  defp validate_positive_number(_), do: {:error, :invalid_positive_number}

  defp validate_range(nil, nil), do: {:ok, nil, nil}
  defp validate_range(start_time, nil) when is_integer(start_time), do: {:ok, start_time, nil}
  defp validate_range(nil, end_time) when is_integer(end_time), do: {:ok, nil, end_time}

  defp validate_range(start_time, end_time)
       when is_integer(start_time) and is_integer(end_time) and start_time <= end_time,
       do: {:ok, start_time, end_time}

  defp validate_range(_start_time, _end_time), do: {:error, :invalid_time_range}

  defp validate_trading_mode(mode) when mode in [:paper, :live], do: {:ok, mode}

  defp validate_trading_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "paper" -> {:ok, :paper}
      "live" -> {:ok, :live}
      _ -> {:error, :invalid_trading_mode}
    end
  end

  defp validate_trading_mode(_), do: {:error, :invalid_trading_mode}

  defp validate_strategy_fun(strategy_fun) when is_function(strategy_fun, 2),
    do: {:ok, strategy_fun}

  defp validate_strategy_fun(_), do: {:error, :invalid_strategy_fun}

  defp validate_candles_fetch_fun(candles_fetch_fun) when is_function(candles_fetch_fun, 1),
    do: {:ok, candles_fetch_fun}

  defp validate_candles_fetch_fun(_), do: {:error, :invalid_candles_fetch_fun}

  defp validate_order_executor(order_executor) when is_function(order_executor, 2),
    do: {:ok, order_executor}

  defp validate_order_executor(_), do: {:error, :invalid_order_executor}

  defp validate_sleep_fun(sleep_fun) when is_function(sleep_fun, 1), do: {:ok, sleep_fun}
  defp validate_sleep_fun(_), do: {:error, :invalid_sleep_fun}

  defp parse_side(value) when is_binary(value) do
    case value |> String.trim() |> String.upcase() do
      "BUY" -> {:ok, "BUY"}
      "SELL" -> {:ok, "SELL"}
      _ -> {:error, :invalid_order_side}
    end
  end

  defp parse_side(value) when is_atom(value), do: value |> Atom.to_string() |> parse_side()
  defp parse_side(_), do: {:error, :invalid_order_side}

  defp normalize_type(nil), do: "MARKET"
  defp normalize_type(type) when is_atom(type), do: type |> Atom.to_string() |> String.upcase()
  defp normalize_type(type) when is_binary(type), do: type |> String.trim() |> String.upcase()
  defp normalize_type(_), do: "MARKET"

  defp parse_non_neg_int(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_non_neg_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, :invalid_open_time}
    end
  end

  defp parse_non_neg_int(_), do: {:error, :invalid_open_time}

  defp parse_positive_number(value) when is_number(value) and value > 0, do: {:ok, value * 1.0}

  defp parse_positive_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} when number > 0.0 -> {:ok, number}
      _ -> {:error, :invalid_number}
    end
  end

  defp parse_positive_number(_), do: {:error, :invalid_number}

  defp output_mode(:paper), do: "paper"
  defp output_mode(:live), do: "live"

  defp mark_market_price(state, symbol, price) do
    state
    |> Map.put(:last_prices, Map.put(state.last_prices, symbol, price))
    |> refresh_risk_state()
  end

  defp refresh_risk_state(state) do
    current_equity = equity(state)
    peak_equity = max(state.peak_equity, current_equity)

    drawdown =
      if peak_equity <= 0.0 do
        0.0
      else
        max(state.max_drawdown_pct, (peak_equity - current_equity) / peak_equity)
      end

    %{state | peak_equity: peak_equity, max_drawdown_pct: drawdown}
  end

  defp current_drawdown_pct(state) do
    current_equity = equity(state)

    if state.peak_equity <= 0.0 do
      0.0
    else
      max(0.0, (state.peak_equity - current_equity) / state.peak_equity)
    end
  end

  defp equity(state) do
    position_value =
      Enum.reduce(state.positions, 0.0, fn {symbol, %{qty: qty, avg_price: avg_price}}, acc ->
        mark_price = Map.get(state.last_prices, symbol, avg_price)
        acc + qty * mark_price
      end)

    state.cash + position_value
  end

  defp apply_fill(state, %{side: "BUY"} = order) do
    position = Map.get(state.positions, order.symbol, %{qty: 0.0, avg_price: 0.0})
    total_qty = position.qty + order.quantity

    avg_price =
      if total_qty <= @epsilon do
        0.0
      else
        (position.qty * position.avg_price + order.quantity * order.price) / total_qty
      end

    %{
      state
      | cash: state.cash - order.quantity * order.price,
        positions: Map.put(state.positions, order.symbol, %{qty: total_qty, avg_price: avg_price})
    }
  end

  defp apply_fill(state, %{side: "SELL"} = order) do
    position = Map.get(state.positions, order.symbol, %{qty: 0.0, avg_price: 0.0})
    remaining_qty = position.qty - order.quantity

    positions =
      if remaining_qty <= @epsilon do
        Map.delete(state.positions, order.symbol)
      else
        Map.put(state.positions, order.symbol, %{
          qty: remaining_qty,
          avg_price: position.avg_price
        })
      end

    %{
      state
      | cash: state.cash + order.quantity * order.price,
        positions: positions
    }
  end

  defp to_map(value) when is_map(value), do: value
  defp to_map(value) when is_list(value), do: Enum.into(value, %{})
  defp to_map(_), do: %{}

  defp field(map, atom_key, string_key) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end
end
