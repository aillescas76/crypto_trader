defmodule CriptoTrader.Strategy.Experiment.MaGatedRotation20260313 do
  @moduledoc """
  Per-asset 20-week SMA gate + 4-week cross-sectional momentum rotation.

  Hypothesis: Cross-sectional momentum among crypto assets creates a positive edge
  because recent outperformers tend to continue outperforming laggards at 4-week
  horizons, while a per-asset 20-week SMA filter prevents holding assets in
  confirmed downtrends. The signal rebalances weekly, holding the top 2 qualifying
  assets (those above their own 20-week SMA, ranked by 4-week return). The per-asset
  MA filter limits bear-market exposure: in 2022, all tested symbols fell below
  their MAs from January onward, keeping max drawdown near 0% vs BnH -50%.
  Expected to beat buy-and-hold (~70-77% in 3-symbol training) AND achieve
  max_drawdown < 40% on both training (pre-2025) and validation (2025+) splits.

  Parameters from Step 5a/5b analysis (training 2022-2024):
  - ma_period_weeks: 20 (per-asset weekly SMA gate — most robust of 13/20/52 tested)
  - momentum_lookback_weeks: 4 (4w better than 2w noisy, similar to 8w)
  - hold_count: 2 (top 2 of 6 assets held at all times)
  - quote_per_position: 5000.0 (half of $10k initial balance per held asset)

  Implementation: pre-loads daily candles in new_state to build a weekly
  position_map (week_start_ms → [symbol_str, ...]). Signal function fires once
  per week per symbol and issues BUY/SELL as rotation dictates.
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 20
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
  @week_ms 7 * 24 * 60 * 60 * 1000

  # -- Initialisation --

  def new_state(symbols, _opts \\ []) do
    symbols_str = Enum.map(symbols, &to_string/1)

    cache_dir = Path.join(System.user_home!(), ".cripto_trader/archive_cache")
    # Start from 2020-01-01 to ensure 20-week warmup before 2022 training data
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
          # Warmup period or no position map entry — hold cash
          {[], new_state}

        Map.has_key?(state.current_holdings, sym) and sym not in target ->
          # Exit: symbol dropped from top-K or fell below MA gate
          qty = state.current_holdings[sym]
          order = %{symbol: sym, side: "SELL", quantity: qty}
          new_state2 = update_in(new_state, [:current_holdings], &Map.delete(&1, sym))
          {[order], new_state2}

        not Map.has_key?(state.current_holdings, sym) and sym in target ->
          # Enter: symbol newly in top-K and above MA gate
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
  # For each week boundary W, determines which symbols to hold during week W.
  # Uses only data from prior weeks to avoid look-ahead bias.

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
        # Insufficient history — skip (warmup)
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
              # 4-week momentum: return from close[W-5] to close[W-1]
              mom_base = Enum.at(history, length(history) - @momentum_lookback_weeks - 1)

              momentum =
                if mom_base && mom_base > 0,
                  do: (close_last - mom_base) / mom_base,
                  else: -999.0

              # Only include symbols above their 20-week MA
              if close_last > sma, do: [{sym, momentum}], else: []
            end
          end)

        top =
          candidates
          |> Enum.sort_by(fn {_, m} -> m end, :desc)
          |> Enum.take(@hold_count)
          |> Enum.map(fn {sym, _} -> sym end)

        # Empty list means all symbols below MA → go to cash
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
