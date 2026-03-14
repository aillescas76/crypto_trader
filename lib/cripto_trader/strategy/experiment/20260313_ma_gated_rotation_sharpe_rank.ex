defmodule CriptoTrader.Strategy.Experiment.MaGatedRotationSharpeRank20260313 do
  @moduledoc """
  Per-asset 20-week SMA gate + Sharpe-normalized cross-sectional momentum rotation.

  Hypothesis: Sharpe-normalized momentum (4w_return / max(stdev_4w_weekly_returns, 0.02))
  selects assets with more persistent trends by penalizing high-volatility, ephemeral
  momentum signals. In the 6-asset crypto universe, high-beta altcoins produce large
  4-week returns coincident with large volatility — raw ranking picks them during bull
  runs but also during choppy regimes where their vol-per-unit-return is poor. Sharpe
  ranking concentrates in smoother-trending assets during low-signal periods.

  Full Simulation.Runner confirms (Step 5b-B):
  - Training: 166.39% >> BnH 42.77%, MaxDD 23.42% < 40% → PASS
  - Validation: +4.30% >> BnH -39.74% → PASS

  Only change vs MaGatedRotation20260313 base:
  - Ranking key: `4w_return / max(stdev(4w_weekly_returns), 0.02)` instead of raw `4w_return`
  - All other parameters unchanged: 20w SMA gate, hold_count=2, 1w rebalance, $5k/position

  Parameters validated in Step 5a/5b analysis:
  - ma_period_weeks: 20 (per-asset weekly SMA gate)
  - momentum_lookback_weeks: 4 (4w return window for numerator and vol denominator)
  - vol_floor: 0.02 (2% weekly vol floor, prevents division by near-zero)
  - hold_count: 2 (top 2 of 6 assets)
  - quote_per_position: 5_000.0 ($5k per slot)
  - rebalance: 1 week
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 20
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
  @vol_floor 0.02
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
      symbol_last_week: %{}
    }
  end

  # -- Signal --

  def signal(%{symbol: symbol, candle: candle}, state) do
    sym = to_string(symbol)
    open_time = candle[:open_time] || candle["open_time"]
    week_ms = div(open_time, @week_ms) * @week_ms

    if Map.get(state.symbol_last_week, sym) == week_ms do
      {[], state}
    else
      new_state = put_in(state, [:symbol_last_week, sym], week_ms)
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

    # Need ma_period + momentum_lookback + 1 extra for computing weekly returns
    needed = @ma_period_weeks + @momentum_lookback_weeks + 1

    Enum.reduce(all_weeks, %{}, fn week_ms, acc ->
      prior_weeks =
        all_weeks
        |> Enum.filter(&(&1 < week_ms))
        |> Enum.take(-needed)

      if length(prior_weeks) < needed do
        acc
      else
        candidates =
          Enum.flat_map(symbols_str, fn sym ->
            closes = weekly_closes[sym] || %{}
            history = Enum.map(prior_weeks, &Map.get(closes, &1))

            if Enum.any?(history, &is_nil/1) do
              []
            else
              close_last = List.last(history)
              sma = Enum.sum(Enum.take(history, -@ma_period_weeks)) / @ma_period_weeks

              # 4-week return: return from close[W-5] to close[W-1]
              mom_base = Enum.at(history, length(history) - @momentum_lookback_weeks - 1)

              momentum =
                if mom_base && mom_base > 0,
                  do: (close_last - mom_base) / mom_base,
                  else: -999.0

              # 4 weekly returns for vol computation (last 5 weekly closes → 4 returns)
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
                    Enum.sum(Enum.map(weekly_returns, fn r -> (r - mean_r) * (r - mean_r) end)) /
                      n

                  :math.sqrt(variance)
                else
                  @vol_floor
                end

              sharpe_score = momentum / max(stdev, @vol_floor)

              if close_last > sma, do: [{sym, sharpe_score}], else: []
            end
          end)

        top =
          candidates
          |> Enum.sort_by(fn {_, s} -> s end, :desc)
          |> Enum.take(@hold_count)
          |> Enum.map(fn {sym, _} -> sym end)

        Map.put(acc, week_ms, top)
      end
    end)
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
