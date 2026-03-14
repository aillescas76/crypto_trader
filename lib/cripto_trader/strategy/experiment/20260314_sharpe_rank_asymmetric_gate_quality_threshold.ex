defmodule CriptoTrader.Strategy.Experiment.SharpeRankAsymmetricGateQualityThreshold20260314 do
  @moduledoc """
  Asymmetric SMA gate + Sharpe-normalized momentum rotation + minimum Sharpe threshold.

  Hypothesis: Adding a minimum Sharpe score threshold (>= 0.5) to the asymmetric gate
  (13w entry / 20w exit) filters noisy early-recovery entries that drive the 94.31%
  training MaxDD, without sacrificing the validation improvement from earlier re-entry.

  The asymmetric gate's MaxDD problem stems from admitting early-recovery assets with
  transiently positive momentum but high volatility (low Sharpe scores). A threshold
  of 0.5 requires both: (1) qualifying by the entry gate (above 13w SMA), AND (2)
  having a quality-adjusted signal (Sharpe score >= 0.5). Relief rallies with high
  noise fail the threshold; genuine persistent recoveries pass.

  Changes vs SharpeRankAsymmetricGate20260314 (Train 196.38%, Val 34.99%, MaxDD 94.31%):
  - sharpe_threshold: none → 0.5 (minimum Sharpe score to qualify for selection)
  - An asset must rank in top-2 AND have sharpe_score >= 0.5 to be entered
  - Held positions are not affected mid-period; threshold applies at entry only

  All other parameters unchanged:
  - entry_gate_weeks: 13 (asymmetric entry — responsive re-entry)
  - exit_gate_weeks: 20 (asymmetric exit — conservative bear detection)
  - rebalance_interval: 3 weeks
  - momentum_lookback_weeks: 4
  - vol_floor: 0.02
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
  @sharpe_threshold 0.5
  @week_ms 7 * 24 * 60 * 60 * 1000
  @rebalance_ms 3 * @week_ms

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
    rebalance_ms = div(open_time, @rebalance_ms) * @rebalance_ms

    if Map.get(state.symbol_last_rebalance, sym) == rebalance_ms do
      {[], state}
    else
      new_state = put_in(state, [:symbol_last_rebalance, sym], rebalance_ms)
      target = Map.get(state.position_map, rebalance_ms)

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
  # Uses asymmetric SMA gate with stateful tracking + Sharpe quality threshold.
  # Entry gate: close > 13w SMA (responsive re-entry)
  # Exit gate:  close > 20w SMA (conservative bear detection)
  # Quality gate: sharpe_score >= @sharpe_threshold (filters noisy early-recovery entries)
  # Only NEW entries require the quality threshold; held positions exit on the 20w gate.

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

    needed = @exit_gate_weeks + @momentum_lookback_weeks + 1

    {position_map, _last_targets} =
      Enum.reduce(all_weeks, {%{}, []}, fn week_ms, {acc, last_targets} ->
        prior_weeks =
          all_weeks
          |> Enum.filter(&(&1 < week_ms))
          |> Enum.take(-needed)

        if length(prior_weeks) < needed do
          {acc, last_targets}
        else
          candidates =
            Enum.flat_map(symbols_str, fn sym ->
              closes = weekly_closes[sym] || %{}
              history = Enum.map(prior_weeks, &Map.get(closes, &1))

              if Enum.any?(history, &is_nil/1) do
                []
              else
                close_last = List.last(history)

                sma_20w =
                  Enum.sum(Enum.take(history, -@exit_gate_weeks)) / @exit_gate_weeks

                sma_13w =
                  Enum.sum(Enum.take(history, -@entry_gate_weeks)) / @entry_gate_weeks

                mom_base = Enum.at(history, length(history) - @momentum_lookback_weeks - 1)

                momentum =
                  if mom_base && mom_base > 0,
                    do: (close_last - mom_base) / mom_base,
                    else: -999.0

                last_5_closes =
                  history
                  |> Enum.take(-(@momentum_lookback_weeks + 1))

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
                      Enum.sum(
                        Enum.map(weekly_returns, fn r -> (r - mean_r) * (r - mean_r) end)
                      ) / n

                    :math.sqrt(variance)
                  else
                    @vol_floor
                  end

                sharpe_score = momentum / max(stdev, @vol_floor)

                is_holding = sym in last_targets

                # Asymmetric gate: exit threshold (20w) for held, entry threshold (13w) for new
                gate_ok =
                  if is_holding,
                    do: close_last > sma_20w,
                    else: close_last > sma_13w

                # Quality threshold: new entries must meet minimum Sharpe score.
                # Held positions are only subject to the exit gate (not the quality filter),
                # preventing premature exit of positions that dip below threshold mid-hold.
                quality_ok = is_holding or sharpe_score >= @sharpe_threshold

                if gate_ok and quality_ok, do: [{sym, sharpe_score}], else: []
              end
            end)

          top =
            candidates
            |> Enum.sort_by(fn {_, s} -> s end, :desc)
            |> Enum.take(@hold_count)
            |> Enum.map(fn {sym, _} -> sym end)

          is_rebalance_week = rem(week_ms, @rebalance_ms) == 0
          new_last_targets = if is_rebalance_week, do: top, else: last_targets

          {Map.put(acc, week_ms, top), new_last_targets}
        end
      end)

    position_map
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
