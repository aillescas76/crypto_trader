defmodule CriptoTrader.Strategy.RegimeDetector do
  @moduledoc """
  ADX-based regime detector that routes signals to sub-strategies.

  - ADX > trend_threshold (default 25): trending → IntradayMomentum only
  - ADX < range_threshold (default 20): ranging → BbRsiReversion only
  - range_threshold ≤ ADX ≤ trend_threshold: mixed → both strategies active
  - ADX nil (warmup): no routing, no orders

  ADX is computed using Wilder's smoothing (period 14 by default).
  Requires 2*adx_period candles before the first ADX value is available.
  """

  alias CriptoTrader.Strategy.{BbRsiReversion, IntradayMomentum}

  @default_adx_period 14
  @default_trend_threshold 25.0
  @default_range_threshold 20.0

  @spec new_state([String.t()], keyword()) :: map()
  def new_state(symbols, opts \\ []) do
    %{
      adx_period: Keyword.get(opts, :adx_period, @default_adx_period),
      trend_threshold: Keyword.get(opts, :trend_threshold, @default_trend_threshold),
      range_threshold: Keyword.get(opts, :range_threshold, @default_range_threshold),
      adx_timeframe_ms: Keyword.get(opts, :adx_timeframe_ms),
      adx_state: %{},
      htf_candles: %{},
      momentum_state: IntradayMomentum.new_state(symbols, opts),
      reversion_state: BbRsiReversion.new_state(symbols, opts)
    }
  end

  @spec signal(map(), map()) :: {[map()], map()}
  def signal(%{symbol: symbol, open_time: open_time, candle: candle} = event, state) do
    state = update_regime_adx(symbol, open_time, candle, state)
    adx = get_in(state, [:adx_state, symbol, :adx])
    regime = classify(adx, state.trend_threshold, state.range_threshold)

    {momentum_orders, momentum_state} =
      if regime in [:trending, :mixed] do
        IntradayMomentum.signal(event, state.momentum_state)
      else
        {[], state.momentum_state}
      end

    # In HTF mode, BbRsiReversion also fires during trending regimes:
    # a 1h-trending market still has mean-reversion opportunities on 15m sub-candles.
    use_reversion = regime in [:ranging, :mixed] or
                      (state.adx_timeframe_ms != nil and regime == :trending)

    {reversion_orders, reversion_state} =
      if use_reversion do
        BbRsiReversion.signal(event, state.reversion_state)
      else
        {[], state.reversion_state}
      end

    new_state = %{state | momentum_state: momentum_state, reversion_state: reversion_state}
    {momentum_orders ++ reversion_orders, new_state}
  end

  def signal(_event, state), do: {[], state}

  # --- ADX update dispatch ---

  defp update_regime_adx(symbol, _open_time, candle, %{adx_timeframe_ms: nil} = state) do
    update_adx(symbol, candle, state)
  end

  defp update_regime_adx(symbol, open_time, candle, state) do
    period_ms = state.adx_timeframe_ms
    bucket = div(open_time, period_ms) * period_ms

    high = parse_float(candle[:high] || candle["high"])
    low = parse_float(candle[:low] || candle["low"])
    close = parse_float(candle[:close] || candle["close"])

    case Map.get(state.htf_candles, symbol) do
      nil ->
        htf = %{bucket: bucket, high: high, low: low, close: close}
        %{state | htf_candles: Map.put(state.htf_candles, symbol, htf)}

      %{bucket: ^bucket} = htf ->
        updated = %{htf | high: max(htf.high, high), low: min(htf.low, low), close: close}
        %{state | htf_candles: Map.put(state.htf_candles, symbol, updated)}

      %{high: h, low: l, close: c} ->
        # New bucket: complete the previous HTF candle → update ADX
        htf_candle = %{"high" => to_string(h), "low" => to_string(l), "close" => to_string(c)}
        state = update_adx(symbol, htf_candle, state)
        htf = %{bucket: bucket, high: high, low: low, close: close}
        %{state | htf_candles: Map.put(state.htf_candles, symbol, htf)}
    end
  end

  # --- Regime classification ---

  defp classify(nil, _, _), do: :warmup
  defp classify(adx, trend, _) when adx >= trend, do: :trending
  defp classify(adx, _, range) when adx <= range, do: :ranging
  defp classify(_, _, _), do: :mixed

  # --- ADX update ---

  defp update_adx(symbol, candle, state) do
    period = state.adx_period
    high = parse_float(candle[:high] || candle["high"])
    low = parse_float(candle[:low] || candle["low"])
    close = parse_float(candle[:close] || candle["close"])

    adx_sym = Map.get(state.adx_state, symbol)
    updated = step_adx(adx_sym, high, low, close, period)
    %{state | adx_state: Map.put(state.adx_state, symbol, updated)}
  end

  # First candle: just store OHLC, no computation yet
  defp step_adx(nil, high, low, close, _period) do
    %{
      prev_high: high,
      prev_low: low,
      prev_close: close,
      count: 0,
      tr_acc: 0.0,
      plus_dm_acc: 0.0,
      minus_dm_acc: 0.0,
      smooth_tr: nil,
      smooth_plus_dm: nil,
      smooth_minus_dm: nil,
      dx_acc: 0.0,
      dx_count: 0,
      adx: nil
    }
  end

  # Subsequent candles: compute TR and directional movement
  defp step_adx(s, high, low, close, period) do
    {tr, plus_dm, minus_dm} = dm_values(high, low, close, s.prev_high, s.prev_low, s.prev_close)
    s = %{s | prev_high: high, prev_low: low, prev_close: close}

    cond do
      # Phase 1: accumulate initial sums (count 0..period-1 after first)
      s.smooth_tr == nil and s.count + 1 < period ->
        %{s | count: s.count + 1, tr_acc: s.tr_acc + tr,
              plus_dm_acc: s.plus_dm_acc + plus_dm, minus_dm_acc: s.minus_dm_acc + minus_dm}

      # Phase 1 → 2: initial smooth complete, compute first DX
      s.smooth_tr == nil ->
        smooth_tr = s.tr_acc + tr
        smooth_plus_dm = s.plus_dm_acc + plus_dm
        smooth_minus_dm = s.minus_dm_acc + minus_dm
        dx = compute_dx(smooth_tr, smooth_plus_dm, smooth_minus_dm)

        %{s | count: s.count + 1,
              smooth_tr: smooth_tr, smooth_plus_dm: smooth_plus_dm, smooth_minus_dm: smooth_minus_dm,
              dx_acc: dx, dx_count: 1,
              tr_acc: 0.0, plus_dm_acc: 0.0, minus_dm_acc: 0.0}

      # Phase 2: accumulate DX for initial ADX average
      s.adx == nil and s.dx_count + 1 < period ->
        {str, spdm, smdm} = wilder_smooth(s.smooth_tr, s.smooth_plus_dm, s.smooth_minus_dm, tr, plus_dm, minus_dm, period)
        dx = compute_dx(str, spdm, smdm)

        %{s | smooth_tr: str, smooth_plus_dm: spdm, smooth_minus_dm: smdm,
              dx_acc: s.dx_acc + dx, dx_count: s.dx_count + 1}

      # Phase 2 → 3: compute initial ADX
      s.adx == nil ->
        {str, spdm, smdm} = wilder_smooth(s.smooth_tr, s.smooth_plus_dm, s.smooth_minus_dm, tr, plus_dm, minus_dm, period)
        dx = compute_dx(str, spdm, smdm)
        adx = (s.dx_acc + dx) / period

        %{s | smooth_tr: str, smooth_plus_dm: spdm, smooth_minus_dm: smdm,
              dx_acc: 0.0, dx_count: 0, adx: adx}

      # Steady state: Wilder smooth ADX
      true ->
        {str, spdm, smdm} = wilder_smooth(s.smooth_tr, s.smooth_plus_dm, s.smooth_minus_dm, tr, plus_dm, minus_dm, period)
        dx = compute_dx(str, spdm, smdm)
        adx = (s.adx * (period - 1) + dx) / period

        %{s | smooth_tr: str, smooth_plus_dm: spdm, smooth_minus_dm: smdm, adx: adx}
    end
  end

  # Directional movement values
  defp dm_values(high, low, _close, prev_high, prev_low, prev_close) do
    tr = Enum.max([high - low, abs(high - prev_close), abs(low - prev_close)])
    up_move = high - prev_high
    down_move = prev_low - low
    plus_dm = if up_move > down_move and up_move > 0, do: up_move, else: 0.0
    minus_dm = if down_move > up_move and down_move > 0, do: down_move, else: 0.0
    {tr, plus_dm, minus_dm}
  end

  # Wilder smoothing: smooth - smooth/period + new
  defp wilder_smooth(str, spdm, smdm, tr, plus_dm, minus_dm, period) do
    {str - str / period + tr, spdm - spdm / period + plus_dm, smdm - smdm / period + minus_dm}
  end

  # DX = 100 * |+DI - -DI| / (+DI + -DI)
  defp compute_dx(smooth_tr, smooth_plus_dm, smooth_minus_dm) when smooth_tr > 0 do
    plus_di = smooth_plus_dm / smooth_tr
    minus_di = smooth_minus_dm / smooth_tr
    di_sum = plus_di + minus_di

    if di_sum == 0.0, do: 0.0, else: 100.0 * abs(plus_di - minus_di) / di_sum
  end

  defp compute_dx(_, _, _), do: 0.0

  # --- Helpers ---

  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v * 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(_), do: 0.0
end
