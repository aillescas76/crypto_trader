defmodule CriptoTrader.Strategy.Experiment.MaGatedRotationEntryBuffer20260313 do
  @moduledoc """
  Per-asset 20-week SMA gate with 3% entry buffer + 4-week raw cross-sectional momentum rotation.

  Hypothesis: Requiring price to be 3% above the 20w SMA before an asset qualifies for rotation
  reduces whipsaw entries at the SMA boundary in choppy markets. In 2025 validation, assets
  repeatedly crossed the SMA threshold creating noisy entry/exit cycles. A 3% buffer filters
  these false breakouts while not delaying genuine bull-market entries (which occur when assets
  are well above SMA). Ranking is raw 4w return (unchanged from base MaGatedRotation).

  Only change vs MaGatedRotation20260313 base:
  - Gate condition: `close_last > sma * 1.03` instead of `close_last > sma`
  - All other parameters unchanged: raw 4w return ranking, 20w SMA period, hold_count=2,
    1w rebalance, $5k/position

  Parameters:
  - ma_period_weeks: 20
  - sma_entry_buffer: 0.03 (3% above SMA required before qualifying)
  - momentum_lookback_weeks: 4
  - hold_count: 2
  - quote_per_position: 5_000.0
  - rebalance: 1 week
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 20
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
  @sma_entry_buffer 0.03
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

              # Entry buffer: require 3% above SMA before qualifying
              if close_last > sma * (1.0 + @sma_entry_buffer),
                do: [{sym, momentum}],
                else: []
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
