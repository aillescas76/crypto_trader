defmodule CriptoTrader.Strategy.Experiment.MaGatedRotation3w20260314 do
  @moduledoc """
  Per-asset 20-week SMA gate + raw 4-week momentum rotation with 3-week rebalance.

  Hypothesis: 3-week rebalance cadence on raw momentum rotation reduces churn in
  choppy 2025 validation period. MaGatedRotationExtended (2w rebalance) achieved
  Val -12.18% vs 1w's -16.89% — a modest improvement. The SharpeNormalized branch
  shows non-linear benefit at 3w (Val +33.81% vs +25.82% at 2w), suggesting the
  cadence itself has merit independent of signal quality. Testing whether 3w cadence
  alone (without Sharpe normalization) meaningfully reduces rotation churn in choppy
  markets, as a controlled comparison to understand cadence vs quality contributions.

  Changes vs MaGatedRotationExtended (2w rebalance):
  - rebalance_interval: 2 weeks → 3 weeks

  All other parameters unchanged:
  - ma_period_weeks: 20 (per-asset weekly SMA gate)
  - momentum_lookback_weeks: 4 (raw 4w cross-sectional return ranking)
  - hold_count: 2
  - quote_per_position: 5_000.0
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 20
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
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
  # Builds weekly position targets using raw 4w momentum ranking.
  # Signal function looks up at 3-week boundaries (a subset of weekly keys),
  # so every 3-week rebalance boundary resolves to a valid position target.

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

    needed = @ma_period_weeks + @momentum_lookback_weeks

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
              mom_base = Enum.at(history, length(history) - @momentum_lookback_weeks - 1)

              momentum =
                if mom_base && mom_base > 0,
                  do: (close_last - mom_base) / mom_base,
                  else: -999.0

              if close_last > sma, do: [{sym, momentum}], else: []
            end
          end)

        top =
          candidates
          |> Enum.sort_by(fn {_, m} -> m end, :desc)
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
