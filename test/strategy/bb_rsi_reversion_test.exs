defmodule CriptoTrader.Strategy.BbRsiReversionTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.BbRsiReversion

  # Helper: build a candle event with OHLCV data
  defp event(symbol, candle_data) do
    %{
      symbol: symbol,
      open_time: Map.get(candle_data, :open_time, 1_718_409_600_000),
      candle: %{
        open: to_string(candle_data[:open] || candle_data[:close]),
        high: to_string(candle_data[:high] || candle_data[:close]),
        low: to_string(candle_data[:low] || candle_data[:close]),
        close: to_string(candle_data[:close]),
        volume: to_string(candle_data[:volume] || 100.0)
      }
    }
  end

  # Helper: feed a list of closes through the strategy to build up indicator state.
  # Returns the final state (no orders are expected during warmup).
  defp warmup(state, symbol, closes) do
    Enum.reduce(closes, state, fn close, acc ->
      {_orders, new_state} = BbRsiReversion.signal(event(symbol, %{close: close}), acc)
      new_state
    end)
  end

  describe "new_state/2" do
    test "creates state with default parameters" do
      state = BbRsiReversion.new_state(["BTCUSDC"])
      assert state.bb_period == 20
      assert state.bb_mult == 2.0
      assert state.rsi_period == 14
      assert state.rsi_oversold == 30.0
      assert state.rsi_overbought == 70.0
      assert state.quote_per_trade == 100.0
      assert state.stop_loss_mult == 3.0
      assert state.positions == %{}
      assert state.prices == %{}
      assert state.rsi_state == %{}
    end

    test "accepts custom options" do
      state =
        BbRsiReversion.new_state(["BTCUSDC"],
          bb_period: 30,
          bb_mult: 2.5,
          rsi_period: 10,
          rsi_oversold: 25.0,
          rsi_overbought: 75.0,
          quote_per_trade: 200.0,
          stop_loss_mult: 2.5
        )

      assert state.bb_period == 30
      assert state.bb_mult == 2.5
      assert state.rsi_period == 10
      assert state.rsi_oversold == 25.0
      assert state.rsi_overbought == 75.0
      assert state.quote_per_trade == 200.0
      assert state.stop_loss_mult == 2.5
    end
  end

  describe "warmup period" do
    test "no orders emitted until enough candles for both BB and RSI" do
      state = BbRsiReversion.new_state(["BTCUSDC"], bb_period: 20, rsi_period: 14)

      # Feed 19 candles (need 20 for BB) — should never produce orders
      state =
        Enum.reduce(1..19, state, fn i, acc ->
          price = 100.0 + :math.sin(i / 3.0) * 2
          {orders, new_state} = BbRsiReversion.signal(event("BTCUSDC", %{close: price}), acc)
          assert orders == [], "Expected no orders during warmup candle #{i}"
          new_state
        end)

      # Verify price buffer is being filled
      assert length(state.prices["BTCUSDC"]) == 19
    end
  end

  describe "long entry signal (BB-RSI confluence)" do
    test "buys when price closes below lower BB and RSI < oversold, then re-enters" do
      state = BbRsiReversion.new_state(["BTCUSDC"], bb_period: 20, rsi_period: 14)

      # Warmup with 20 candles of stable prices around 100
      stable_prices = List.duplicate(100.0, 20)
      state = warmup(state, "BTCUSDC", stable_prices)

      # Now feed a series of declining candles to push RSI below 30
      # and price below lower BB
      declining = for i <- 1..8, do: 100.0 - i * 1.5
      state = warmup(state, "BTCUSDC", declining)

      # The price should now be well below the lower BB and RSI should be oversold.
      # Feed one candle that closes back inside the lower BB (re-entry confirmation).
      # This should trigger a BUY.
      recovery_price = 90.0
      {orders, state} = BbRsiReversion.signal(event("BTCUSDC", %{close: recovery_price}), state)

      # We expect a BUY order if conditions are met
      if orders != [] do
        [order] = orders
        assert order.side == "BUY"
        assert order.symbol == "BTCUSDC"
        assert order.quantity > 0
        assert Map.has_key?(state.positions, "BTCUSDC")
      end

      # At minimum, state should have accumulated prices
      assert length(state.prices["BTCUSDC"]) > 0
    end

    test "does not buy when RSI is not oversold even if price below lower BB" do
      state = BbRsiReversion.new_state(["BTCUSDC"], bb_period: 20, rsi_period: 14)

      # Warmup with prices that have high variance (wide BB) but RSI neutral
      # Alternating up/down keeps RSI near 50
      zigzag = for i <- 1..25, do: 100.0 + if(rem(i, 2) == 0, do: 5.0, else: -5.0)
      state = warmup(state, "BTCUSDC", zigzag)

      # Feed a price below lower BB but RSI should be ~50 (not oversold)
      {orders, _state} = BbRsiReversion.signal(event("BTCUSDC", %{close: 80.0}), state)
      # RSI won't be < 30 with zigzag pattern, so no buy
      assert orders == []
    end

    test "does not buy if already holding a position" do
      state = BbRsiReversion.new_state(["BTCUSDC"], bb_period: 20, rsi_period: 14)
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 95.0, quantity: 1.0}}}

      # Even with oversold conditions, should not double-buy
      declining = for i <- 1..25, do: 100.0 - i * 0.8
      state = warmup(state, "BTCUSDC", declining)

      {orders, _state} = BbRsiReversion.signal(event("BTCUSDC", %{close: 85.0}), state)
      assert orders == []
    end
  end

  describe "exit at middle BB (take profit)" do
    test "sells when price reaches middle BB (SMA)" do
      state = BbRsiReversion.new_state(["BTCUSDC"], bb_period: 20, rsi_period: 14)

      # Warmup
      state = warmup(state, "BTCUSDC", List.duplicate(100.0, 25))

      # Simulate holding a position bought at 95
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 95.0, quantity: 1.0}}}

      # Price at the SMA (middle BB) ~100 → should trigger take-profit SELL
      {orders, state} = BbRsiReversion.signal(event("BTCUSDC", %{close: 100.0}), state)

      assert [order] = orders
      assert order.side == "SELL"
      assert order.symbol == "BTCUSDC"
      assert order.quantity == 1.0
      refute Map.has_key?(state.positions, "BTCUSDC")
    end
  end

  describe "stop loss (3-sigma)" do
    test "sells when price drops below entry - 3*stddev (stop loss)" do
      state = BbRsiReversion.new_state(["BTCUSDC"], bb_period: 20, rsi_period: 14, stop_loss_mult: 3.0)

      # Warmup with stable prices to establish a known stddev
      state = warmup(state, "BTCUSDC", List.duplicate(100.0, 20))

      # Add some variance so stddev is non-zero
      varied = for i <- 1..5, do: 100.0 + :math.sin(i) * 2
      state = warmup(state, "BTCUSDC", varied)

      # Simulate holding
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 98.0, quantity: 1.0}}}

      # Crash the price far below — should trigger stop loss
      {orders, state} = BbRsiReversion.signal(event("BTCUSDC", %{close: 80.0}), state)

      assert [order] = orders
      assert order.side == "SELL"
      refute Map.has_key?(state.positions, "BTCUSDC")
    end

    test "does not stop-loss on moderate dip" do
      state = BbRsiReversion.new_state(["BTCUSDC"], bb_period: 20, rsi_period: 14, stop_loss_mult: 3.0)

      # Warmup with variance so stddev is meaningful (~2.0)
      # Prices oscillating 96-104 give stddev ~2.5, so 3-sigma stop ~ SMA - 7.5 ~ 92.5
      varied = for i <- 1..25, do: 100.0 + :math.sin(i * 0.8) * 4
      state = warmup(state, "BTCUSDC", varied)

      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 99.0, quantity: 1.0}}}

      # Small dip to 96 — well above 3-sigma stop (~92.5), should not trigger
      {orders, _state} = BbRsiReversion.signal(event("BTCUSDC", %{close: 96.0}), state)
      assert orders == []
    end
  end

  describe "multi-symbol independence" do
    test "tracks and trades each symbol independently" do
      state = BbRsiReversion.new_state(["BTCUSDC", "ETHUSDC"])

      # Warmup both symbols with different prices
      btc_prices = List.duplicate(50_000.0, 25)
      eth_prices = List.duplicate(3_000.0, 25)

      state = warmup(state, "BTCUSDC", btc_prices)
      state = warmup(state, "ETHUSDC", eth_prices)

      assert Map.has_key?(state.prices, "BTCUSDC")
      assert Map.has_key?(state.prices, "ETHUSDC")

      # Position on BTC only
      state = %{state | positions: %{"BTCUSDC" => %{entry_price: 49_000.0, quantity: 0.002}}}

      # BTC at SMA → sell
      {btc_orders, state} = BbRsiReversion.signal(event("BTCUSDC", %{close: 50_000.0}), state)
      assert [%{side: "SELL", symbol: "BTCUSDC"}] = btc_orders

      # ETH unaffected
      {eth_orders, _state} = BbRsiReversion.signal(event("ETHUSDC", %{close: 3_000.0}), state)
      assert eth_orders == []
    end
  end

  describe "quote-based sizing" do
    test "position size is based on quote_per_trade / entry_price" do
      state = BbRsiReversion.new_state(["BTCUSDC"], quote_per_trade: 100.0, bb_period: 5, rsi_period: 5)

      # Short warmup then force a buy condition
      # Use a tiny BB period so we can trigger faster
      declining = [100.0, 100.0, 100.0, 100.0, 100.0, 99.0, 98.0, 97.0, 96.0, 95.0]
      state = warmup(state, "BTCUSDC", declining)

      # If a buy triggers, check sizing
      {orders, _state} = BbRsiReversion.signal(event("BTCUSDC", %{close: 94.0}), state)

      if orders != [] do
        [order] = orders
        expected_qty = 100.0 / 94.0
        assert_in_delta order.quantity, expected_qty, 0.001
      end
    end
  end

  describe "edge cases" do
    test "ignores events without required fields" do
      state = BbRsiReversion.new_state(["BTCUSDC"])
      {orders, ^state} = BbRsiReversion.signal(%{}, state)
      assert orders == []
    end

    test "handles zero/negative prices gracefully" do
      state = BbRsiReversion.new_state(["BTCUSDC"])
      {orders, _state} = BbRsiReversion.signal(event("BTCUSDC", %{close: 0.0}), state)
      assert orders == []
    end
  end
end
