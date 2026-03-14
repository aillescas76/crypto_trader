defmodule CriptoTrader.Strategy.Experiment.VolRegimeCadence8w20260314 do
  @moduledoc """
  Volatility-regime conditioned rebalance cadence + Sharpe-normalized momentum.
  Short vol window increased to 8w to reduce false-calm readings.

  Hypothesis: The original VolRegimeCadence (4w short_vol window, threshold=1.3) suffered
  from false-calm readings in 2025 validation — transient vol dips below the threshold
  triggered unnecessary weekly rebalances during choppy ranging periods. Increasing the
  short_vol window from 4w to 8w smooths the volatility estimate, reducing sensitivity to
  transient dips while preserving the ability to detect genuine sustained-calm trending
  periods (like bull 2023-2024 where vol stayed consistently low for months).

  Changes vs VolRegimeCadence20260314 (Train 280.67%, Val -5.31%, +11.6pp margin):
  - short_vol_window: 4 weeks → 8 weeks

  All other parameters unchanged:
  - long_vol_window: 12 weeks (vol baseline)
  - vol_ratio_threshold: 1.3 (calm vs elevated regime boundary)
  - Rebalance: 1w if vol_ratio < 1.3, else max 2w
  - 20-week per-asset SMA gate, Sharpe-normalized ranking, hold_count=2
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 20
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
  @vol_floor 0.02
  @short_vol_window 8
  @long_vol_window 12
  @vol_ratio_threshold 1.3
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
  # position_map keys are only the weeks where a rebalance is scheduled.
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

    # Need enough history for: SMA (20w) + momentum+stdev (5w) and long_vol (13w)
    # short_vol_window (8w) < long_vol_window (12w), binding constraint: max(5, 13) = 13
    needed = @ma_period_weeks + max(@momentum_lookback_weeks + 1, @long_vol_window + 1)

    {position_map, _last_rebalance} =
      Enum.reduce(all_weeks, {%{}, nil}, fn week_ms, {acc, last_rebalance_ms} ->
        prior_weeks =
          all_weeks
          |> Enum.filter(&(&1 < week_ms))
          |> Enum.take(-needed)

        if length(prior_weeks) < needed do
          {acc, last_rebalance_ms}
        else
          vol_ratio = compute_portfolio_vol_ratio(symbols_str, weekly_closes, prior_weeks)

          weeks_since_last =
            if last_rebalance_ms,
              do: div(week_ms - last_rebalance_ms, @week_ms),
              else: 999

          should_rebalance =
            cond do
              vol_ratio < @vol_ratio_threshold -> true
              weeks_since_last >= 2 -> true
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

  defp compute_portfolio_vol_ratio(symbols_str, weekly_closes, prior_weeks) do
    # short_vol = stdev of last @short_vol_window weekly returns (8w window = 9 closes)
    # long_vol  = stdev of last @long_vol_window weekly returns (12w window = 13 closes)
    ratios =
      Enum.flat_map(symbols_str, fn sym ->
        closes = weekly_closes[sym] || %{}
        history = Enum.map(prior_weeks, &Map.get(closes, &1))

        if Enum.any?(history, &is_nil/1) do
          []
        else
          short_closes = Enum.take(history, -(@short_vol_window + 1))
          long_closes = Enum.take(history, -(@long_vol_window + 1))

          short_vol = weekly_return_stdev(short_closes)
          long_vol = weekly_return_stdev(long_closes)

          if long_vol > 0.001, do: [short_vol / long_vol], else: []
        end
      end)

    if ratios == [], do: 1.0, else: Enum.sum(ratios) / length(ratios)
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

  defp weekly_return_stdev(closes) when length(closes) < 2, do: @vol_floor

  defp weekly_return_stdev(closes) do
    returns =
      closes
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> if a > 0, do: (b - a) / a, else: 0.0 end)

    n = length(returns)

    if n < 2 do
      @vol_floor
    else
      mean_r = Enum.sum(returns) / n
      variance = Enum.sum(Enum.map(returns, fn r -> (r - mean_r) * (r - mean_r) end)) / n
      :math.sqrt(variance)
    end
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
