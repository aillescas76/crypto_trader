defmodule CriptoTrader.LiveSim.Manager do
  @moduledoc """
  GenServer that maintains live paper-trading state for N registered strategies.

  State per strategy:
  - balance / positions / pending_orders / filled_orders / realized_pnl
  - strategy_state (opaque term owned by the strategy module)
  - last_signals: %{symbol => order_count}

  Strategies are persisted to priv/live_simulation/strategies.json so they
  survive server restarts (positions/balance reset on restart by design).
  """

  use GenServer
  require Logger

  alias CriptoTrader.LiveSim.OrderFill

  @strategies_file "priv/live_simulation/strategies.json"
  @max_fills 50

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def get_symbols, do: GenServer.call(__MODULE__, :get_symbols)
  def add_strategy(spec), do: GenServer.call(__MODULE__, {:add_strategy, spec})
  def remove_strategy(id), do: GenServer.call(__MODULE__, {:remove_strategy, id})
  def reset_strategy(id), do: GenServer.call(__MODULE__, {:reset_strategy, id})
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  # ── Init ────────────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    File.mkdir_p!(Path.dirname(@strategies_file))
    {:ok, %{strategies: load_strategies(), last_prices: %{}}}
  end

  # ── Calls ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:get_symbols, _from, state) do
    symbols =
      state.strategies
      |> Enum.flat_map(fn {_id, s} -> s.symbols end)
      |> Enum.uniq()

    {:reply, symbols, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:add_strategy, spec}, _from, state) do
    module = resolve_module(spec["module"])

    if is_nil(module) or not function_exported?(module, :signal, 2) do
      {:reply, {:error, :bad_module}, state}
    else
      id = gen_id("strat")
      symbols = parse_symbols(spec["symbols"])
      initial_balance = parse_float(spec["initial_balance"] || 1000.0)
      params = parse_params(spec["params"])
      entry = build_entry(id, module, spec["module"], spec["label"], symbols, initial_balance, params)

      new_state = %{state | strategies: Map.put(state.strategies, id, entry)}
      persist_strategies(new_state)
      refresh_stream(new_state)
      {:reply, {:ok, id}, new_state}
    end
  end

  def handle_call({:remove_strategy, id}, _from, state) do
    new_state = %{state | strategies: Map.delete(state.strategies, id)}
    persist_strategies(new_state)
    refresh_stream(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:reset_strategy, id}, _from, state) do
    case Map.fetch(state.strategies, id) do
      {:ok, s} ->
        params = parse_params(s.saved_params)
        reset = %{s |
          balance: s.initial_balance,
          strategy_state: apply(s.module, :new_state, [s.symbols, params]),
          positions: %{},
          pending_orders: [],
          filled_orders: [],
          realized_pnl: 0.0,
          last_signals: %{}
        }
        {:reply, :ok, %{state | strategies: Map.put(state.strategies, id, reset)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ── Casts ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:candle, event}, state) do
    symbol = event.symbol
    close = get_candle_float(event.candle, :close)

    new_strategies =
      Enum.reduce(state.strategies, state.strategies, fn {id, s}, acc ->
        if symbol in s.symbols do
          Map.put(acc, id, process_candle(s, event))
        else
          acc
        end
      end)

    new_state = %{state |
      strategies: new_strategies,
      last_prices: Map.put(state.last_prices, symbol, close)
    }

    Phoenix.PubSub.broadcast(CriptoTrader.PubSub, "live_sim:updates", {:update, build_snapshot(new_state)})

    candle_map =
      Map.merge(event.candle, %{
        symbol: event.symbol,
        interval: "15m",
        open_time: event.open_time
      })

    Task.start(fn ->
      case CriptoTrader.CandleDB.insert_candles([candle_map]) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("CandleDB write failed: #{inspect(reason)}")
      end
    end)

    {:noreply, new_state}
  end

  # ── Strategy processing ─────────────────────────────────────────────────────

  defp process_candle(s, event) do
    symbol = event.symbol
    candle = event.candle

    # 1. Separate pending orders into filled and still-pending for this symbol
    {still_pending, fills} =
      Enum.reduce(s.pending_orders, {[], []}, fn order, {p_acc, f_acc} ->
        if Map.get(order, :symbol) == symbol do
          case OrderFill.try_fill(order, candle) do
            {:filled, fill_price} ->
              fill_record = order |> Map.put(:fill_price, fill_price) |> Map.put(:filled_at, iso_now())
              {p_acc, [fill_record | f_acc]}

            :pending ->
              {[order | p_acc], f_acc}
          end
        else
          {[order | p_acc], f_acc}
        end
      end)

    # 2. Apply all fills to balance/positions
    s_after_fills =
      fills
      |> Enum.reduce(
        %{s | pending_orders: Enum.reverse(still_pending)},
        fn fill, s_acc -> apply_fill(s_acc, fill, fill.fill_price) end
      )
      |> then(fn s_acc ->
        %{s_acc | filled_orders: (fills ++ s_acc.filled_orders) |> Enum.take(@max_fills)}
      end)

    # 3. Call strategy signal
    {new_orders, new_strategy_state} =
      try do
        s_after_fills.module.signal(event, s_after_fills.strategy_state)
      rescue
        e ->
          Logger.error("Strategy #{s_after_fills.label} signal error: #{Exception.message(e)}")
          {[], s_after_fills.strategy_state}
      end

    # 4. Stamp and append new orders
    stamped =
      Enum.map(new_orders, fn o ->
        m = if is_map(o), do: o, else: Map.new(o)
        m |> Map.put_new(:id, gen_id("ord")) |> Map.put_new(:type, "MARKET") |> Map.put_new(:queued_at, iso_now())
      end)

    %{s_after_fills |
      strategy_state: new_strategy_state,
      pending_orders: s_after_fills.pending_orders ++ stamped,
      last_signals: Map.put(s_after_fills.last_signals, symbol, length(new_orders))
    }
  end

  defp apply_fill(s, order, fill_price) do
    qty = parse_float(Map.get(order, :quantity))
    symbol = Map.get(order, :symbol)
    side = Map.get(order, :side, "")

    case side do
      "BUY" ->
        cost = fill_price * qty
        existing = Map.get(s.positions, symbol, %{qty: 0.0, entry_price: fill_price})
        total_qty = existing.qty + qty
        avg = if total_qty > 0, do: (existing.entry_price * existing.qty + fill_price * qty) / total_qty, else: fill_price
        %{s |
          balance: s.balance - cost,
          positions: Map.put(s.positions, symbol, %{qty: total_qty, entry_price: avg})
        }

      "SELL" ->
        existing = Map.get(s.positions, symbol, %{qty: 0.0, entry_price: fill_price})
        sell_qty = min(qty, max(0.0, existing.qty))
        proceeds = fill_price * sell_qty
        pnl = (fill_price - existing.entry_price) * sell_qty
        new_qty = existing.qty - sell_qty

        new_positions =
          if new_qty < 1.0e-10 do
            Map.delete(s.positions, symbol)
          else
            Map.put(s.positions, symbol, %{existing | qty: new_qty})
          end

        %{s |
          balance: s.balance + proceeds,
          positions: new_positions,
          realized_pnl: s.realized_pnl + pnl
        }

      _ ->
        s
    end
  end

  # ── Snapshot ────────────────────────────────────────────────────────────────

  defp build_snapshot(state) do
    strategies =
      Enum.map(state.strategies, fn {_id, s} ->
        unrealized_pnl =
          Enum.reduce(s.positions, 0.0, fn {sym, pos}, acc ->
            last = Map.get(state.last_prices, sym, pos.entry_price)
            acc + (last - pos.entry_price) * pos.qty
          end)

        equity =
          s.balance +
            Enum.reduce(s.positions, 0.0, fn {sym, pos}, acc ->
              last = Map.get(state.last_prices, sym, pos.entry_price)
              acc + last * pos.qty
            end)

        equity_return_pct =
          if s.initial_balance > 0,
            do: (equity - s.initial_balance) / s.initial_balance * 100.0,
            else: 0.0

        %{
          id: s.id,
          label: s.label,
          module: s.module_str,
          symbols: s.symbols,
          initial_balance: s.initial_balance,
          balance: s.balance,
          equity: equity,
          equity_return_pct: equity_return_pct,
          realized_pnl: s.realized_pnl,
          unrealized_pnl: unrealized_pnl,
          positions: s.positions,
          pending_orders: s.pending_orders,
          filled_orders: Enum.take(s.filled_orders, 10),
          last_signals: s.last_signals
        }
      end)

    %{strategies: strategies, last_prices: state.last_prices, updated_at: iso_now()}
  end

  # ── Persistence ─────────────────────────────────────────────────────────────

  defp load_strategies do
    case File.read(@strategies_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) ->
            list
            |> Enum.map(fn spec ->
              module = resolve_module(spec["module"])

              if module && function_exported?(module, :signal, 2) do
                id = spec["id"] || gen_id("strat")
                symbols = parse_symbols(spec["symbols"])
                initial_balance = parse_float(spec["initial_balance"] || 1000.0)
                params = parse_params(spec["params"])
                {id, build_entry(id, module, spec["module"], spec["label"], symbols, initial_balance, params)}
              else
                Logger.warning("LiveSim: skipping unknown module '#{spec["module"]}'")
                nil
              end
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.into(%{})

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp persist_strategies(state) do
    list =
      Enum.map(state.strategies, fn {_id, s} ->
        %{
          "id" => s.id,
          "module" => s.module_str,
          "label" => s.label,
          "symbols" => s.symbols,
          "initial_balance" => s.initial_balance,
          "params" => s.saved_params || %{}
        }
      end)

    File.write!(@strategies_file, Jason.encode!(list, pretty: true))
  end

  defp build_entry(id, module, module_str, label, symbols, initial_balance, params) do
    %{
      id: id,
      module: module,
      module_str: module_str,
      label: label || module_str,
      symbols: symbols,
      initial_balance: initial_balance,
      saved_params: %{},
      balance: initial_balance,
      strategy_state: apply(module, :new_state, [symbols, params]),
      positions: %{},
      pending_orders: [],
      filled_orders: [],
      realized_pnl: 0.0,
      last_signals: %{}
    }
  end

  defp refresh_stream(state) do
    symbols =
      state.strategies
      |> Enum.flat_map(fn {_id, s} -> s.symbols end)
      |> Enum.uniq()

    CriptoTrader.LiveSim.BinanceStream.update_symbols(symbols)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp resolve_module(str) when is_binary(str) do
    try do
      mod = String.to_existing_atom("Elixir.#{str}")
      if Code.ensure_loaded?(mod), do: mod, else: nil
    rescue
      _ -> nil
    end
  end

  defp resolve_module(_), do: nil

  defp parse_symbols(list) when is_list(list), do: list

  defp parse_symbols(str) when is_binary(str) do
    str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_symbols(_), do: []

  defp parse_params(params) when is_map(params) do
    Enum.reduce(params, [], fn {k, v}, acc ->
      try do
        [{String.to_existing_atom(k), v} | acc]
      rescue
        _ -> acc
      end
    end)
  end

  defp parse_params(_), do: []

  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v * 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(_), do: 0.0

  defp get_candle_float(candle, key) do
    parse_float(Map.get(candle, key) || Map.get(candle, Atom.to_string(key)))
  end

  defp gen_id(prefix) do
    "#{prefix}-#{:erlang.system_time(:millisecond)}-#{:rand.uniform(9999)}"
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
