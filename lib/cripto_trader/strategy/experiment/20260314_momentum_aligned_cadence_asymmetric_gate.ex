defmodule CriptoTrader.Strategy.Experiment.MomentumAlignedCadenceAsymmetricGate20260314 do
  @moduledoc """
  Momentum-alignment adaptive cadence + asymmetric SMA gate + Sharpe-ranked rotation.

  Hypothesis: Combining the two best-performing mechanisms from prior experiments:

  1. Asymmetric SMA gate (13w entry / 20w exit) from SharpeRankAsymmetricGate20260314
     (Val +34.99%, best ever) — captures earlier recovery re-entries without sacrificing
     conservative bear exit protection.

  2. Cross-asset momentum-alignment cadence from MomentumAlignedCadence20260314
     (Val +13.34%) — uses direction consensus (>=4/6 assets with positive 4w return)
     to switch between 1w (aligned bull) and 3w (fragmented/choppy) rebalance,
     reducing churn in choppy markets.

  Both mechanisms were validated independently; this tests whether combining them
  produces non-additive gain. The alignment cadence disciplines the asymmetric gate
  from over-rotating in choppy 2025 OOS periods (its remaining vulnerability).

  Changes vs SharpeRankAsymmetricGate20260314 (Train 196.38%, Val +34.99%):
  - Cadence: fixed 3w → alignment-driven (1w when >=4/6 positive, 3w otherwise)

  Changes vs MomentumAlignedCadence20260314 (Train 146.95%, Val +13.34%):
  - SMA gate: symmetric 20w → asymmetric (13w entry, 20w exit) with stateful tracking

  All other parameters unchanged:
  - momentum_lookback_weeks: 4
  - vol_floor: 0.02 (Sharpe normalization floor)
  - hold_count: 2
  - quote_per_position: 5_000.0
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @exit_gate_weeks 20
  @entry_gate_weeks 13
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
  @vol_floor 0.02
  # 4 of 6 assets must have positive 4w return for "aligned bull" state
  @alignment_threshold 0.667
  # slow cadence in fragmented/choppy markets
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
  # position_map keys are week-aligned timestamps where rebalances were scheduled.
  # At each weekly candle, check if this week's start is a rebalance boundary.

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
  # Combines two mechanisms:
  # 1. Alignment-driven cadence: >=4/6 assets with positive 4w return → 1w rebalance;
  #    else 3w rebalance (reduces churn in choppy/fragmented markets).
  # 2. Asymmetric SMA gate: entry when close > 13w SMA; exit when close < 20w SMA.
  #    Stateful tracking via last_targets: entry gate applied to new positions,
  #    exit gate applied to held positions.

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

    # exit gate (20w) is larger; +momentum+stdev window
    needed = @exit_gate_weeks + @momentum_lookback_weeks + 1

    {position_map, _last_rebalance, _last_targets} =
      Enum.reduce(all_weeks, {%{}, nil, []}, fn week_ms, {acc, last_rebalance_ms, last_targets} ->
        prior_weeks =
          all_weeks
          |> Enum.filter(&(&1 < week_ms))
          |> Enum.take(-needed)

        if length(prior_weeks) < needed do
          {acc, last_rebalance_ms, last_targets}
        else
          alignment_ratio =
            compute_momentum_alignment(symbols_str, weekly_closes, prior_weeks)

          weeks_since_last =
            if last_rebalance_ms,
              do: div(week_ms - last_rebalance_ms, @week_ms),
              else: 999

          should_rebalance =
            cond do
              # aligned bull market: rotate weekly to capture momentum shifts
              alignment_ratio >= @alignment_threshold -> true
              # fragmented/choppy: use slow cadence to reduce noise-driven churn
              weeks_since_last >= @slow_cadence_weeks -> true
              true -> false
            end

          if should_rebalance do
            targets = compute_targets(symbols_str, weekly_closes, prior_weeks, last_targets)
            {Map.put(acc, week_ms, targets), week_ms, targets}
          else
            {acc, last_rebalance_ms, last_targets}
          end
        end
      end)

    position_map
  end

  # Fraction of assets with positive 4w momentum (0.0 to 1.0).
  # >= 0.667 (4 of 6) = aligned bull market → 1w cadence.
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

  # Computes target holdings using asymmetric gate + Sharpe-normalized ranking.
  # last_targets: list of symbols held from the most recent rebalance — used to
  # apply entry gate (13w) to new positions and exit gate (20w) to held positions.
  defp compute_targets(symbols_str, weekly_closes, prior_weeks, last_targets) do
    candidates =
      Enum.flat_map(symbols_str, fn sym ->
        closes = weekly_closes[sym] || %{}
        history = Enum.map(prior_weeks, &Map.get(closes, &1))

        if Enum.any?(history, &is_nil/1) do
          []
        else
          close_last = List.last(history)

          sma_exit =
            Enum.sum(Enum.take(history, -@exit_gate_weeks)) / @exit_gate_weeks

          sma_entry =
            Enum.sum(Enum.take(history, -@entry_gate_weeks)) / @entry_gate_weeks

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

          # Asymmetric gate: held assets use exit gate (20w), new entries use entry gate (13w)
          is_holding = sym in last_targets

          gate_ok =
            if is_holding,
              do: close_last > sma_exit,
              else: close_last > sma_entry

          if gate_ok, do: [{sym, sharpe_score}], else: []
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
