defmodule CriptoTrader.Strategy.Experiment.MomentumAlignedCadenceStrength20260314 do
  @moduledoc """
  Continuous alignment-strength cadence + Sharpe-normalized rotation.

  Hypothesis: The MomentumAlignedCadence investigation established that binary alignment
  count (4/6 vs 5/6 threshold) is ineffective because in a 6-asset correlated crypto
  universe, momentum alignment is quasi-binary — assets are either all trending or
  fragmented, rarely landing between 4 and 5. The untried improvement: replace the
  binary COUNT with a continuous STRENGTH signal (sum of all 6 assets' 4w returns),
  then drive a 3-tier cadence (1w/2w/3w) based on strength thresholds.

  The strength signal captures the MAGNITUDE of consensus: 4 assets each up 30%
  (strength ≈ 1.20) is fundamentally different from 4 assets each up 2% (strength ≈ 0.08),
  though both trigger a 1w cadence under the binary 4/6 rule. The intermediate 2w tier
  handles marginal alignment that shouldn't trigger aggressive weekly rotation.

  Changes vs MomentumAlignedCadence20260314 (Train 146.95%, Val +13.34%, MaxDD 26.1%):
  - Discriminator: binary count ratio (>=0.667) → continuous sum of 4w returns
  - Cadence: 2-tier (1w / 3w) → 3-tier (1w / 2w / 3w)
    - alignment_strength > 0.50 → 1w (strong bull, rotate aggressively)
    - alignment_strength > 0.15 → 2w (moderate alignment, balanced rotation)
    - alignment_strength <= 0.15 → 3w (fragmented/choppy, preserve quality signals)

  All other parameters unchanged:
  - ma_period_weeks: 20 (per-asset SMA gate)
  - momentum_lookback_weeks: 4
  - vol_floor: 0.02 (Sharpe normalization floor)
  - hold_count: 2
  - quote_per_position: 5_000.0
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 20
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
  @vol_floor 0.02
  @week_ms 7 * 24 * 60 * 60 * 1000

  # Cadence thresholds: sum of all 6 assets' 4w returns
  # >0.50 → 1w (strong bull: e.g. average asset up ~8%+ over 4w)
  # >0.15 → 2w (moderate alignment: e.g. average asset up ~2.5%+ over 4w)
  # else  → 3w (weak/mixed: fragmented signals)
  @strong_bull_threshold 0.50
  @moderate_bull_threshold 0.15

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
  # position_map keys are only the weeks where a rebalance is scheduled.

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

  defp build_position_map(symbols_str, daily_candles_by_symbol) do
    weekly_closes =
      Map.new(symbols_str, fn sym ->
        candles = Map.get(daily_candles_by_symbol, sym, [])
        {sym, weekly_closes_for(candles)}
      end)

    all_weeks =
      weekly_closes
      |> Map.values()
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()

    # Need: ma_period (20w) + momentum+stdev (5w) = 25 weeks minimum
    needed = @ma_period_weeks + @momentum_lookback_weeks + 1

    {position_map, _last_rebalance} =
      Enum.reduce(all_weeks, {%{}, nil}, fn week_ms, {acc, last_rebalance_ms} ->
        prior_weeks =
          all_weeks
          |> Enum.filter(&(&1 < week_ms))
          |> Enum.take(-needed)

        if length(prior_weeks) < needed do
          {acc, last_rebalance_ms}
        else
          alignment_strength =
            compute_alignment_strength(symbols_str, weekly_closes, prior_weeks)

          weeks_since_last =
            if last_rebalance_ms,
              do: div(week_ms - last_rebalance_ms, @week_ms),
              else: 999

          # 3-tier cadence based on continuous alignment strength
          required_weeks =
            cond do
              alignment_strength > @strong_bull_threshold -> 1
              alignment_strength > @moderate_bull_threshold -> 2
              true -> 3
            end

          should_rebalance = weeks_since_last >= required_weeks

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

  # Computes the sum of all 6 assets' 4w returns.
  # Range: roughly -6.0 (all down 100%) to unbounded positive.
  # Positive values indicate bullish consensus; higher = stronger consensus.
  defp compute_alignment_strength(symbols_str, weekly_closes, prior_weeks) do
    Enum.reduce(symbols_str, 0.0, fn sym, acc ->
      closes = weekly_closes[sym] || %{}
      history = Enum.map(prior_weeks, &Map.get(closes, &1))

      if Enum.any?(history, &is_nil/1) do
        acc
      else
        close_last = List.last(history)
        mom_base = Enum.at(history, length(history) - @momentum_lookback_weeks - 1)

        momentum =
          if mom_base && mom_base > 0,
            do: (close_last - mom_base) / mom_base,
            else: 0.0

        acc + momentum
      end
    end)
  end

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
