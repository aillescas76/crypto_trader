defmodule CriptoTrader.Strategy.Experiment.SharpeRankAsymmetricGate20260314 do
  @moduledoc """
  Asymmetric SMA gate + Sharpe-normalized momentum rotation with 3-week rebalance.

  Hypothesis: Decoupling the entry and exit SMA thresholds captures earlier recovery
  re-entries (via the responsive 13w SMA) without sacrificing the conservative bear
  protection of the 20w SMA. MaGatedRotationSharpeRank13wGate3w showed 13w/13w gate
  reduces validation margin to +43.52pp vs 20w/20w baseline's +50.74pp, because a
  symmetric 13w gate admits noisy false re-entries in choppy 2025 OOS. With an
  asymmetric gate (enter at 13w, exit at 20w), the entry is responsive while the
  exit remains conservative: once we're in an asset, we stay until the slower 20w
  SMA confirms a bear, reducing false sell-then-rebuy cycles.

  Changes vs MaGatedRotationSharpeRank3w20260314 (Train 151.3%, Val +33.81%):
  - entry_gate_weeks: 20 → 13 (more responsive recovery re-entry)
  - exit_gate_weeks: remains 20 (conservative bear detection)
  - Stateful asymmetric gate: tracks holdings across rebalance periods to apply
    the correct threshold (13w for entry, 20w for exit)

  All other parameters unchanged:
  - rebalance_interval: 3 weeks
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
  # Uses asymmetric SMA gate with stateful tracking of held positions:
  # - Entry gate (13w SMA): asset can be entered if close > sma_13w
  # - Exit gate (20w SMA): asset must be exited if close < sma_20w
  # last_targets tracks holdings at each epoch-aligned 3-week boundary so the
  # gate applied (entry vs exit) correctly reflects the current holding state.

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

    # @exit_gate_weeks (20) is the larger window; +1 for weekly return computation
    needed = @exit_gate_weeks + @momentum_lookback_weeks + 1

    # last_targets: assets held from the most recent epoch-aligned 3-week rebalance.
    # Updated only at @rebalance_ms-aligned boundaries so the asymmetric gate
    # correctly reflects actual holdings rather than intermediate weekly signals.
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

                # Asymmetric gate logic:
                # - Currently holding → need close > 20w SMA to stay (conservative exit)
                # - Not holding      → need close > 13w SMA to enter (responsive re-entry)
                is_holding = sym in last_targets

                gate_ok =
                  if is_holding,
                    do: close_last > sma_20w,
                    else: close_last > sma_13w

                if gate_ok, do: [{sym, sharpe_score}], else: []
              end
            end)

          top =
            candidates
            |> Enum.sort_by(fn {_, s} -> s end, :desc)
            |> Enum.take(@hold_count)
            |> Enum.map(fn {sym, _} -> sym end)

          # Only update last_targets at epoch-aligned 3-week rebalance boundaries.
          # These are the same timestamps the signal function resolves to via
          # div(open_time, @rebalance_ms) * @rebalance_ms, ensuring the gate state
          # correctly tracks actual holdings at the point each trade is executed.
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
