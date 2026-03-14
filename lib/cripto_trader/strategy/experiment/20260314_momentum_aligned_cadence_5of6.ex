defmodule CriptoTrader.Strategy.Experiment.MomentumAlignedCadence5of620260314 do
  @moduledoc """
  Cross-asset momentum-alignment cadence with 5/6 threshold + Sharpe-normalized rotation.

  Hypothesis: The MomentumAlignedCadence strategy used a 4/6 (67%) alignment threshold
  to trigger 1w rebalance cadence. This was too permissive: in a 6-asset highly-correlated
  crypto universe, sideways/ranging markets frequently produce 4 of 6 assets with marginally
  positive 4w returns simultaneously, causing false weekly rebalances during choppy validation.
  Raising the threshold to 5/6 (83%) requires genuine bull consensus before switching to
  the faster 1w cadence.

  Changes vs MomentumAlignedCadence20260314 (Train 146.95%, Val +13.34%, +30.27pp margin):
  - alignment_threshold: 4/6 (0.667) → 5/6 (0.833)

  All other parameters unchanged:
  - ma_period_weeks: 20 (per-asset SMA gate)
  - momentum_lookback_weeks: 4
  - vol_floor: 0.02 (Sharpe normalization floor)
  - hold_count: 2
  - slow_cadence_weeks: 3
  - quote_per_position: 5_000.0
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 20
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
  @vol_floor 0.02
  # 5 of 6 assets must have positive 4w return (83% consensus)
  @alignment_threshold 0.833
  # slow cadence in misaligned (choppy) markets
  @slow_cadence_weeks 3
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
          alignment_ratio =
            compute_momentum_alignment(symbols_str, weekly_closes, prior_weeks)

          weeks_since_last =
            if last_rebalance_ms,
              do: div(week_ms - last_rebalance_ms, @week_ms),
              else: 999

          should_rebalance =
            cond do
              # 5/6 aligned bull market: rotate weekly to capture momentum shifts
              alignment_ratio >= @alignment_threshold -> true
              # misaligned / choppy: use slow cadence (3w)
              weeks_since_last >= @slow_cadence_weeks -> true
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

  defp compute_momentum_alignment(symbols_str, weekly_closes, prior_weeks) do
    aligned_count =
      Enum.count(symbols_str, fn sym ->
        closes = weekly_closes[sym] || %{}
        history = Enum.map(prior_weeks, &Map.get(closes, &1))

        if Enum.any?(history, &is_nil/1) do
          false
        else
          close_last = List.last(history)
          mom_base = Enum.at(history, length(history) - @momentum_lookback_weeks - 1)

          if mom_base && mom_base > 0 do
            (close_last - mom_base) / mom_base > 0
          else
            false
          end
        end
      end)

    total = length(symbols_str)
    if total > 0, do: aligned_count / total, else: 0.0
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
