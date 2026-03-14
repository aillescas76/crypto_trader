defmodule CriptoTrader.Strategy.Experiment.VolRegimeCadenceAdxGate20260314 do
  @moduledoc """
  ADX-gated rebalance cadence + Sharpe-normalized momentum rotation.

  Hypothesis: VolRegimeCadence (Train 280.67%, Val -5.31%) captured the best training of
  any strategy by compounding weekly in calm bull regimes. But its vol-ratio discriminator
  (short_vol/long_vol < 1.3 → 1w cadence) failed in validation because crypto has
  persistently elevated baseline vol — making the ratio insensitive to regime differences.
  Both calm-trending and calm-ranging periods produce similar vol ratios, so the 1w cadence
  fires incorrectly in ranging 2025 validation, generating churn without trend capture.

  This variant replaces the vol-ratio discriminator with ADX-based trend detection:
  ADX measures directional STRENGTH (not vol level), correctly distinguishing:
  - Trending regime (ADX > 20): strong directional bias → 1w rebalance (capture momentum)
  - Ranging regime (ADX ≤ 20): choppy, low-bias market → 3w rebalance (reduce churn)

  ADX is computed on weekly OHLC data (aggregated from daily candles) using 14-period
  Wilder's smoothing. Portfolio-average ADX across all 6 assets is used to avoid
  single-asset noise, consistent with the cross-sectional nature of the strategy.

  Changes vs VolRegimeCadence20260314 (Train 280.67%, Val -5.31%):
  - Remove: short_vol/long_vol ratio discriminator
  - Add: 14-period ADX on weekly OHLC per symbol, averaged across portfolio
  - Trending (ADX > 20) → 1w rebalance (unchanged from VolRegimeCadence)
  - Ranging (ADX ≤ 20) → 3w max cadence (CHANGED from 2w; aligns with SharpeRank3w proven +33.81%)
  - All other parameters unchanged:
    Sharpe-normalized ranking, 20w SMA gate, hold_count=2, quote_per_position=5,000
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 20
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
  @vol_floor 0.02
  @adx_period 14
  @adx_threshold 20.0
  # Max cadence when ADX <= threshold (ranging regime)
  @max_cadence_weeks 3
  @week_ms 7 * 24 * 60 * 60 * 1000

  # -- Initialisation --

  def new_state(symbols, _opts \\ []) do
    symbols_str = Enum.map(symbols, &to_string/1)

    cache_dir = Path.join(System.user_home!(), ".cripto_trader/archive_cache")
    fetch_start_ms = 1_577_836_800_000
    fetch_end_ms = System.system_time(:millisecond)

    position_map =
      case ArchiveCandles.fetch(
             symbols: symbols_str,
             interval: "1d",
             start_time: fetch_start_ms,
             end_time: fetch_end_ms,
             cache_dir: cache_dir
           ) do
        {:ok, daily_candles_by_symbol} ->
          build_position_map(symbols_str, daily_candles_by_symbol)

        _ ->
          %{}
      end

    %{
      position_map: position_map,
      current_holdings: %{},
      symbol_last_rebalance: %{}
    }
  end

  # -- Signal --
  # Position map keys are only weeks where a rebalance is scheduled.
  # At each weekly candle, check if this week is a rebalance boundary.

  def signal(%{symbol: symbol, candle: candle}, state) do
    sym = to_string(symbol)
    open_time = candle[:open_time] || candle["open_time"]
    week_ms = div(open_time, @week_ms) * @week_ms

    if Map.get(state.symbol_last_rebalance, sym) == week_ms do
      {[], state}
    else
      new_state = put_in(state, [:symbol_last_rebalance, sym], week_ms)
      target = Map.get(state.position_map, week_ms)

      cond do
        is_nil(target) ->
          {[], new_state}

        Map.has_key?(state.current_holdings, sym) and sym not in target ->
          qty = state.current_holdings[sym]
          order = %{symbol: sym, side: "SELL", quantity: qty}
          new_state2 = update_in(new_state, [:current_holdings], &Map.delete(&1, sym))
          {[order], new_state2}

        not Map.has_key?(state.current_holdings, sym) and sym in target ->
          close = parse_float(candle[:close] || candle["close"])
          qty = @quote_per_position / close
          order = %{symbol: sym, side: "BUY", quantity: qty}
          new_state2 = put_in(new_state, [:current_holdings, sym], qty)
          {[order], new_state2}

        true ->
          {[], new_state}
      end
    end
  end

  def signal(_event, state), do: {[], state}

  # -- Position map construction --
  # For each week W:
  # 1. Compute portfolio-average ADX from weekly OHLC to decide cadence
  # 2. If ADX > threshold → rebalance this week (1w cadence)
  #    If weeks since last rebalance >= max_cadence_weeks → force rebalance
  #    Otherwise → hold (no rebalance)
  # 3. If rebalancing: compute Sharpe-ranked targets

  defp build_position_map(symbols_str, daily_candles_by_symbol) do
    weekly_closes =
      Map.new(symbols_str, fn sym ->
        candles = Map.get(daily_candles_by_symbol, sym, [])
        {sym, weekly_closes_for(candles)}
      end)

    weekly_ohlc =
      Map.new(symbols_str, fn sym ->
        candles = Map.get(daily_candles_by_symbol, sym, [])
        {sym, weekly_ohlc_for(candles)}
      end)

    all_weeks =
      weekly_closes
      |> Map.values()
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()

    # Need: SMA (20w) + momentum+stdev (5w) + ADX lookback (adx_period*2 + 1 weeks)
    # ADX requires adx_period pairs = adx_period+1 weekly OHLC values for first smooth
    # + adx_period more for ADX smooth = 2*adx_period+1 values total
    adx_history_needed = @adx_period * 2 + 1
    needed = @ma_period_weeks + max(@momentum_lookback_weeks + 1, adx_history_needed)

    {position_map, _last_rebalance} =
      Enum.reduce(all_weeks, {%{}, nil}, fn week_ms, {acc, last_rebalance_ms} ->
        prior_weeks =
          all_weeks
          |> Enum.filter(&(&1 < week_ms))
          |> Enum.take(-needed)

        if length(prior_weeks) < needed do
          {acc, last_rebalance_ms}
        else
          adx = compute_portfolio_adx(symbols_str, weekly_ohlc, prior_weeks)

          weeks_since_last =
            if last_rebalance_ms,
              do: div(week_ms - last_rebalance_ms, @week_ms),
              else: 999

          should_rebalance =
            cond do
              # Trending regime: rebalance every week
              adx > @adx_threshold -> true
              # Ranging regime: force rebalance after max_cadence_weeks
              weeks_since_last >= @max_cadence_weeks -> true
              # Ranging regime, not yet at cadence limit: skip
              true -> false
            end

          if should_rebalance do
            targets = compute_targets(symbols_str, weekly_closes, prior_weeks)
            {Map.put(acc, week_ms, targets), week_ms}
          else
            {acc, last_rebalance_ms}
          end
        end
      end)

    position_map
  end

  # -- ADX computation --
  # Computes 14-period ADX on weekly OHLC using Wilder's smoothing.
  # Returns portfolio-average ADX across all symbols.

  defp compute_portfolio_adx(symbols_str, weekly_ohlc_by_sym, prior_weeks) do
    lookback = @adx_period * 2 + 1
    relevant_weeks = Enum.take(prior_weeks, -lookback)

    adx_values =
      Enum.flat_map(symbols_str, fn sym ->
        ohlc_map = Map.get(weekly_ohlc_by_sym, sym, %{})
        weeks_with_data = Enum.filter(relevant_weeks, &Map.has_key?(ohlc_map, &1))

        if length(weeks_with_data) < @adx_period + 2 do
          []
        else
          case compute_symbol_adx(ohlc_map, weeks_with_data) do
            {:ok, adx} -> [adx]
            _ -> []
          end
        end
      end)

    if adx_values == [], do: @adx_threshold, else: Enum.sum(adx_values) / length(adx_values)
  end

  defp compute_symbol_adx(ohlc_map, weeks) do
    n = @adx_period

    # Build TR/+DM/-DM for each consecutive week pair
    dm_data =
      weeks
      |> Enum.map(&Map.get(ohlc_map, &1))
      |> Enum.filter(&(not is_nil(&1)))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [prev, curr] ->
        hl = curr.high - curr.low
        hpc = abs(curr.high - prev.close)
        lpc = abs(curr.low - prev.close)
        tr = Enum.max([hl, hpc, lpc])

        up = curr.high - prev.high
        down = prev.low - curr.low
        pdm = if up > down and up > 0, do: up, else: 0.0
        mdm = if down > up and down > 0, do: down, else: 0.0

        {tr, pdm, mdm}
      end)

    if length(dm_data) < n + 1 do
      {:error, :insufficient_data}
    else
      # Wilder's first smooth: sum of first n values
      {init_tr, init_pdm, init_mdm} =
        dm_data
        |> Enum.take(n)
        |> Enum.reduce({0.0, 0.0, 0.0}, fn {tr, pdm, mdm}, {t, p, m} ->
          {t + tr, p + pdm, m + mdm}
        end)

      # Wilder smooth remaining values, compute DX at each step
      {_, _, _, dx_list} =
        dm_data
        |> Enum.drop(n)
        |> Enum.reduce({init_tr, init_pdm, init_mdm, []}, fn {tr, pdm, mdm},
                                                              {str, spdm, smdm, dxs} ->
          str2 = str - str / n + tr
          spdm2 = spdm - spdm / n + pdm
          smdm2 = smdm - smdm / n + mdm

          pdi = if str2 > 0, do: 100.0 * spdm2 / str2, else: 0.0
          mdi = if str2 > 0, do: 100.0 * smdm2 / str2, else: 0.0
          dx = if pdi + mdi > 0, do: 100.0 * abs(pdi - mdi) / (pdi + mdi), else: 0.0

          {str2, spdm2, smdm2, [dx | dxs]}
        end)

      if dx_list == [] do
        {:error, :no_dx_values}
      else
        # ADX = average of DX values (Wilder's recursive ADX approximation)
        adx = Enum.sum(dx_list) / length(dx_list)
        {:ok, adx}
      end
    end
  end

  # -- Sharpe-ranked targets (same as SharpeNormalizedMomentum line) --

  defp compute_targets(symbols_str, weekly_closes, prior_weeks) do
    candidates =
      Enum.flat_map(symbols_str, fn sym ->
        closes = weekly_closes[sym] || %{}
        history = Enum.map(prior_weeks, &Map.get(closes, &1))

        if Enum.any?(history, &is_nil/1) do
          []
        else
          close_last = List.last(history)
          sma = Enum.sum(Enum.take(history, -@ma_period_weeks)) / @ma_period_weeks
          mom_base = Enum.at(history, length(history) - @momentum_lookback_weeks - 1)

          momentum =
            if mom_base && mom_base > 0,
              do: (close_last - mom_base) / mom_base,
              else: -999.0

          last_5_closes = Enum.take(history, -(@momentum_lookback_weeks + 1))

          weekly_returns =
            last_5_closes
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.map(fn [a, b] ->
              if a > 0, do: (b - a) / a, else: 0.0
            end)

          n = length(weekly_returns)

          stdev =
            if n >= 2 do
              mean_r = Enum.sum(weekly_returns) / n

              variance =
                Enum.sum(Enum.map(weekly_returns, fn r -> (r - mean_r) * (r - mean_r) end)) / n

              :math.sqrt(variance)
            else
              @vol_floor
            end

          sharpe_score = momentum / max(stdev, @vol_floor)

          if close_last > sma, do: [{sym, sharpe_score}], else: []
        end
      end)

    candidates
    |> Enum.sort_by(fn {_, s} -> s end, :desc)
    |> Enum.take(@hold_count)
    |> Enum.map(fn {sym, _} -> sym end)
  end

  # -- Data aggregation --

  defp weekly_closes_for(daily_candles) do
    daily_candles
    |> Enum.group_by(fn c ->
      t = c[:open_time] || c["open_time"]
      div(t, @week_ms) * @week_ms
    end)
    |> Map.new(fn {w, candles} ->
      last = Enum.max_by(candles, fn c -> c[:open_time] || c["open_time"] end)
      {w, parse_float(last[:close] || last["close"])}
    end)
  end

  defp weekly_ohlc_for(daily_candles) do
    daily_candles
    |> Enum.group_by(fn c ->
      t = c[:open_time] || c["open_time"]
      div(t, @week_ms) * @week_ms
    end)
    |> Map.new(fn {w, candles} ->
      highs = Enum.map(candles, &parse_float(&1[:high] || &1["high"]))
      lows = Enum.map(candles, &parse_float(&1[:low] || &1["low"]))
      last = Enum.max_by(candles, fn c -> c[:open_time] || c["open_time"] end)

      {w,
       %{
         high: Enum.max(highs),
         low: Enum.min(lows),
         close: parse_float(last[:close] || last["close"])
       }}
    end)
  end

  # -- Helpers --

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
