defmodule CriptoTrader.Strategy.CycleAthTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.CycleAth

  defp event(symbol, close) do
    %{
      symbol: symbol,
      open_time: 1_718_409_600_000,
      candle: %{close: to_string(close)}
    }
  end

  defp feed(state, symbol, closes) do
    Enum.reduce(closes, state, fn close, acc ->
      {_orders, new_state} = CycleAth.signal(event(symbol, close), acc)
      new_state
    end)
  end

  describe "new_state/2" do
    test "builds defaults" do
      state = CycleAth.new_state(["BTCUSDC"])
      assert state.multiplier == 2.0
      assert state.trail_pct == 0.20
      assert state.quote_per_trade == 1000.0
      assert state.ath == %{}
      assert state.prev_ath == %{}
      assert state.positions == %{}
    end

    test "accepts custom options" do
      state = CycleAth.new_state(["BTCUSDC"], multiplier: 3.0, trail_pct: 0.15, quote_per_trade: 500.0)
      assert state.multiplier == 3.0
      assert state.trail_pct == 0.15
      assert state.quote_per_trade == 500.0
    end
  end

  describe "ATH tracking" do
    test "does not buy with only one ATH (no prev_ath)" do
      state = CycleAth.new_state(["BTCUSDC"])
      # Only one ATH established — no prev_ath yet
      {orders, _state} = CycleAth.signal(event("BTCUSDC", 100.0), state)
      assert orders == []
    end

    test "does not buy when price is above prev_ath" do
      state = CycleAth.new_state(["BTCUSDC"])
      # ATH 1: 100, ATH 2: 200, price: 150 (above prev_ath=100, below current ath=200 — no buy)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      {orders, _state} = CycleAth.signal(event("BTCUSDC", 150.0), state)
      assert orders == []
    end

    test "buys when price crosses below prev_ath" do
      state = CycleAth.new_state(["BTCUSDC"], quote_per_trade: 1000.0)
      # ATH 1: 100, ATH 2: 200
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      # Price drops below prev_ath (100.0)
      {[order], state} = CycleAth.signal(event("BTCUSDC", 90.0), state)
      assert order.side == "BUY"
      assert order.symbol == "BTCUSDC"
      assert_in_delta order.quantity, 1000.0 / 90.0, 0.0001
      assert state.positions["BTCUSDC"].entry_price == 90.0
    end
  end

  describe "trailing stop exit" do
    test "transitions to trailing when multiplier is hit" do
      state = CycleAth.new_state(["BTCUSDC"], multiplier: 2.0, trail_pct: 0.20, quote_per_trade: 1000.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      # Buy at 90
      {[_buy], state} = CycleAth.signal(event("BTCUSDC", 90.0), state)
      # Price hits 2x (180) — should activate trailing, no sell yet
      {orders, state} = CycleAth.signal(event("BTCUSDC", 180.0), state)
      assert orders == []
      assert Map.get(state.phase, "BTCUSDC") == :trailing
      assert Map.get(state.trail_high, "BTCUSDC") == 180.0
    end

    test "does not sell before multiplier is hit" do
      state = CycleAth.new_state(["BTCUSDC"], multiplier: 2.0, quote_per_trade: 1000.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      {[_buy], state} = CycleAth.signal(event("BTCUSDC", 90.0), state)
      # Price rises but below 2x
      {orders, _state} = CycleAth.signal(event("BTCUSDC", 170.0), state)
      assert orders == []
    end

    test "sells when trailing stop triggered" do
      state = CycleAth.new_state(["BTCUSDC"], multiplier: 2.0, trail_pct: 0.20, quote_per_trade: 1000.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      {[_buy], state} = CycleAth.signal(event("BTCUSDC", 90.0), state)
      # Hit multiplier, activate trailing
      {[], state} = CycleAth.signal(event("BTCUSDC", 180.0), state)
      # Price rises to 300
      {[], state} = CycleAth.signal(event("BTCUSDC", 300.0), state)
      # Drop 20%+ from high (300 * 0.80 = 240 → sell below 240)
      {[order], state} = CycleAth.signal(event("BTCUSDC", 239.0), state)
      assert order.side == "SELL"
      refute Map.has_key?(state.positions, "BTCUSDC")
      assert Map.get(state.phase, "BTCUSDC") == :watching
    end

    test "does not sell while still within trailing window" do
      state = CycleAth.new_state(["BTCUSDC"], multiplier: 2.0, trail_pct: 0.20, quote_per_trade: 1000.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      {[_buy], state} = CycleAth.signal(event("BTCUSDC", 90.0), state)
      {[], state} = CycleAth.signal(event("BTCUSDC", 180.0), state)
      # Small dip, not 20% from high
      {orders, _state} = CycleAth.signal(event("BTCUSDC", 160.0), state)
      assert orders == []
    end
  end

  describe "multi-symbol independence" do
    test "tracks two symbols independently" do
      state = CycleAth.new_state(["BTCUSDC", "ETHUSDC"], quote_per_trade: 1000.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      state = feed(state, "ETHUSDC", [50.0, 100.0])
      {[btc_order], state} = CycleAth.signal(event("BTCUSDC", 90.0), state)
      {[eth_order], _state} = CycleAth.signal(event("ETHUSDC", 45.0), state)
      assert btc_order.symbol == "BTCUSDC"
      assert eth_order.symbol == "ETHUSDC"
    end
  end

  describe "edge cases" do
    test "ignores malformed events" do
      state = CycleAth.new_state(["BTCUSDC"])
      {orders, ^state} = CycleAth.signal(%{}, state)
      assert orders == []
    end

    test "ignores zero close" do
      state = CycleAth.new_state(["BTCUSDC"])
      {orders, _state} = CycleAth.signal(event("BTCUSDC", 0.0), state)
      assert orders == []
    end
  end
end
