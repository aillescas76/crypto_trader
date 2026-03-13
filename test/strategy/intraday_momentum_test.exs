defmodule CriptoTrader.Strategy.IntradayMomentumTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.IntradayMomentum

  # Base timestamp: 2024-06-15 00:00:00 UTC
  @base_ms 1_718_409_600_000

  defp ms_for_day_hour(day, hour, quarter \\ 0) do
    @base_ms + day * 86_400_000 + hour * 3_600_000 + quarter * 900_000
  end

  defp event(symbol, day, hour, open, close, quarter \\ 0) do
    %{
      symbol: symbol,
      open_time: ms_for_day_hour(day, hour, quarter),
      candle: %{
        open: to_string(open),
        close: to_string(close),
        high: to_string(max(open, close)),
        low: to_string(min(open, close))
      }
    }
  end

  # Shorthand: same-day event at fixed buy_hour=19, sell_hour=21
  defp ev(symbol, hour, open, close, quarter \\ 0) do
    event(symbol, 10, hour, open, close, quarter)
  end

  # Pre-load state with 10 days of consistent history to establish best_hours.
  # The history is injected directly so tests stay focused on trading logic.
  defp with_best_hours(state, symbol, buy_hour, sell_hour) do
    history = List.duplicate({buy_hour, sell_hour}, 10)

    %{
      state
      | day_history: Map.put(state.day_history, symbol, history),
        best_hours: Map.put(state.best_hours, symbol, {buy_hour, sell_hour})
    }
  end

  describe "new_state/2" do
    test "creates state with defaults" do
      state = IntradayMomentum.new_state(["BTCUSDC"])
      assert state.quote_per_trade == 100.0
      assert state.stop_loss_pct == 0.02
      assert state.trail_pct == 0.003
      assert state.positions == %{}
      assert state.tracking == %{}
      assert state.day_history == %{}
      assert state.best_hours == %{}
    end

    test "accepts keyword options" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"],
          quote_per_trade: 200.0,
          stop_loss_pct: 0.01,
          trail_pct: 0.005
        )

      assert state.quote_per_trade == 200.0
      assert state.stop_loss_pct == 0.01
      assert state.trail_pct == 0.005
    end

    test "legacy numeric arity still works" do
      state = IntradayMomentum.new_state(["BTCUSDC"], 250.0)
      assert state.quote_per_trade == 250.0
    end
  end

  describe "history accumulation" do
    test "does not trade before 10 days of history" do
      state = IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.001)

      # Simulate 9 days: hour 5 is always low, hour 10 is always high
      state =
        Enum.reduce(0..8, state, fn day, s ->
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, 5, 100, 95), s)
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, 10, 98, 105), s)
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, 23, 103, 103), s)
          s
        end)

      assert Map.get(state.best_hours, "BTCUSDC") == {nil, nil}

      # Even at the known buy hour, no trade
      {orders, _} = IntradayMomentum.signal(event("BTCUSDC", 9, 5, 100, 96), state)
      assert orders == []
    end

    test "activates best_hours after 10 days of consistent pattern" do
      state = IntradayMomentum.new_state(["BTCUSDC"])

      # 10 full days: hour 5 always low, hour 10 always high
      state =
        Enum.reduce(0..9, state, fn day, s ->
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, 3, 103, 103), s)
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, 5, 102, 95), s)
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, 10, 97, 108), s)
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, 23, 107, 107), s)
          s
        end)

      # The 10th day (index 10) transition finalises day 9
      {_, state} = IntradayMomentum.signal(event("BTCUSDC", 10, 0, 103, 103), state)

      assert Map.get(state.best_hours, "BTCUSDC") == {5, 10}
    end

    test "does not activate when pattern is inconsistent" do
      state = IntradayMomentum.new_state(["BTCUSDC"])

      # 10 days where low hour is random — no consistent pattern
      low_hours = [2, 5, 8, 3, 7, 1, 4, 6, 9, 0]

      state =
        Enum.reduce(Enum.with_index(low_hours), state, fn {low_h, day}, s ->
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, low_h, 102, 95), s)
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, 20, 97, 108), s)
          {_, s} = IntradayMomentum.signal(event("BTCUSDC", day, 23, 107, 107), s)
          s
        end)

      {_, state} = IntradayMomentum.signal(event("BTCUSDC", 10, 0, 103, 103), state)

      assert Map.get(state.best_hours, "BTCUSDC") == {nil, nil}
    end
  end

  describe "trailing buy" do
    test "tracks low during buy window, buys on bounce" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)
        |> with_best_hours("BTCUSDC", 19, 21)

      # 19:00 q0 — price at 100, starts tracking
      {orders, state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 101, 100.0, 0), state)
      assert orders == []
      assert state.tracking["BTCUSDC"].low == 100.0

      # 19:00 q1 — price drops to 98, updates low
      {orders, state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 100, 98.0, 1), state)
      assert orders == []
      assert state.tracking["BTCUSDC"].low == 98.0

      # 19:00 q2 — price at 98.5, not enough bounce (trigger = 98 * 1.01 = 98.98)
      {orders, state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 98, 98.5, 2), state)
      assert orders == []

      # 19:00 q3 — price at 99.0, above trigger (98.98) — buy!
      {[order], state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 98.5, 99.0, 3), state)
      assert order.side == "BUY"
      assert order.symbol == "BTCUSDC"
      assert Map.has_key?(state.positions, "BTCUSDC")
      refute Map.has_key?(state.tracking, "BTCUSDC")
    end

    test "does not buy if price never bounces enough" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)
        |> with_best_hours("BTCUSDC", 19, 21)

      {[], state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 101, 100, 0), state)
      {[], state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 100, 99, 1), state)
      {[], state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 99, 98, 2), state)
      {[], _state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 98, 97, 3), state)
    end

    test "does not buy if already holding" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)
        |> with_best_hours("BTCUSDC", 19, 21)

      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 100.0, quantity: 1.0}}}

      {orders, _} = IntradayMomentum.signal(ev("BTCUSDC", 19, 101, 99, 0), state)
      assert orders == []
    end
  end

  describe "trailing sell" do
    test "tracks high during sell window, sells on pullback" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)
        |> with_best_hours("BTCUSDC", 19, 21)

      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 99.0, quantity: 1.0}}}

      # 21:00 q0 — price at 101, starts tracking high
      {orders, state} = IntradayMomentum.signal(ev("BTCUSDC", 21, 100, 101.0, 0), state)
      assert orders == []
      assert state.tracking["BTCUSDC"].high == 101.0

      # 21:00 q1 — price rises to 102, updates high
      {orders, state} = IntradayMomentum.signal(ev("BTCUSDC", 21, 101, 102.0, 1), state)
      assert orders == []
      assert state.tracking["BTCUSDC"].high == 102.0

      # 21:00 q2 — price at 101.5, not enough pullback (trigger = 102 * 0.99 = 100.98)
      {orders, state} = IntradayMomentum.signal(ev("BTCUSDC", 21, 102, 101.5, 2), state)
      assert orders == []

      # 21:00 q3 — price at 100.5, below trigger (100.98) — sell!
      {[order], state} = IntradayMomentum.signal(ev("BTCUSDC", 21, 101, 100.5, 3), state)
      assert order.side == "SELL"
      assert order.quantity == 1.0
      refute Map.has_key?(state.positions, "BTCUSDC")
    end

    test "holds through sell window if price keeps rising" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)
        |> with_best_hours("BTCUSDC", 19, 21)

      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 99.0, quantity: 1.0}}}

      {[], state} = IntradayMomentum.signal(ev("BTCUSDC", 21, 100, 101, 0), state)
      {[], state} = IntradayMomentum.signal(ev("BTCUSDC", 21, 101, 102, 1), state)
      {[], state} = IntradayMomentum.signal(ev("BTCUSDC", 21, 102, 103, 2), state)
      {[], _state} = IntradayMomentum.signal(ev("BTCUSDC", 21, 103, 104, 3), state)
    end
  end

  describe "force sell past sell window" do
    test "force sells any remaining position past sell hour" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"])
        |> with_best_hours("BTCUSDC", 19, 21)

      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 99.0, quantity: 1.0}}}

      {[order], state} = IntradayMomentum.signal(ev("BTCUSDC", 22, 103, 104, 0), state)
      assert order.side == "SELL"
      refute Map.has_key?(state.positions, "BTCUSDC")
    end
  end

  describe "stop loss" do
    test "triggers during hold period" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"], stop_loss_pct: 0.01)
        |> with_best_hours("BTCUSDC", 19, 21)

      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 100.0, quantity: 1.0}}}

      # 1.5% drop between windows — stop loss fires
      {[order], state} = IntradayMomentum.signal(ev("BTCUSDC", 20, 99, 98.5, 2), state)
      assert order.side == "SELL"
      refute Map.has_key?(state.positions, "BTCUSDC")
    end

    test "does not trigger on small drop" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"], stop_loss_pct: 0.02)
        |> with_best_hours("BTCUSDC", 19, 21)

      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 100.0, quantity: 1.0}}}

      # 0.5% drop — no stop
      {orders, _} = IntradayMomentum.signal(ev("BTCUSDC", 20, 100, 99.5, 0), state)
      assert orders == []
    end
  end

  describe "quote-based sizing" do
    test "same dollar amount regardless of coin price" do
      state =
        IntradayMomentum.new_state(["BTCUSDC", "ADAUSDC"], quote_per_trade: 100.0, trail_pct: 0.001)
        |> with_best_hours("BTCUSDC", 19, 21)
        |> with_best_hours("ADAUSDC", 19, 21)

      # BTC: track low then bounce
      {[], state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 50_100, 50_000.0, 0), state)
      {[btc_order], state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 50_000, 50_100.0, 1), state)

      # ADA: track low then bounce
      {[], state} = IntradayMomentum.signal(ev("ADAUSDC", 19, 0.51, 0.50, 0), state)
      {[ada_order], _state} = IntradayMomentum.signal(ev("ADAUSDC", 19, 0.50, 0.505, 1), state)

      btc_quote = btc_order.quantity * 50_100.0
      ada_quote = ada_order.quantity * 0.505

      assert_in_delta btc_quote, 100.0, 1.0
      assert_in_delta ada_quote, 100.0, 1.0
    end
  end

  describe "multi-symbol independence" do
    test "tracks and trades each symbol independently" do
      state =
        IntradayMomentum.new_state(["BTCUSDC", "ETHUSDC"], trail_pct: 0.01)
        |> with_best_hours("BTCUSDC", 19, 21)
        |> with_best_hours("ETHUSDC", 19, 21)

      # Both start tracking at 19:00
      {[], state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 101, 100, 0), state)
      {[], state} = IntradayMomentum.signal(ev("ETHUSDC", 19, 51, 50, 0), state)

      assert map_size(state.tracking) == 2

      # BTC bounces and buys, ETH keeps dropping
      {[btc_order], state} = IntradayMomentum.signal(ev("BTCUSDC", 19, 100, 101.5, 1), state)
      {[], state} = IntradayMomentum.signal(ev("ETHUSDC", 19, 50, 49, 1), state)

      assert btc_order.side == "BUY"
      assert Map.has_key?(state.positions, "BTCUSDC")
      refute Map.has_key?(state.positions, "ETHUSDC")
    end
  end

  describe "edge cases" do
    test "ignores events with missing data" do
      state = IntradayMomentum.new_state(["BTCUSDC"])
      {orders, _} = IntradayMomentum.signal(%{}, state)
      assert orders == []
    end

    test "clears tracking outside windows when best_hours is known" do
      state =
        IntradayMomentum.new_state(["BTCUSDC"])
        |> with_best_hours("BTCUSDC", 19, 21)

      state = %{state | tracking: %{"BTCUSDC" => %{low: 100.0, high: 101.0}}}

      {[], state} = IntradayMomentum.signal(ev("BTCUSDC", 15, 100, 101, 0), state)
      assert state.tracking == %{}
    end

    test "no action outside windows when no history yet" do
      state = IntradayMomentum.new_state(["BTCUSDC"])
      state = %{state | tracking: %{"BTCUSDC" => %{low: 100.0, high: 101.0}}}

      # Without best_hours, signal returns immediately with no state mutation
      {orders, _state} = IntradayMomentum.signal(ev("BTCUSDC", 15, 100, 101, 0), state)
      assert orders == []
    end
  end
end
