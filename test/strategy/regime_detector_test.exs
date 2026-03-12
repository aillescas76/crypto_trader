defmodule CriptoTrader.Strategy.RegimeDetectorTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.RegimeDetector

  # Build a full OHLCV candle event
  defp event(symbol, i, opts \\ []) do
    close = Keyword.get(opts, :close, 100.0)
    high = Keyword.get(opts, :high, close)
    low = Keyword.get(opts, :low, close)
    open = Keyword.get(opts, :open, close)

    %{
      symbol: symbol,
      open_time: i * 900_000,
      candle: %{
        open: to_string(open),
        high: to_string(high),
        low: to_string(low),
        close: to_string(close),
        volume: "100"
      }
    }
  end

  # Candle with consistent upward move of `step` per candle
  defp trending_up(symbol, i, step \\ 2.0) do
    p = 100.0 + i * step
    event(symbol, i, open: p - 0.5, high: p + 0.5, low: p - 0.5, close: p)
  end

  # Candle with flat price (no directional movement)
  defp flat(symbol, i), do: event(symbol, i, close: 100.0)

  defp feed(state, events) do
    Enum.reduce(events, state, fn ev, s ->
      {_orders, new_s} = RegimeDetector.signal(ev, s)
      new_s
    end)
  end

  defp adx_value(state, symbol) do
    get_in(state, [:adx_state, symbol, :adx])
  end

  # --- new_state/2 ---

  describe "new_state/2" do
    test "creates state with default parameters" do
      state = RegimeDetector.new_state(["BTCUSDC"])
      assert state.adx_period == 14
      assert state.trend_threshold == 25.0
      assert state.range_threshold == 20.0
    end

    test "accepts custom ADX parameters" do
      state =
        RegimeDetector.new_state(["BTCUSDC"],
          adx_period: 7,
          trend_threshold: 30.0,
          range_threshold: 15.0
        )

      assert state.adx_period == 7
      assert state.trend_threshold == 30.0
      assert state.range_threshold == 15.0
    end
  end

  # --- ADX computation ---

  describe "ADX warmup" do
    test "ADX is nil before 2*period candles have been processed" do
      # period=5 needs 10 candles; feed only 9
      state = RegimeDetector.new_state(["BTCUSDC"], adx_period: 5)
      events = for i <- 0..8, do: trending_up("BTCUSDC", i)
      final = feed(state, events)
      assert adx_value(final, "BTCUSDC") == nil
    end

    test "ADX is available after exactly 2*period candles" do
      state = RegimeDetector.new_state(["BTCUSDC"], adx_period: 5)
      events = for i <- 0..9, do: trending_up("BTCUSDC", i)
      final = feed(state, events)
      assert adx_value(final, "BTCUSDC") != nil
    end

    test "no orders are emitted during warmup" do
      state = RegimeDetector.new_state(["BTCUSDC"], adx_period: 5)
      events = for i <- 0..8, do: trending_up("BTCUSDC", i)

      {all_orders, _final} =
        Enum.map_reduce(events, state, fn ev, s ->
          {orders, new_s} = RegimeDetector.signal(ev, s)
          {orders, new_s}
        end)

      assert Enum.all?(all_orders, &(&1 == []))
    end
  end

  describe "ADX value in trending market" do
    test "produces high ADX (> 25) after sustained directional moves" do
      # period=5; feed 15 candles of consistent uptrend
      state = RegimeDetector.new_state(["BTCUSDC"], adx_period: 5)
      events = for i <- 0..14, do: trending_up("BTCUSDC", i, 2.0)
      final = feed(state, events)
      assert adx_value(final, "BTCUSDC") > 25.0
    end
  end

  describe "ADX value in ranging market" do
    test "produces low ADX (< 20) after flat/oscillating prices" do
      # Constant price = zero TR, zero DM → ADX = 0
      state = RegimeDetector.new_state(["BTCUSDC"], adx_period: 5)
      events = for i <- 0..14, do: flat("BTCUSDC", i)
      final = feed(state, events)
      assert adx_value(final, "BTCUSDC") < 20.0
    end
  end

  # --- Regime routing ---

  # Force a specific ADX value directly into state.
  # Smooth values are derived so that a flat candle at 100.0 keeps DX = adx,
  # making ADX stable on the next candle.
  defp set_adx(state, symbol, adx) do
    # With smooth_tr=10, we need +DI and -DI such that DX = adx.
    # Choose +DI = 0.5 + adx/200, -DI = 0.5 - adx/200 → DX = adx exactly.
    smooth_plus_dm = 10.0 * (0.5 + adx / 200.0)
    smooth_minus_dm = 10.0 * (0.5 - adx / 200.0)

    entry = %{
      prev_high: 100.0,
      prev_low: 100.0,
      prev_close: 100.0,
      count: 999,
      tr_acc: 0.0,
      plus_dm_acc: 0.0,
      minus_dm_acc: 0.0,
      smooth_tr: 10.0,
      smooth_plus_dm: smooth_plus_dm,
      smooth_minus_dm: smooth_minus_dm,
      dx_acc: 0.0,
      dx_count: 999,
      adx: adx
    }

    put_in(state, [:adx_state, symbol], entry)
  end

  describe "trending regime (ADX > trend_threshold)" do
    test "routes candles to IntradayMomentum in buy window" do
      state =
        RegimeDetector.new_state(["BTCUSDC"],
          adx_period: 5,
          quote_per_trade: 100.0,
          stop_loss_pct: 0.02,
          trail_pct: 0.003
        )

      state = set_adx(state, "BTCUSDC", 35.0)

      # 19:00 UTC = hour 19 → open_time covers that hour
      buy_window_ts = 19 * 3_600_000

      # Feed a dip then bounce to trigger IntradayMomentum buy
      low_ev = %{
        event("BTCUSDC", 0, close: 98.0)
        | open_time: buy_window_ts
      }

      {_, state} = RegimeDetector.signal(low_ev, state)

      # Price bounces above trigger = 98.0 * (1 + 0.003) = 98.294
      bounce_ev = %{
        event("BTCUSDC", 1, close: 98.5)
        | open_time: buy_window_ts + 900_000
      }

      {orders, _} = RegimeDetector.signal(bounce_ev, state)
      assert [%{side: "BUY", symbol: "BTCUSDC"}] = orders
    end

    test "suppresses BbRsiReversion signals in trending regime" do
      state =
        RegimeDetector.new_state(["BTCUSDC"],
          adx_period: 5,
          quote_per_trade: 100.0,
          bb_period: 5,
          rsi_period: 5
        )

      # Warm up the reversion sub-state indicators (adx_period=5 → 10 events for ADX;
      # then 15 more routed to reversion to fill bb_period=5 and rsi_period=5)
      warmup_events = for i <- 0..24, do: flat("BTCUSDC", i)
      state = feed(state, warmup_events)

      # Now force trending ADX and inject a reversion position
      state = set_adx(state, "BTCUSDC", 35.0)

      reversion =
        put_in(state.reversion_state, [:positions, "BTCUSDC"], %{
          entry_price: 95.0,
          quantity: 1.0
        })

      state = %{state | reversion_state: reversion}

      # Price at SMA (~100) would normally trigger take-profit SELL from BbRsiReversion
      # In trending regime, that signal must be suppressed
      outside_window_ts = 10 * 3_600_000
      ev = %{flat("BTCUSDC", 100) | open_time: outside_window_ts}
      {orders, _} = RegimeDetector.signal(ev, state)

      refute Enum.any?(orders, &(&1.side == "SELL"))
    end
  end

  describe "ranging regime (ADX < range_threshold)" do
    test "routes candles to BbRsiReversion in ranging regime" do
      state =
        RegimeDetector.new_state(["BTCUSDC"],
          adx_period: 5,
          quote_per_trade: 100.0,
          bb_period: 5,
          rsi_period: 5
        )

      warmup_events = for i <- 0..24, do: flat("BTCUSDC", i)
      state = feed(state, warmup_events)
      state = set_adx(state, "BTCUSDC", 10.0)

      reversion =
        put_in(state.reversion_state, [:positions, "BTCUSDC"], %{
          entry_price: 95.0,
          quantity: 1.0
        })

      state = %{state | reversion_state: reversion}

      # Price at SMA (~100) → take-profit SELL should fire from BbRsiReversion
      outside_window_ts = 10 * 3_600_000
      ev = %{flat("BTCUSDC", 100) | open_time: outside_window_ts}
      {orders, _} = RegimeDetector.signal(ev, state)

      assert [%{side: "SELL", symbol: "BTCUSDC"}] = orders
    end

    test "suppresses IntradayMomentum in ranging regime" do
      state =
        RegimeDetector.new_state(["BTCUSDC"],
          adx_period: 5,
          quote_per_trade: 100.0,
          stop_loss_pct: 0.02,
          trail_pct: 0.003
        )

      state = set_adx(state, "BTCUSDC", 10.0)

      buy_window_ts = 19 * 3_600_000

      low_ev = %{event("BTCUSDC", 0, close: 98.0) | open_time: buy_window_ts}
      {_, state} = RegimeDetector.signal(low_ev, state)

      bounce_ev = %{event("BTCUSDC", 1, close: 98.5) | open_time: buy_window_ts + 900_000}
      {orders, _} = RegimeDetector.signal(bounce_ev, state)

      # Momentum buy must NOT fire in ranging regime
      refute Enum.any?(orders, &(&1.side == "BUY"))
    end
  end

  describe "mixed regime (range_threshold <= ADX <= trend_threshold)" do
    test "routes to both strategies in mixed regime" do
      state =
        RegimeDetector.new_state(["BTCUSDC"],
          adx_period: 5,
          quote_per_trade: 100.0,
          bb_period: 5,
          rsi_period: 5,
          stop_loss_pct: 0.02,
          trail_pct: 0.003
        )

      warmup_events = for i <- 0..24, do: flat("BTCUSDC", i)
      state = feed(state, warmup_events)
      state = set_adx(state, "BTCUSDC", 22.0)

      # Inject a reversion position
      reversion =
        put_in(state.reversion_state, [:positions, "BTCUSDC"], %{
          entry_price: 95.0,
          quantity: 1.0
        })

      state = %{state | reversion_state: reversion}

      # Outside all windows → only reversion can fire
      outside_window_ts = 10 * 3_600_000
      ev = %{flat("BTCUSDC", 100) | open_time: outside_window_ts}
      {orders, _} = RegimeDetector.signal(ev, state)

      # Reversion SELL should fire even in mixed mode
      assert Enum.any?(orders, &(&1.side == "SELL"))
    end
  end

  describe "multi-symbol independence" do
    test "tracks ADX independently per symbol" do
      state = RegimeDetector.new_state(["BTCUSDC", "ETHUSDC"], adx_period: 5)

      btc_events = for i <- 0..14, do: trending_up("BTCUSDC", i, 2.0)
      eth_events = for i <- 0..14, do: flat("ETHUSDC", i)

      state = feed(state, btc_events)
      state = feed(state, eth_events)

      btc_adx = adx_value(state, "BTCUSDC")
      eth_adx = adx_value(state, "ETHUSDC")

      assert btc_adx > 25.0
      assert eth_adx < 20.0
    end
  end

  # --- Higher-timeframe ADX (adx_timeframe_ms option) ---
  #
  # Use adx_timeframe_ms: 4 so each "HTF candle" = 4ms.
  # With adx_period: 5, need 10 HTF-bucket completions for first ADX.
  # Bucket crossings happen at open_time = 4, 8, 12, …, 40 (10 crossings).

  @htf_ms 4

  defp ev_at(symbol, open_time, opts \\ []) do
    close = Keyword.get(opts, :close, 100.0)
    step = Keyword.get(opts, :step, 0.0)
    p = close + open_time * step
    %{
      symbol: symbol,
      open_time: open_time,
      candle: %{
        open: to_string(p),
        high: to_string(p + 0.5),
        low: to_string(p - 0.5),
        close: to_string(p),
        volume: "100"
      }
    }
  end

  describe "higher-timeframe ADX (adx_timeframe_ms)" do
    test "new_state/2 accepts adx_timeframe_ms option" do
      state = RegimeDetector.new_state(["BTCUSDC"], adx_timeframe_ms: 3_600_000)
      assert state.adx_timeframe_ms == 3_600_000
    end

    test "ADX is nil before enough HTF buckets have completed" do
      # 9 bucket crossings at t=4,8,...,36 → 9 completions, need 10
      state = RegimeDetector.new_state(["BTCUSDC"], adx_period: 5, adx_timeframe_ms: @htf_ms)
      events = for t <- 0..39, do: ev_at("BTCUSDC", t, step: 0.5)
      final = feed(state, events)
      assert adx_value(final, "BTCUSDC") == nil
    end

    test "ADX is available after exactly 2*adx_period HTF bucket completions" do
      # 10th crossing happens at t=40
      state = RegimeDetector.new_state(["BTCUSDC"], adx_period: 5, adx_timeframe_ms: @htf_ms)
      events = for t <- 0..40, do: ev_at("BTCUSDC", t, step: 0.5)
      final = feed(state, events)
      assert adx_value(final, "BTCUSDC") != nil
    end

    test "ADX does not change while inside an HTF bucket" do
      state = RegimeDetector.new_state(["BTCUSDC"], adx_period: 5, adx_timeframe_ms: @htf_ms)
      # Warm up: get ADX running
      setup = for t <- 0..40, do: ev_at("BTCUSDC", t, step: 0.5)
      state = feed(state, setup)
      adx_after_setup = adx_value(state, "BTCUSDC")
      assert adx_after_setup != nil

      # t=41,42,43 are all in bucket 40 → no new completion → ADX must not change
      {adx_mid_bucket, _} =
        Enum.map_reduce([41, 42, 43], state, fn t, s ->
          {_orders, new_s} = RegimeDetector.signal(ev_at("BTCUSDC", t), s)
          {adx_value(new_s, "BTCUSDC"), new_s}
        end)

      assert Enum.all?(adx_mid_bucket, &(&1 == adx_after_setup))
    end

    test "ADX updates when the next HTF bucket starts" do
      # Use flat setup so ADX converges to 0.0 — easy baseline
      state = RegimeDetector.new_state(["BTCUSDC"], adx_period: 5, adx_timeframe_ms: @htf_ms)
      flat_setup = for t <- 0..43, do: ev_at("BTCUSDC", t)
      state = feed(state, flat_setup)
      # t=44 completes flat bucket 40 → ADX = 0.0
      {_, state} = RegimeDetector.signal(ev_at("BTCUSDC", 44), state)
      adx_before = adx_value(state, "BTCUSDC")
      assert adx_before == 0.0

      # Feed strongly trending data into bucket 44 (t=45..47), then trigger at t=48
      trending_bucket = for t <- 45..47, do: ev_at("BTCUSDC", t, step: 5.0)
      state = feed(state, trending_bucket)
      {_orders, state_after} = RegimeDetector.signal(ev_at("BTCUSDC", 48, step: 5.0), state)
      adx_after = adx_value(state_after, "BTCUSDC")

      # Bucket 44 was strongly trending → DX > 0 → ADX rises from 0
      assert adx_after > adx_before
    end

    test "in trending HTF regime, BbRsiReversion still fires on 15m sub-candles" do
      # Warm up with trending HTF data so ADX > 25 on HTF
      state =
        RegimeDetector.new_state(["BTCUSDC"],
          adx_period: 5,
          adx_timeframe_ms: @htf_ms,
          quote_per_trade: 100.0,
          bb_period: 5,
          rsi_period: 5
        )

      # Build trending HTF ADX: feed enough trending candles to get ADX > 25
      trending_setup = for t <- 0..50, do: ev_at("BTCUSDC", t, step: 2.0)
      state = feed(state, trending_setup)
      assert adx_value(state, "BTCUSDC") > 25.0

      # Reversion sub-state received events from t=40..50 (step=2.0 → closes ~180..200).
      # Inject position with entry below the current SMA (~196).
      reversion =
        put_in(state.reversion_state, [:positions, "BTCUSDC"], %{
          entry_price: 180.0,
          quantity: 1.0
        })

      state = %{state | reversion_state: reversion}

      # Send a candle at ~200 (above SMA ≈196) to trigger take-profit SELL.
      outside_ts = 10 * 3_600_000
      ev = %{ev_at("BTCUSDC", 0, close: 200.0) | open_time: outside_ts}
      {orders, _} = RegimeDetector.signal(ev, state)

      # In a trending HTF regime, BbRsiReversion IS still routed
      # (routing depends on 1h ADX, sub-candle reversion signals fire within the trend)
      assert Enum.any?(orders, &(&1.side == "SELL"))
    end
  end
end
