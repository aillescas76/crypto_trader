defmodule CriptoTrader.Strategy.Experiment.MaGatedRotationSharpeRank13wGate3w20260314 do
  @moduledoc """
  Per-asset 13-week SMA gate + Sharpe-normalized momentum rotation with 3-week rebalance.

  Hypothesis: Reducing the SMA gate from 20w to 13w allows re-entry into recovering assets
  5-7 weeks faster while Sharpe-normalized ranking filters out the false bear-rally re-entries
  that hurt the raw-signal 13w gate (MaGatedRotationSmaGate13w, +15.06pp val margin but
  noisy false entries in training). In combination: 13w provides faster recovery capture;
  SharpeRank (4w_return / max(stdev_4w, 0.02)) scores brief high-vol bear rallies poorly,
  preventing them from ranking into the top-2 hold slots. 3w rebalance gives quality signals
  time to play out without weekly noise interruption.

  Changes vs MaGatedRotationSharpeRank3w20260314 (best baseline: Train +151%, Val +33.81%):
  - ma_period_weeks: 20 weeks → 13 weeks

  All other parameters unchanged:
  - momentum_lookback_weeks: 4
  - vol_floor: 0.02 (Sharpe normalization floor)
  - hold_count: 2
  - rebalance_interval: 3 weeks
  - quote_per_position: 5_000.0
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 13
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
  # Builds weekly position targets using Sharpe-normalized ranking.
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

    # +1 extra for computing 4 weekly returns from 5 consecutive weekly closes
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
