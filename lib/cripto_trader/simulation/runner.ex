defmodule CriptoTrader.Simulation.Runner do
  @moduledoc """
  Deterministic simulation runner for Binance Spot-oriented strategy execution.

  The runner replays historical candles across one or more symbols in
  chronological order and feeds each event to one strategy function.
  Orders are routed through an injectable executor (default: OrderManager)
  so risk controls can remain part of the execution path. Simulation order
  execution defaults to `:paper` mode unless explicitly overridden.
  """

  require Logger

  alias CriptoTrader.OrderManager

  @type candle :: map()
  @type order_request :: map() | keyword()
  @type strategy_state :: term()

  @type simulation_event :: %{
          symbol: String.t(),
          interval: String.t() | nil,
          open_time: non_neg_integer(),
          emitted_at: non_neg_integer(),
          candle: map()
        }

  @type strategy_response ::
          {[order_request()], strategy_state()} | {:ok, [order_request()], strategy_state()}
  @type strategy_fun :: (simulation_event(), strategy_state() -> strategy_response())
  @type order_executor :: (map(), keyword() -> {:ok, map()} | {:error, term()})

  @type run_opts :: [
          {:symbols, [String.t()]},
          {:interval, String.t()},
          {:candles_by_symbol, %{String.t() => [candle()]}},
          {:trading_mode, :paper | :live | String.t()},
          {:speed, pos_integer()},
          {:strategy_fun, strategy_fun()},
          {:strategy_state, strategy_state()},
          {:order_executor, order_executor()},
          {:order_executor_opts, keyword()},
          {:event_handler, (simulation_event() -> term())},
          {:log_strategy_decisions, boolean()},
          {:include_trade_log, boolean()},
          {:initial_balance, number()},
          {:start_emitted_at, non_neg_integer()},
          {:include_equity_curve, boolean()}
        ]

  @epsilon 1.0e-12
  @default_initial_balance 10_000.0
  @volatile_order_response_keys [
    "clientOrderId",
    "client_order_id",
    "orderId",
    "order_id",
    "origClientOrderId",
    "orig_client_order_id",
    "time",
    "transactTime",
    "transact_time",
    "updateTime",
    "update_time",
    "workingTime",
    "working_time"
  ]

  @spec run(run_opts()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    with {:ok, symbols} <- validate_symbols(Keyword.get(opts, :symbols, [])),
         {:ok, candles_by_symbol} <-
           validate_candles_by_symbol(Keyword.get(opts, :candles_by_symbol, %{}), symbols),
         {:ok, speed} <- validate_speed(Keyword.get(opts, :speed, 1)),
         {:ok, initial_balance} <-
           validate_initial_balance(Keyword.get(opts, :initial_balance, @default_initial_balance)),
         {:ok, event_queue, first_open_time} <- build_event_queue(symbols, candles_by_symbol),
         {:ok, strategy_fun} <-
           validate_strategy_fun(Keyword.get(opts, :strategy_fun, &default_strategy/2)),
         {:ok, order_executor} <-
           validate_order_executor(Keyword.get(opts, :order_executor, &default_order_executor/2)),
         {:ok, trading_mode} <- validate_trading_mode(Keyword.get(opts, :trading_mode, :paper)),
         {:ok, event_handler} <- validate_event_handler(Keyword.get(opts, :event_handler)),
         {:ok, log_strategy_decisions} <-
           validate_log_strategy_decisions(Keyword.get(opts, :log_strategy_decisions, false)),
         {:ok, include_trade_log} <-
           validate_include_trade_log(Keyword.get(opts, :include_trade_log, true)) do
      include_equity_curve = Keyword.get(opts, :include_equity_curve, false)
      start_emitted_at = Keyword.get(opts, :start_emitted_at, first_open_time)
      interval = Keyword.get(opts, :interval)
      strategy_state = Keyword.get(opts, :strategy_state, %{})

      order_executor_opts =
        opts
        |> Keyword.get(:order_executor_opts, [])
        |> Keyword.put_new(:trading_mode, trading_mode)

      initial_state = new_state(initial_balance, include_equity_curve)

      process_opts = %{
        interval: interval,
        start_emitted_at: start_emitted_at,
        first_open_time: first_open_time,
        speed: speed,
        strategy_fun: strategy_fun,
        order_executor: order_executor,
        order_executor_opts: order_executor_opts,
        event_handler: event_handler,
        log_strategy_decisions: log_strategy_decisions,
        include_trade_log: include_trade_log
      }

      process_events(event_queue, initial_state, strategy_state, process_opts)
      |> case do
        {:ok, state, _strategy_state} -> {:ok, finalize(state)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp default_strategy(_event, state), do: {[], state}

  defp default_order_executor(params, opts), do: OrderManager.place_order(params, opts)

  defp validate_symbols(symbols) when is_list(symbols) do
    symbols =
      symbols
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if symbols == [], do: {:error, :symbols_required}, else: {:ok, symbols}
  end

  defp validate_symbols(_), do: {:error, :symbols_required}

  defp validate_candles_by_symbol(candles_by_symbol, symbols) when is_map(candles_by_symbol) do
    Enum.reduce_while(symbols, {:ok, %{}}, fn symbol, {:ok, acc} ->
      case Map.fetch(candles_by_symbol, symbol) do
        {:ok, candles} when is_list(candles) ->
          with {:ok, normalized} <- normalize_candles(symbol, candles) do
            {:cont, {:ok, Map.put(acc, symbol, normalized)}}
          end

        {:ok, _invalid} ->
          {:halt, {:error, {:invalid_candle_list, symbol}}}

        :error ->
          {:halt, {:error, {:missing_candles_for_symbol, symbol}}}
      end
    end)
  end

  defp validate_candles_by_symbol(_, _), do: {:error, :candles_by_symbol_required}

  defp normalize_candles(symbol, candles) do
    candles
    |> Enum.reduce_while({:ok, [], nil, true}, fn candle, {:ok, acc, prev_open_time, sorted?} ->
      case normalize_candle(candle) do
        {:ok, normalized} ->
          next_sorted? =
            sorted? and
              (is_nil(prev_open_time) or normalized.open_time >= prev_open_time)

          {:cont, {:ok, [normalized | acc], normalized.open_time, next_sorted?}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_candle, symbol, reason}}}
      end
    end)
    |> case do
      {:ok, normalized_rev, _prev_open_time, true} ->
        {:ok, Enum.reverse(normalized_rev)}

      {:ok, normalized_rev, _prev_open_time, false} ->
        sorted =
          normalized_rev
          |> Enum.reverse()
          |> Enum.with_index()
          |> Enum.sort_by(fn {candle, original_idx} -> {candle.open_time, original_idx} end)
          |> Enum.map(&elem(&1, 0))

        {:ok, sorted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_candle(candle) when is_map(candle) do
    with {:ok, open_time} <- parse_non_neg_int(field(candle, :open_time, "open_time")),
         {:ok, close} <- parse_positive_number(field(candle, :close, "close")) do
      {:ok, %{open_time: open_time, close: close, raw: candle}}
    end
  end

  defp normalize_candle(_), do: {:error, :candle_must_be_map}

  defp validate_speed(speed) when is_integer(speed) and speed > 0, do: {:ok, speed}
  defp validate_speed(_), do: {:error, :invalid_speed}

  defp validate_initial_balance(balance) when is_number(balance) and balance > 0,
    do: {:ok, balance * 1.0}

  defp validate_initial_balance(_), do: {:error, :invalid_initial_balance}

  defp validate_strategy_fun(strategy_fun) when is_function(strategy_fun, 2),
    do: {:ok, strategy_fun}

  defp validate_strategy_fun(_), do: {:error, :invalid_strategy_fun}

  defp validate_order_executor(order_executor) when is_function(order_executor, 2),
    do: {:ok, order_executor}

  defp validate_order_executor(_), do: {:error, :invalid_order_executor}

  defp validate_trading_mode(mode) when mode in [:paper, :live], do: {:ok, mode}

  defp validate_trading_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "paper" -> {:ok, :paper}
      "live" -> {:ok, :live}
      _ -> {:error, :invalid_trading_mode}
    end
  end

  defp validate_trading_mode(_), do: {:error, :invalid_trading_mode}

  defp validate_event_handler(nil), do: {:ok, nil}

  defp validate_event_handler(event_handler) when is_function(event_handler, 1),
    do: {:ok, event_handler}

  defp validate_event_handler(_), do: {:error, :invalid_event_handler}

  defp validate_log_strategy_decisions(value) when is_boolean(value), do: {:ok, value}
  defp validate_log_strategy_decisions(_), do: {:error, :invalid_log_strategy_decisions}

  defp validate_include_trade_log(value) when is_boolean(value), do: {:ok, value}
  defp validate_include_trade_log(_), do: {:error, :invalid_include_trade_log}

  defp build_event_queue(symbols, candles_by_symbol) do
    queue =
      symbols
      |> Enum.with_index()
      |> Enum.reduce(:gb_trees.empty(), fn {symbol, symbol_idx}, acc ->
        enqueue_symbol_candles(acc, symbol, symbol_idx, Map.fetch!(candles_by_symbol, symbol))
      end)

    if :gb_trees.is_empty(queue) do
      {:error, :empty_timeline}
    else
      {{first_open_time, _, _}, _} = :gb_trees.smallest(queue)
      {:ok, queue, first_open_time}
    end
  end

  defp enqueue_symbol_candles(queue, _symbol, _symbol_idx, []), do: queue

  defp enqueue_symbol_candles(queue, symbol, symbol_idx, [first | rest]) do
    key = {first.open_time, symbol_idx, 0}
    value = {symbol, symbol_idx, 0, first, rest}
    :gb_trees.insert(key, value, queue)
  end

  defp process_events(queue, state, strategy_state, process_opts) do
    if :gb_trees.is_empty(queue) do
      {:ok, state, strategy_state}
    else
      {{_open_time, symbol_idx, candle_idx}, {symbol, _, _, candle, rest}, next_queue} =
        :gb_trees.take_smallest(queue)

      queue_with_next =
        case rest do
          [next_candle | remaining] ->
            next_key = {next_candle.open_time, symbol_idx, candle_idx + 1}
            next_value = {symbol, symbol_idx, candle_idx + 1, next_candle, remaining}
            :gb_trees.insert(next_key, next_value, next_queue)

          [] ->
            next_queue
        end

      event =
        build_event(
          symbol,
          candle,
          process_opts.interval,
          process_opts.start_emitted_at,
          process_opts.first_open_time,
          process_opts.speed
        )

      with {:ok, orders, next_strategy_state} <-
             evaluate_strategy(process_opts.strategy_fun, event, strategy_state),
           :ok <- log_strategy_decision(event, orders, process_opts.log_strategy_decisions),
           {:ok, updated_state} <-
             execute_orders(
               orders,
               event,
               state,
               process_opts.order_executor,
               process_opts.order_executor_opts,
               process_opts.include_trade_log
             ),
           {:ok, post_event_state} <-
             update_event_state(updated_state, event, process_opts.event_handler) do
        process_events(queue_with_next, post_event_state, next_strategy_state, process_opts)
      else
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_event(symbol, candle, interval, start_emitted_at, first_open_time, speed) do
    elapsed_ms = candle.open_time - first_open_time

    emitted_at =
      start_emitted_at +
        if(elapsed_ms <= 0, do: 0, else: div(elapsed_ms, speed))

    %{
      symbol: symbol,
      interval: interval,
      open_time: candle.open_time,
      emitted_at: emitted_at,
      candle: Map.put(candle.raw, :close, candle.close)
    }
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

  defp execute_orders(
         [],
         _event,
         state,
         _order_executor,
         _order_executor_opts,
         _include_trade_log
       ),
       do: {:ok, state}

  defp execute_orders(
         orders,
         event,
         state,
         order_executor,
         order_executor_opts,
         include_trade_log
       ) do
    Enum.reduce_while(orders, {:ok, state}, fn order_request, {:ok, acc_state} ->
      case execute_order(
             order_request,
             event,
             acc_state,
             order_executor,
             order_executor_opts,
             include_trade_log
           ) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_order(
         order_request,
         event,
         state,
         order_executor,
         order_executor_opts,
         include_trade_log
       ) do
    with {:ok, normalized_order} <- normalize_order(order_request, event),
         :ok <- validate_spot_position(normalized_order, state),
         {:ok, updated_state} <-
           dispatch_order(
             normalized_order,
             event,
             state,
             order_executor,
             order_executor_opts,
             include_trade_log
           ) do
      {:ok, updated_state}
    else
      {:error, reason} ->
        {:ok, reject_order(state, event, order_request, reason, include_trade_log)}

      {:reject, reason} ->
        {:ok, reject_order(state, event, order_request, reason, include_trade_log)}
    end
  end

  defp normalize_order(order_request, event) do
    params =
      case order_request do
        %{} = map -> map
        list when is_list(list) -> Enum.into(list, %{})
        _ -> %{}
      end

    with {:ok, side} <- parse_side(field(params, :side, "side")),
         {:ok, quantity} <- parse_positive_number(field(params, :quantity, "quantity") || 1.0),
         {:ok, price} <-
           parse_positive_number(
             field(params, :price, "price") || field(event.candle, :close, "close")
           ),
         symbol <- field(params, :symbol, "symbol") || event.symbol,
         true <- is_binary(symbol) do
      {:ok,
       %{
         symbol: symbol,
         side: side,
         quantity: quantity,
         price: price,
         type: normalize_type(field(params, :type, "type"))
       }}
    else
      false -> {:error, :invalid_order_symbol}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp validate_spot_position(_normalized_order, _state), do: :ok

  defp dispatch_order(
         order,
         event,
         state,
         order_executor,
         order_executor_opts,
         include_trade_log
       ) do
    order_quote = order.quantity * order.price
    drawdown_pct = current_drawdown_pct(state)

    context =
      order_executor_opts
      |> Keyword.get(:context, %{})
      |> Map.new()
      |> Map.merge(%{order_quote: order_quote, drawdown_pct: drawdown_pct})

    executor_opts = Keyword.put(order_executor_opts, :context, context)

    case order_executor.(
           Map.take(order, [:symbol, :side, :type, :quantity, :price]),
           executor_opts
         ) do
      {:ok, response} -> {:ok, apply_fill(state, event, order, response, include_trade_log)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_order_executor_response, other}}
    end
  end

  defp apply_fill(state, event, order, response, include_trade_log) do
    updated_state =
      case order.side do
        "BUY" ->
          apply_buy_fill(state, order.symbol, order.quantity, order.price)

        "SELL" ->
          apply_sell_fill(state, order.symbol, order.quantity, order.price)
      end

    trade_log_rev =
      if include_trade_log do
        log_entry = %{
          status: "filled",
          symbol: order.symbol,
          side: order.side,
          quantity: order.quantity,
          price: order.price,
          open_time: event.open_time,
          emitted_at: event.emitted_at,
          order_response: sanitize_order_response(response)
        }

        [log_entry | updated_state.trade_log_rev]
      else
        updated_state.trade_log_rev
      end

    %{
      updated_state
      | accepted_orders: updated_state.accepted_orders + 1,
        trade_log_rev: trade_log_rev
    }
  end

  defp apply_buy_fill(state, symbol, quantity, price) do
    position = Map.get(state.positions, symbol, %{qty: 0.0, avg_price: 0.0})

    total_qty = position.qty + quantity

    avg_price =
      if total_qty <= @epsilon do
        0.0
      else
        (position.qty * position.avg_price + quantity * price) / total_qty
      end

    %{
      state
      | cash: state.cash - quantity * price,
        positions: Map.put(state.positions, symbol, %{qty: total_qty, avg_price: avg_price})
    }
  end

  defp apply_sell_fill(state, symbol, quantity, price) do
    position = Map.get(state.positions, symbol, %{qty: 0.0, avg_price: 0.0})
    realized = (price - position.avg_price) * quantity
    remaining_qty = position.qty - quantity

    positions =
      if remaining_qty <= @epsilon do
        Map.delete(state.positions, symbol)
      else
        Map.put(state.positions, symbol, %{qty: remaining_qty, avg_price: position.avg_price})
      end

    %{
      state
      | cash: state.cash + quantity * price,
        positions: positions,
        realized_pnl: state.realized_pnl + realized,
        closed_trades: state.closed_trades + 1,
        winning_trades: state.winning_trades + if(realized > 0.0, do: 1, else: 0)
    }
  end

  defp reject_order(state, event, order_request, reason, include_trade_log) do
    trade_log_rev =
      if include_trade_log do
        log_entry = %{
          status: "rejected",
          reason: reason,
          open_time: event.open_time,
          emitted_at: event.emitted_at,
          order_request: order_request
        }

        [log_entry | state.trade_log_rev]
      else
        state.trade_log_rev
      end

    %{
      state
      | rejected_orders: state.rejected_orders + 1,
        trade_log_rev: trade_log_rev
    }
  end

  defp update_event_state(state, event, event_handler) do
    with :ok <- maybe_emit_event(event_handler, event) do
      last_prices = Map.put(state.last_prices, event.symbol, field(event.candle, :close, "close"))
      equity = equity(%{state | last_prices: last_prices})
      peak_equity = max(state.peak_equity, equity)

      drawdown =
        if peak_equity <= 0.0 do
          0.0
        else
          max(state.max_drawdown_pct, (peak_equity - equity) / peak_equity)
        end

      curve =
        if state.include_equity_curve do
          [%{open_time: event.open_time, equity: Float.round(equity, 8)} | state.equity_curve_rev]
        else
          state.equity_curve_rev
        end

      {:ok,
       %{
         state
         | last_prices: last_prices,
           peak_equity: peak_equity,
           max_drawdown_pct: drawdown,
           equity_curve_rev: curve,
           events_processed: state.events_processed + 1
       }}
    end
  end

  defp log_strategy_decision(_event, _orders, false), do: :ok

  defp log_strategy_decision(event, orders, true) do
    Logger.debug(fn ->
      payload = %{
        event: "strategy_decision",
        symbol: event.symbol,
        interval: event.interval,
        open_time: event.open_time,
        emitted_at: event.emitted_at,
        orders: length(orders)
      }

      "simulation_event " <> Jason.encode!(payload)
    end)

    :ok
  end

  defp maybe_emit_event(nil, _event), do: :ok

  defp maybe_emit_event(event_handler, event) do
    event_handler.(event)
    :ok
  rescue
    error ->
      {:error, {:event_handler_failed, error}}
  end

  defp finalize(state) do
    final_equity = equity(state)

    summary =
      %{
        pnl: Float.round(final_equity - state.initial_balance, 8),
        win_rate: Float.round(win_rate(state), 8),
        max_drawdown_pct: Float.round(state.max_drawdown_pct, 8),
        trades: state.accepted_orders,
        rejected_orders: state.rejected_orders,
        closed_trades: state.closed_trades,
        events_processed: state.events_processed
      }

    %{
      trade_log: Enum.reverse(state.trade_log_rev),
      summary: summary,
      equity_curve: Enum.reverse(state.equity_curve_rev)
    }
  end

  defp win_rate(%{closed_trades: 0}), do: 0.0
  defp win_rate(state), do: state.winning_trades / state.closed_trades

  defp equity(state) do
    position_value =
      Enum.reduce(state.positions, 0.0, fn {symbol, %{qty: qty, avg_price: avg_price}}, acc ->
        mark_price = Map.get(state.last_prices, symbol, avg_price)
        acc + qty * mark_price
      end)

    state.cash + position_value
  end

  defp current_drawdown_pct(state) do
    current_equity = equity(state)

    if state.peak_equity <= 0.0 do
      0.0
    else
      max(0.0, (state.peak_equity - current_equity) / state.peak_equity)
    end
  end

  defp new_state(initial_balance, include_equity_curve) do
    %{
      initial_balance: initial_balance,
      cash: initial_balance,
      positions: %{},
      last_prices: %{},
      peak_equity: initial_balance,
      max_drawdown_pct: 0.0,
      accepted_orders: 0,
      rejected_orders: 0,
      closed_trades: 0,
      winning_trades: 0,
      realized_pnl: 0.0,
      trade_log_rev: [],
      equity_curve_rev: [],
      include_equity_curve: include_equity_curve,
      events_processed: 0
    }
  end

  defp parse_side(value) when is_binary(value) do
    case String.upcase(String.trim(value)) do
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
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> {:error, :invalid_open_time}
    end
  end

  defp parse_non_neg_int(_), do: {:error, :invalid_open_time}

  defp parse_positive_number(value) when is_number(value) and value > 0, do: {:ok, value * 1.0}

  defp parse_positive_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {num, ""} when num > 0.0 -> {:ok, num}
      _ -> {:error, :invalid_number}
    end
  end

  defp parse_positive_number(_), do: {:error, :invalid_number}

  defp sanitize_order_response(response) when is_map(response) do
    response
    |> Enum.reject(fn {key, _value} -> volatile_response_key?(key) end)
    |> Map.new()
  end

  defp sanitize_order_response(response), do: response

  defp volatile_response_key?(key) when is_binary(key),
    do: key in @volatile_order_response_keys

  defp volatile_response_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> volatile_response_key?()

  defp volatile_response_key?(_key), do: false

  defp field(map, atom_key, string_key) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end
end
