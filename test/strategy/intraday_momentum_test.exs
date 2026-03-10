defmodule CriptoTrader.Strategy.IntradayMomentumTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.IntradayMomentum

  defp ms_for_hour(hour, quarter \\ 0) do
    # 2024-06-15 base date + hour + quarter (0-3 for 15m intervals)
    base = 1_718_409_600_000
    base + hour * 3_600_000 + quarter * 900_000
  end

  defp event(symbol, hour, open, close, quarter \\ 0) do
    %{
      symbol: symbol,
      open_time: ms_for_hour(hour, quarter),
      candle: %{
        open: to_string(open),
        close: to_string(close),
        high: to_string(max(open, close)),
        low: to_string(min(open, close))
      }
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

  describe "trailing buy (19:00-20:00 UTC)" do
    test "tracks low during buy window, buys on bounce" do
      state = IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)

      # 19:00 q0 — price at 100, starts tracking
      {orders, state} = IntradayMomentum.signal(event("BTCUSDC", 19, 101, 100.0, 0), state)
      assert orders == []
      assert state.tracking["BTCUSDC"].low == 100.0

      # 19:00 q1 — price drops to 98, updates low
      {orders, state} = IntradayMomentum.signal(event("BTCUSDC", 19, 100, 98.0, 1), state)
      assert orders == []
      assert state.tracking["BTCUSDC"].low == 98.0

      # 19:00 q2 — price at 98.5, not enough bounce (trigger = 98 * 1.01 = 98.98)
      {orders, state} = IntradayMomentum.signal(event("BTCUSDC", 19, 98, 98.5, 2), state)
      assert orders == []

      # 19:00 q3 — price at 99.0, above trigger (98.98) — buy!
      {[order], state} = IntradayMomentum.signal(event("BTCUSDC", 19, 98.5, 99.0, 3), state)
      assert order.side == "BUY"
      assert order.symbol == "BTCUSDC"
      assert Map.has_key?(state.positions, "BTCUSDC")
      refute Map.has_key?(state.tracking, "BTCUSDC")
    end

    test "does not buy if price never bounces enough" do
      state = IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)

      # Steady decline through buy window
      {[], state} = IntradayMomentum.signal(event("BTCUSDC", 19, 101, 100, 0), state)
      {[], state} = IntradayMomentum.signal(event("BTCUSDC", 19, 100, 99, 1), state)
      {[], state} = IntradayMomentum.signal(event("BTCUSDC", 19, 99, 98, 2), state)
      {[], _state} = IntradayMomentum.signal(event("BTCUSDC", 19, 98, 97, 3), state)
    end

    test "does not buy if already holding" do
      state = IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 100.0, quantity: 1.0}}}

      {orders, _} = IntradayMomentum.signal(event("BTCUSDC", 19, 101, 99, 0), state)
      assert orders == []
    end
  end

  describe "trailing sell (21:00-22:00 UTC)" do
    test "tracks high during sell window, sells on pullback" do
      state = IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 99.0, quantity: 1.0}}}

      # 21:00 q0 — price at 101, starts tracking high
      {orders, state} = IntradayMomentum.signal(event("BTCUSDC", 21, 100, 101.0, 0), state)
      assert orders == []
      assert state.tracking["BTCUSDC"].high == 101.0

      # 21:00 q1 — price rises to 102, updates high
      {orders, state} = IntradayMomentum.signal(event("BTCUSDC", 21, 101, 102.0, 1), state)
      assert orders == []
      assert state.tracking["BTCUSDC"].high == 102.0

      # 21:00 q2 — price at 101.5, not enough pullback (trigger = 102 * 0.99 = 100.98)
      {orders, state} = IntradayMomentum.signal(event("BTCUSDC", 21, 102, 101.5, 2), state)
      assert orders == []

      # 21:00 q3 — price at 100.5, below trigger (100.98) — sell!
      {[order], state} = IntradayMomentum.signal(event("BTCUSDC", 21, 101, 100.5, 3), state)
      assert order.side == "SELL"
      assert order.quantity == 1.0
      refute Map.has_key?(state.positions, "BTCUSDC")
    end

    test "holds through sell window if price keeps rising" do
      state = IntradayMomentum.new_state(["BTCUSDC"], trail_pct: 0.01)
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 99.0, quantity: 1.0}}}

      {[], state} = IntradayMomentum.signal(event("BTCUSDC", 21, 100, 101, 0), state)
      {[], state} = IntradayMomentum.signal(event("BTCUSDC", 21, 101, 102, 1), state)
      {[], state} = IntradayMomentum.signal(event("BTCUSDC", 21, 102, 103, 2), state)
      {[], _state} = IntradayMomentum.signal(event("BTCUSDC", 21, 103, 104, 3), state)
    end
  end

  describe "force sell at 22:00" do
    test "force sells any remaining position past sell window" do
      state = IntradayMomentum.new_state(["BTCUSDC"])
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 99.0, quantity: 1.0}}}

      {[order], state} = IntradayMomentum.signal(event("BTCUSDC", 22, 103, 104, 0), state)
      assert order.side == "SELL"
      refute Map.has_key?(state.positions, "BTCUSDC")
    end
  end

  describe "stop loss" do
    test "triggers during hold period" do
      state = IntradayMomentum.new_state(["BTCUSDC"], stop_loss_pct: 0.01)
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 100.0, quantity: 1.0}}}

      # 1.5% drop at 20:30
      {[order], state} = IntradayMomentum.signal(event("BTCUSDC", 20, 99, 98.5, 2), state)
      assert order.side == "SELL"
      refute Map.has_key?(state.positions, "BTCUSDC")
    end

    test "does not trigger on small drop" do
      state = IntradayMomentum.new_state(["BTCUSDC"], stop_loss_pct: 0.02)
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 100.0, quantity: 1.0}}}

      # 0.5% drop
      {orders, _} = IntradayMomentum.signal(event("BTCUSDC", 20, 100, 99.5, 0), state)
      assert orders == []
    end
  end

  describe "quote-based sizing" do
    test "same dollar amount regardless of coin price" do
      state = IntradayMomentum.new_state(["BTCUSDC", "ADAUSDC"], quote_per_trade: 100.0, trail_pct: 0.001)

      # BTC: track low then bounce
      {[], state} = IntradayMomentum.signal(event("BTCUSDC", 19, 50_100, 50_000.0, 0), state)
      {[btc_order], state} = IntradayMomentum.signal(event("BTCUSDC", 19, 50_000, 50_100.0, 1), state)

      # ADA: track low then bounce
      {[], state} = IntradayMomentum.signal(event("ADAUSDC", 19, 0.51, 0.50, 0), state)
      {[ada_order], _state} = IntradayMomentum.signal(event("ADAUSDC", 19, 0.50, 0.505, 1), state)

      btc_quote = btc_order.quantity * 50_100.0
      ada_quote = ada_order.quantity * 0.505

      assert_in_delta btc_quote, 100.0, 1.0
      assert_in_delta ada_quote, 100.0, 1.0
    end
  end

  describe "multi-symbol independence" do
    test "tracks and trades each symbol independently" do
      state = IntradayMomentum.new_state(["BTCUSDC", "ETHUSDC"], trail_pct: 0.01)

      # Both start tracking at 19:00
      {[], state} = IntradayMomentum.signal(event("BTCUSDC", 19, 101, 100, 0), state)
      {[], state} = IntradayMomentum.signal(event("ETHUSDC", 19, 51, 50, 0), state)

      assert map_size(state.tracking) == 2

      # BTC bounces and buys, ETH keeps dropping
      {[btc_order], state} = IntradayMomentum.signal(event("BTCUSDC", 19, 100, 101.5, 1), state)
      {[], state} = IntradayMomentum.signal(event("ETHUSDC", 19, 50, 49, 1), state)

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

    test "clears tracking outside windows" do
      state = IntradayMomentum.new_state(["BTCUSDC"])
      state = %{state | tracking: %{"BTCUSDC" => %{low: 100.0, high: 101.0}}}

      {[], state} = IntradayMomentum.signal(event("BTCUSDC", 15, 100, 101, 0), state)
      assert state.tracking == %{}
    end
  end
end
