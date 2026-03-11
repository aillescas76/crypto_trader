defmodule CriptoTrader.Strategy.CycleAthConfirmTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.CycleAthConfirm

  defp event(symbol, close) do
    %{
      symbol: symbol,
      open_time: 1_718_409_600_000,
      candle: %{close: to_string(close)}
    }
  end

  defp feed(state, symbol, closes) do
    Enum.reduce(closes, state, fn close, acc ->
      {_orders, new_state} = CycleAthConfirm.signal(event(symbol, close), acc)
      new_state
    end)
  end

  describe "new_state/2" do
    test "builds defaults" do
      state = CycleAthConfirm.new_state(["BTCUSDC"])
      assert state.confirm_candles == 3
      assert state.multiplier == 2.0
      assert state.trail_pct == 0.20
      assert state.quote_per_trade == 1000.0
    end

    test "accepts custom confirm_candles" do
      state = CycleAthConfirm.new_state(["BTCUSDC"], confirm_candles: 5)
      assert state.confirm_candles == 5
    end
  end

  describe "confirmation gating" do
    test "does not buy on first candle below prev_ath" do
      state = CycleAthConfirm.new_state(["BTCUSDC"], confirm_candles: 3)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      {orders, _state} = CycleAthConfirm.signal(event("BTCUSDC", 90.0), state)
      assert orders == []
    end

    test "does not buy before confirm_candles threshold" do
      state = CycleAthConfirm.new_state(["BTCUSDC"], confirm_candles: 3)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      # 2 candles below prev_ath — not enough
      state = feed(state, "BTCUSDC", [90.0, 85.0])
      assert Map.get(state.confirm_count, "BTCUSDC", 0) == 2
      assert state.positions == %{}
    end

    test "buys after confirm_candles consecutive closes below prev_ath" do
      state = CycleAthConfirm.new_state(["BTCUSDC"], confirm_candles: 3, quote_per_trade: 1000.0)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      # 2 candles below — not yet
      state = feed(state, "BTCUSDC", [90.0, 85.0])
      assert state.positions == %{}
      # 3rd candle — buy
      {[order], _state} = CycleAthConfirm.signal(event("BTCUSDC", 80.0), state)
      assert order.side == "BUY"
      assert order.symbol == "BTCUSDC"
    end

    test "resets counter when price goes back above prev_ath" do
      state = CycleAthConfirm.new_state(["BTCUSDC"], confirm_candles: 3)
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      # 2 candles below
      state = feed(state, "BTCUSDC", [90.0, 85.0])
      assert Map.get(state.confirm_count, "BTCUSDC", 0) == 2
      # Bounce above prev_ath — reset
      {orders, state} = CycleAthConfirm.signal(event("BTCUSDC", 110.0), state)
      assert orders == []
      assert Map.get(state.confirm_count, "BTCUSDC", 0) == 0
    end
  end

  describe "trailing exit (inherited)" do
    test "activates trailing at multiplier and sells on stop" do
      state = CycleAthConfirm.new_state(["BTCUSDC"],
        confirm_candles: 1,
        multiplier: 2.0,
        trail_pct: 0.20,
        quote_per_trade: 1000.0
      )
      state = feed(state, "BTCUSDC", [100.0, 200.0])
      # confirm_candles=1, one candle below prev_ath triggers buy
      {[_buy], state} = CycleAthConfirm.signal(event("BTCUSDC", 90.0), state)
      # Hits 2x
      {[], state} = CycleAthConfirm.signal(event("BTCUSDC", 180.0), state)
      assert Map.get(state.phase, "BTCUSDC") == :trailing
      # Trailing drop
      {[sell], _state} = CycleAthConfirm.signal(event("BTCUSDC", 143.0), state)
      assert sell.side == "SELL"
    end
  end
end
