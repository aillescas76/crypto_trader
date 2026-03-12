defmodule CriptoTrader.Strategy.AltcoinCycleTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.AltcoinCycle

  defp event(symbol, close) do
    %{
      symbol: symbol,
      open_time: 1_000_000,
      candle: %{close: close}
    }
  end

  defp default_state do
    AltcoinCycle.new_state(
      ["BTCUSDC", "ETHUSDC", "SOLUSDC"],
      entry_ath: 20_000.0,
      initial_ath: 69_044.0,
      trail_pct: 0.25,
      alt_trail_pct: 0.35,
      quote_per_trade: 1_000.0
    )
  end

  describe "new_state/2" do
    test "splits btc_symbol from alt_symbols" do
      state = default_state()
      assert state.btc_symbol == "BTCUSDC"
      assert MapSet.member?(state.alt_symbols, "ETHUSDC")
      assert MapSet.member?(state.alt_symbols, "SOLUSDC")
      refute MapSet.member?(state.alt_symbols, "BTCUSDC")
    end

    test "initialises btc_phase to :watching" do
      assert default_state().btc_phase == :watching
    end

    test "defaults buy_signal and btc_exit_signal to false" do
      state = default_state()
      refute state.buy_signal
      refute state.btc_exit_signal
    end

    test "accepts custom btc_symbol" do
      state =
        AltcoinCycle.new_state(["BTCUSDT", "ETHUSDT"],
          btc_symbol: "BTCUSDT",
          entry_ath: 1.0,
          initial_ath: 2.0
        )

      assert state.btc_symbol == "BTCUSDT"
      assert MapSet.member?(state.alt_symbols, "ETHUSDT")
      refute MapSet.member?(state.alt_symbols, "BTCUSDT")
    end
  end

  describe "BTC watching phase" do
    test "no orders and no buy_signal while BTC close >= entry_ath" do
      state = default_state()

      {orders, state} = AltcoinCycle.signal(event("BTCUSDC", 21_000.0), state)
      assert orders == []
      refute state.buy_signal
      assert state.btc_phase == :watching
    end

    test "sets buy_signal when BTC drops below entry_ath" do
      state = default_state()

      {orders, state} = AltcoinCycle.signal(event("BTCUSDC", 19_999.0), state)
      assert orders == []
      assert state.buy_signal
      assert state.btc_phase == :in_position
    end
  end

  describe "altcoin buy on signal" do
    test "alts buy on their own event after buy_signal is set" do
      state = default_state()

      {[], state} = AltcoinCycle.signal(event("BTCUSDC", 19_000.0), state)
      assert state.buy_signal

      {eth_orders, state} = AltcoinCycle.signal(event("ETHUSDC", 1_500.0), state)
      assert [%{symbol: "ETHUSDC", side: "BUY", quantity: qty}] = eth_orders
      assert_in_delta qty, 1_000.0 / 1_500.0, 0.0001

      # SOL buys at its own price
      {sol_orders, state} = AltcoinCycle.signal(event("SOLUSDC", 50.0), state)
      assert [%{symbol: "SOLUSDC", side: "BUY", quantity: sol_qty}] = sol_orders
      assert_in_delta sol_qty, 1_000.0 / 50.0, 0.0001

      assert Map.has_key?(state.alt_positions, "ETHUSDC")
      assert Map.has_key?(state.alt_positions, "SOLUSDC")
    end

    test "alt does not buy again once already in position" do
      state = default_state()

      {[], state} = AltcoinCycle.signal(event("BTCUSDC", 19_000.0), state)
      {[_buy], state} = AltcoinCycle.signal(event("ETHUSDC", 1_500.0), state)

      # Second ETH event should not re-buy
      {orders, _state} = AltcoinCycle.signal(event("ETHUSDC", 1_600.0), state)
      assert orders == []
    end

    test "BTC events never produce orders" do
      state = default_state()

      {orders, state} = AltcoinCycle.signal(event("BTCUSDC", 15_000.0), state)
      assert orders == []

      {orders, _} = AltcoinCycle.signal(event("BTCUSDC", 80_000.0), state)
      assert orders == []
    end
  end

  describe "per-coin trailing stop" do
    test "alt sells independently when own trailing stop fires" do
      state = default_state()

      {[], state} = AltcoinCycle.signal(event("BTCUSDC", 19_000.0), state)
      {[_buy], state} = AltcoinCycle.signal(event("ETHUSDC", 1_000.0), state)
      {[_buy], state} = AltcoinCycle.signal(event("SOLUSDC", 100.0), state)

      # ETH pumps to 2000 (sets peak)
      {[], state} = AltcoinCycle.signal(event("ETHUSDC", 2_000.0), state)

      # ETH drops > 35% from peak (2000 * 0.65 = 1300)
      {eth_orders, state} = AltcoinCycle.signal(event("ETHUSDC", 1_290.0), state)
      assert [%{symbol: "ETHUSDC", side: "SELL"}] = eth_orders
      refute Map.has_key?(state.alt_positions, "ETHUSDC")

      # SOL unaffected
      assert Map.has_key?(state.alt_positions, "SOLUSDC")
    end

    test "alt does not sell on small dip below peak" do
      state = default_state()

      {[], state} = AltcoinCycle.signal(event("BTCUSDC", 19_000.0), state)
      {[_buy], state} = AltcoinCycle.signal(event("ETHUSDC", 1_000.0), state)

      # ETH pumps to 2000
      {[], state} = AltcoinCycle.signal(event("ETHUSDC", 2_000.0), state)

      # Small dip (10%) — below 35% threshold, should not sell
      {orders, _state} = AltcoinCycle.signal(event("ETHUSDC", 1_800.0), state)
      assert orders == []
    end
  end

  describe "BTC exit signal sells remaining alts" do
    defp state_with_trailing do
      state = default_state()

      # BTC enters position
      {[], state} = AltcoinCycle.signal(event("BTCUSDC", 19_000.0), state)

      # Alts buy
      {[_], state} = AltcoinCycle.signal(event("ETHUSDC", 1_000.0), state)
      {[_], state} = AltcoinCycle.signal(event("SOLUSDC", 100.0), state)

      # BTC breaks initial_ath → enters trailing
      {[], state} = AltcoinCycle.signal(event("BTCUSDC", 70_000.0), state)
      assert state.btc_phase == :trailing

      # BTC peaks and drops > 25%
      {[], state} = AltcoinCycle.signal(event("BTCUSDC", 100_000.0), state)
      {[], state} = AltcoinCycle.signal(event("BTCUSDC", 74_000.0), state)
      assert state.btc_exit_signal

      state
    end

    test "remaining alt positions are sold on next event after btc_exit_signal" do
      state = state_with_trailing()

      {eth_orders, state} = AltcoinCycle.signal(event("ETHUSDC", 1_200.0), state)
      assert [%{symbol: "ETHUSDC", side: "SELL"}] = eth_orders
      refute Map.has_key?(state.alt_positions, "ETHUSDC")

      {sol_orders, state} = AltcoinCycle.signal(event("SOLUSDC", 90.0), state)
      assert [%{symbol: "SOLUSDC", side: "SELL"}] = sol_orders
      refute Map.has_key?(state.alt_positions, "SOLUSDC")
    end

    test "alt already sold by own trailing stop is not double-sold on btc_exit" do
      state = default_state()

      {[], state} = AltcoinCycle.signal(event("BTCUSDC", 19_000.0), state)
      {[_], state} = AltcoinCycle.signal(event("ETHUSDC", 1_000.0), state)

      # ETH sells via own trailing stop
      {[], state} = AltcoinCycle.signal(event("ETHUSDC", 2_000.0), state)
      {[_sell], state} = AltcoinCycle.signal(event("ETHUSDC", 1_200.0), state)
      refute Map.has_key?(state.alt_positions, "ETHUSDC")

      # BTC triggers exit
      state = %{state | btc_exit_signal: true}

      # ETH event — should not produce another sell
      {orders, _} = AltcoinCycle.signal(event("ETHUSDC", 1_100.0), state)
      assert orders == []
    end
  end

  describe "unknown symbols" do
    test "events for symbols not in alt_symbols or btc_symbol are ignored" do
      state = default_state()

      {orders, new_state} = AltcoinCycle.signal(event("BNBUSDC", 300.0), state)
      assert orders == []
      assert new_state == state
    end
  end

  describe "edge cases" do
    test "ignores events without candle field" do
      state = default_state()
      {orders, ^state} = AltcoinCycle.signal(%{symbol: "BTCUSDC"}, state)
      assert orders == []
    end

    test "ignores zero close price" do
      state = default_state()
      {orders, ^state} = AltcoinCycle.signal(event("BTCUSDC", 0.0), state)
      assert orders == []
    end
  end
end
