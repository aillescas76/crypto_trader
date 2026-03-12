defmodule CriptoTrader.Strategy.LateralRangeTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.LateralRange

  defp event(symbol, close) do
    %{
      symbol: symbol,
      open_time: 1_718_409_600_000,
      candle: %{
        open: to_string(close),
        high: to_string(close),
        low: to_string(close),
        close: to_string(close)
      }
    }
  end

  defp warmup(state, symbol, closes) do
    Enum.reduce(closes, state, fn close, acc ->
      {_orders, new_state} = LateralRange.signal(event(symbol, close), acc)
      new_state
    end)
  end

  describe "new_state/2" do
    test "builds defaults" do
      state = LateralRange.new_state(["BTCUSDC"])

      assert state.lookback == 30
      assert state.max_range_pct == 0.02
      assert state.quote_per_trade == 100.0
      assert state.stop_loss_pct == 0.015
      assert state.entry_buffer_pct == 0.0025
      assert state.exit_buffer_pct == 0.0025
      assert state.breakout_pct == 0.005
      assert state.positions == %{}
      assert state.closes == %{}
    end

    test "accepts custom options" do
      state =
        LateralRange.new_state(["BTCUSDC"],
          lookback: 12,
          max_range_pct: 0.01,
          quote_per_trade: 250.0,
          stop_loss_pct: 0.02,
          entry_buffer_pct: 0.001,
          exit_buffer_pct: 0.001,
          breakout_pct: 0.003
        )

      assert state.lookback == 12
      assert state.max_range_pct == 0.01
      assert state.quote_per_trade == 250.0
      assert state.stop_loss_pct == 0.02
      assert state.entry_buffer_pct == 0.001
      assert state.exit_buffer_pct == 0.001
      assert state.breakout_pct == 0.003
    end
  end

  describe "range trading behavior" do
    test "waits for warmup before trading" do
      state = LateralRange.new_state(["BTCUSDC"], lookback: 5)

      state =
        Enum.reduce(1..4, state, fn idx, acc ->
          {orders, new_state} = LateralRange.signal(event("BTCUSDC", 100.0 + idx), acc)
          assert orders == []
          new_state
        end)

      assert length(state.closes["BTCUSDC"]) == 4
    end

    test "buys near lower bound in lateral regime and sells near upper bound" do
      state =
        LateralRange.new_state(["BTCUSDC"],
          lookback: 5,
          max_range_pct: 0.02,
          entry_buffer_pct: 0.001,
          exit_buffer_pct: 0.001,
          quote_per_trade: 100.0
        )

      state = warmup(state, "BTCUSDC", [100.0, 100.4, 99.8, 100.2, 99.7])

      {[buy], state} = LateralRange.signal(event("BTCUSDC", 99.75), state)
      assert buy.side == "BUY"
      assert buy.symbol == "BTCUSDC"
      assert buy.quantity > 0

      {[sell], state} = LateralRange.signal(event("BTCUSDC", 100.35), state)
      assert sell.side == "SELL"
      refute Map.has_key?(state.positions, "BTCUSDC")
    end

    test "does not buy in non-lateral regime" do
      state =
        LateralRange.new_state(["BTCUSDC"],
          lookback: 5,
          max_range_pct: 0.01,
          entry_buffer_pct: 0.01
        )

      state = warmup(state, "BTCUSDC", [100.0, 102.0, 104.0, 106.0, 108.0])

      {orders, _state} = LateralRange.signal(event("BTCUSDC", 102.0), state)
      assert orders == []
    end
  end

  describe "loss protection" do
    test "stop-loss closes position on adverse move" do
      state = LateralRange.new_state(["BTCUSDC"], lookback: 5, stop_loss_pct: 0.01)
      state = warmup(state, "BTCUSDC", [100.0, 100.2, 99.9, 100.1, 100.0])
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 100.0, quantity: 1.0}}}

      {[sell], state} = LateralRange.signal(event("BTCUSDC", 98.9), state)
      assert sell.side == "SELL"
      refute Map.has_key?(state.positions, "BTCUSDC")
    end

    test "downside breakout exits even before stop-loss" do
      state =
        LateralRange.new_state(["BTCUSDC"],
          lookback: 5,
          stop_loss_pct: 0.05,
          breakout_pct: 0.005
        )

      state = warmup(state, "BTCUSDC", [100.0, 100.4, 99.8, 100.2, 99.7])
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 100.0, quantity: 1.0}}}

      {[sell], _state} = LateralRange.signal(event("BTCUSDC", 98.4), state)
      assert sell.side == "SELL"
    end
  end

  describe "edge cases" do
    test "ignores malformed events" do
      state = LateralRange.new_state(["BTCUSDC"])
      {orders, ^state} = LateralRange.signal(%{}, state)
      assert orders == []
    end

    test "ignores zero or negative close" do
      state = LateralRange.new_state(["BTCUSDC"])
      {orders, _state} = LateralRange.signal(event("BTCUSDC", 0.0), state)
      assert orders == []
    end
  end
end
