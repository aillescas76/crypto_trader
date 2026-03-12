defmodule CriptoTrader.Strategy.CycleDcaTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.CycleDca

  defp event(symbol, close) do
    %{
      symbol: symbol,
      open_time: 1_718_409_600_000,
      candle: %{close: to_string(close)}
    }
  end

  defp feed(state, symbol, closes) do
    Enum.reduce(closes, state, fn close, acc ->
      {_orders, new_state} = CycleDca.signal(event(symbol, close), acc)
      new_state
    end)
  end

  describe "new_state/2" do
    test "builds defaults" do
      state = CycleDca.new_state(["BTCUSDC"])
      assert state.multiplier == 2.0
      assert state.trail_pct == 0.20
      assert state.quote_per_trade == 1000.0
      assert state.dca_levels == [1.0, 0.85, 0.70]
    end

    test "accepts custom dca_levels" do
      state = CycleDca.new_state(["BTCUSDC"], dca_levels: [1.0, 0.80], multiplier: 3.0)
      assert state.dca_levels == [1.0, 0.80]
      assert state.multiplier == 3.0
    end
  end

  describe "DCA entries" do
    test "first buy triggers at prev_ath (level 1.0)" do
      state = CycleDca.new_state(["BTCUSDC"], dca_levels: [1.0, 0.85, 0.70], quote_per_trade: 900.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      # Price hits prev_ath (100.0) from above
      {[order], state} = CycleDca.signal(event("BTCUSDC", 100.0), state)
      assert order.side == "BUY"
      assert_in_delta order.quantity, 300.0 / 100.0, 0.0001  # 900/3 = 300 per tranche
      ss = state.per_symbol["BTCUSDC"]
      assert ss.entries_done == 1
      assert length(ss.tranches) == 1
    end

    test "second buy triggers at dca_level_2 * prev_ath" do
      state = CycleDca.new_state(["BTCUSDC"], dca_levels: [1.0, 0.85, 0.70], quote_per_trade: 900.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      # First buy at 100
      {[_], state} = CycleDca.signal(event("BTCUSDC", 100.0), state)
      # Second level: 100 * 0.85 = 85
      {[order], state} = CycleDca.signal(event("BTCUSDC", 85.0), state)
      assert order.side == "BUY"
      assert state.per_symbol["BTCUSDC"].entries_done == 2
    end

    test "third buy triggers at dca_level_3 * prev_ath" do
      state = CycleDca.new_state(["BTCUSDC"], dca_levels: [1.0, 0.85, 0.70], quote_per_trade: 900.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      state = feed(state, "BTCUSDC", [100.0, 85.0])
      {[order], state} = CycleDca.signal(event("BTCUSDC", 70.0), state)
      assert order.side == "BUY"
      assert state.per_symbol["BTCUSDC"].entries_done == 3
    end

    test "no fourth buy after all levels filled" do
      state = CycleDca.new_state(["BTCUSDC"], dca_levels: [1.0, 0.85, 0.70], quote_per_trade: 900.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      state = feed(state, "BTCUSDC", [100.0, 85.0, 70.0])
      # Price drops further
      {orders, _state} = CycleDca.signal(event("BTCUSDC", 50.0), state)
      assert orders == []
    end
  end

  describe "trailing exit" do
    test "trailing activates when avg_entry * multiplier is hit" do
      # prev_ath = 100, buy at 100, avg_entry=100, multiplier=2.0
      state = CycleDca.new_state(["BTCUSDC"],
        dca_levels: [1.0],
        multiplier: 2.0,
        trail_pct: 0.20,
        quote_per_trade: 300.0
      )
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      {[_buy], state} = CycleDca.signal(event("BTCUSDC", 100.0), state)
      # Hit 2x average entry (100 * 2 = 200)
      {[], state} = CycleDca.signal(event("BTCUSDC", 200.0), state)
      assert state.per_symbol["BTCUSDC"].phase == :trailing
    end

    test "sells all tranches on trailing stop" do
      state = CycleDca.new_state(["BTCUSDC"],
        dca_levels: [1.0, 0.85],
        multiplier: 2.0,
        trail_pct: 0.20,
        quote_per_trade: 600.0
      )
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      # First buy at 100, second at 85
      {[_], state} = CycleDca.signal(event("BTCUSDC", 100.0), state)
      {[_], state} = CycleDca.signal(event("BTCUSDC", 85.0), state)
      # avg entry ≈ 92.5, 2x ≈ 185
      {[], state} = CycleDca.signal(event("BTCUSDC", 185.0), state)
      assert state.per_symbol["BTCUSDC"].phase == :trailing
      # Rise to 300, then drop 20%
      {[], state} = CycleDca.signal(event("BTCUSDC", 300.0), state)
      {[sell], state} = CycleDca.signal(event("BTCUSDC", 239.0), state)
      assert sell.side == "SELL"
      assert sell.quantity > 0
      ss = state.per_symbol["BTCUSDC"]
      assert ss.tranches == []
      assert ss.phase == :watching
    end
  end

  describe "edge cases" do
    test "ignores malformed events" do
      state = CycleDca.new_state(["BTCUSDC"])
      {orders, ^state} = CycleDca.signal(%{}, state)
      assert orders == []
    end

    test "ignores zero close" do
      state = CycleDca.new_state(["BTCUSDC"])
      {orders, _state} = CycleDca.signal(event("BTCUSDC", 0.0), state)
      assert orders == []
    end
  end
end
