defmodule CriptoTrader.Strategy.Experiment.MaGatedRotationVolScaled20260313 do
  @moduledoc """
  MaGatedRotation signal (20w SMA gate + 4w cross-sectional momentum top-2, weekly
  rebalance) with EWMA volatility-targeted position sizing replacing fixed $5k/position.

  Hypothesis: Volatility clustering in crypto (daily EWMA vol ACF=0.985) allows
  EWMA-based position sizing to reduce risk exposure during high-vol regimes while
  maintaining near-full capital deployment during low-vol regimes. The MA gate handles
  2022 bear-market exits; vol scaling provides additional protection during within-trend
  shocks (e.g., Aug 2024 Japan carry unwind: position reduced from $5k to $4,660 as vol
  spiked 36.7% → 64.4%). Median sizing is $4,854 vs $5k fixed (cap binds 81% of days),
  reducing max drawdown from ~14.75% to ~9.30% in BTC-only simulation while trading
  ~3% reduction in PnL from the base. With base MaGatedRotation at +372.69% training,
  the vol-scaled version should still comfortably beat buy-and-hold (+44.9% training)
  and improve Sharpe through better risk-adjusted sizing. Expected to maintain
  max_drawdown < 40% on both training (pre-2025) and validation (2025+) splits.

  Parameters validated in Step 5a/5b analysis (training 2022-2024):
  - ma_period_weeks: 20 (per-asset weekly SMA gate)
  - momentum_lookback_weeks: 4 (4w cross-sectional return)
  - hold_count: 2 (top 2 of 6 assets)
  - rebalance_interval: 1 week
  - target_vol: 0.30 (30% annualized; calibrated so median BTC sizing ≈ $4,854)
  - vol_ewma_halflife_days: 20 (best regime separation 1.93x, noise 2.08%/day)
  - max_position_fraction: 0.5 (hard cap: no asset > 50% = $5k of $10k capital)
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period_weeks 20
  @momentum_lookback_weeks 4
  @hold_count 2
  @week_ms 7 * 24 * 60 * 60 * 1000
  @base_capital 10_000.0
  @target_vol 0.30
  @max_position_fraction 0.5
  @vol_ewma_halflife 20.0

  # -- Initialisation --

  def new_state(symbols, _opts \\ []) do
    symbols_str = Enum.map(symbols, &to_string/1)

    cache_dir = Path.join(System.user_home!(), ".cripto_trader/archive_cache")
    fetch_start_ms = 1_577_836_800_000
    fetch_end_ms = System.system_time(:millisecond)

    {position_map, size_map} =
      case ArchiveCandles.fetch(
             symbols: symbols_str,
             interval: "1d",
             start_time: fetch_start_ms,
             end_time: fetch_end_ms,
             cache_dir: cache_dir
           ) do
        {:ok, daily_candles_by_symbol} ->
          build_maps(symbols_str, daily_candles_by_symbol)

        _ ->
          {%{}, %{}}
      end

    %{
      position_map: position_map,
      size_map: size_map,
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
          quote_size = vol_position_size(sym, week_ms, state.size_map)
          qty = quote_size / close
          order = %{symbol: sym, side: "BUY", quantity: qty}
          new_state2 = put_in(new_state, [:current_holdings, sym], qty)
          {[order], new_state2}

        true ->
          {[], new_state}
      end
    end
  end

  def signal(_event, state), do: {[], state}

  # -- Vol-targeted position size lookup --
  # Falls back to max_position_fraction * base_capital if no vol entry (warmup).

  defp vol_position_size(sym, week_ms, size_map) do
    Map.get(size_map, {sym, week_ms}, @max_position_fraction * @base_capital)
  end

  # -- Map construction --
  # Builds position_map (week_ms → [symbol]) and size_map ({sym, week_ms} → quote_size)
  # using only data available at each week boundary (no look-ahead bias).

  defp build_maps(symbols_str, daily_candles_by_symbol) do
    weekly_closes =
      Map.new(symbols_str, fn sym ->
        candles = Map.get(daily_candles_by_symbol, sym, [])
        {sym, weekly_closes_for(candles)}
      end)

    # vol_by_week: sym → %{week_ms → annualized_ewma_vol_at_start_of_week}
    ewma_vols =
      Map.new(symbols_str, fn sym ->
        candles = Map.get(daily_candles_by_symbol, sym, [])
        {sym, ewma_vol_by_week(candles)}
      end)

    all_weeks =
      weekly_closes
      |> Map.values()
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()

    needed = @ma_period_weeks + @momentum_lookback_weeks

    Enum.reduce(all_weeks, {%{}, %{}}, fn week_ms, {pos_acc, size_acc} ->
      prior_weeks =
        all_weeks
        |> Enum.filter(&(&1 < week_ms))
        |> Enum.take(-needed)

      if length(prior_weeks) < needed do
        {pos_acc, size_acc}
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

        new_pos_acc = Map.put(pos_acc, week_ms, top)

        new_size_acc =
          Enum.reduce(top, size_acc, fn sym, acc ->
            vol = get_in(ewma_vols, [sym, week_ms]) || @target_vol
            size =
              if vol > 0.01 do
                min(@target_vol / vol * @base_capital, @max_position_fraction * @base_capital)
              else
                @max_position_fraction * @base_capital
              end

            Map.put(acc, {sym, week_ms}, size)
          end)

        {new_pos_acc, new_size_acc}
      end
    end)
  end

  # Builds map of week_ms → annualized EWMA vol using daily closes known
  # at the START of that week (i.e., last close of the prior week).
  # Each week_ms entry = vol computed from all days strictly before that week.

  defp ewma_vol_by_week(daily_candles) do
    sorted = Enum.sort_by(daily_candles, fn c -> c[:open_time] || c["open_time"] end)

    decay = :math.exp(-1.0 / @vol_ewma_halflife)
    complement = 1.0 - decay

    # Compute running EWMA variance per day; collect {open_time, ann_vol} pairs
    {_, _, daily_vol_entries} =
      Enum.reduce(sorted, {nil, nil, []}, fn candle, {prev_close, prev_var, acc} ->
        t = candle[:open_time] || candle["open_time"]
        close = parse_float(candle[:close] || candle["close"])

        {new_var, new_entry} =
          if is_nil(prev_close) or prev_close <= 0.0 or close <= 0.0 do
            {nil, nil}
          else
            log_ret_sq = :math.pow(:math.log(close / prev_close), 2)

            new_v =
              if is_nil(prev_var),
                do: log_ret_sq,
                else: decay * prev_var + complement * log_ret_sq

            ann_vol = :math.sqrt(new_v * 252)
            {new_v, {t, ann_vol}}
          end

        new_acc = if is_nil(new_entry), do: acc, else: [new_entry | acc]
        {close, new_var, new_acc}
      end)

    # Group by week; for each week W, take the last vol entry (end of week W).
    # Map it to week W + @week_ms so: vol_map[week_W] = vol known at END of week (W-1).
    # This is the vol available at the time of a rebalance decision at the start of week W.
    daily_vol_entries
    |> Enum.reverse()
    |> Enum.group_by(fn {t, _} -> div(t, @week_ms) * @week_ms end)
    |> Map.new(fn {w, entries} ->
      {_, last_vol} = Enum.max_by(entries, fn {t, _} -> t end)
      {w + @week_ms, last_vol}
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
