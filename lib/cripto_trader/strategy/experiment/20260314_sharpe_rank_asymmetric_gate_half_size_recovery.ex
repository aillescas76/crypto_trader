defmodule CriptoTrader.Strategy.Experiment.SharpeRankAsymmetricGateHalfSizeRecovery20260314 do
  @moduledoc """
  Asymmetric SMA gate + Sharpe-normalized rotation + 50w SMA half-size filter.

  Hypothesis: SharpeRankAsymmetricGate (Train 196.38%, Val +34.99%) passes on Sharpe
  but has catastrophic training MaxDD of 94.31%. The root cause: the 13w entry gate
  admits assets in early recovery phases that subsequently decline further before the
  20w exit gate fires. Half-sizing these early-recovery entries (below 50w SMA) reduces
  capital at risk while preserving the recovery-capture upside. Assets confirmed above
  their 50w SMA are in a stronger trend and merit full sizing.

  Changes vs SharpeRankAsymmetricGate20260314 (Train 196.38%, Val +34.99%, MaxDD 94.31%):
  - Add 50w SMA computation at each rebalance week
  - NEW position entry below 50w SMA: 2,500 USDC (half-size — early recovery confirmation pending)
  - NEW position entry above 50w SMA: 5,000 USDC (full-size — trend confirmed by longer MA)
  - HELD positions: always full 5,000 USDC (never downsize held winners; exit gate handles exit)

  All other parameters unchanged:
  - entry_gate_weeks: 13 (responsive re-entry)
  - exit_gate_weeks: 20 (conservative bear detection)
  - rebalance_interval: 3 weeks
  - momentum_lookback_weeks: 4
  - vol_floor: 0.02 (Sharpe normalization floor)
  - hold_count: 2
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @exit_gate_weeks 20
  @entry_gate_weeks 13
  # 50w SMA: secondary confirmation threshold for full sizing
  @size_gate_weeks 50
  @momentum_lookback_weeks 4
  @hold_count 2
  @quote_per_position 5_000.0
  @half_quote_per_position 2_500.0
  @vol_floor 0.02
  @week_ms 7 * 24 * 60 * 60 * 1000
  @rebalance_ms 3 * @week_ms

  # -- Initialisation --

  def new_state(symbols, _opts \\ []) do
    symbols_str = Enum.map(symbols, &to_string/1)

    cache_dir = Path.join(System.user_home!(), ".cripto_trader/archive_cache")
    fetch_start_ms = 1_577_836_800_000
    fetch_end_ms = System.system_time(:millisecond)

    {position_map, sizing_map} =
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
          {%{}, %{}}
      end

    %{
      position_map: position_map,
      # %{week_ms => %{sym => :full | :half}}
      sizing_map: sizing_map,
      # tracks quantity held per symbol for SELL orders
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
      sizing = Map.get(state.sizing_map, rebalance_ms, %{})

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
          # Use half-size if asset is in early recovery (below 50w SMA), else full
          quote = if Map.get(sizing, sym) == :half, do: @half_quote_per_position, else: @quote_per_position
          qty = quote / close
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
  # Returns {position_map, sizing_map}
  # position_map: %{rebalance_ms => [sym, ...]}  — top assets to hold
  # sizing_map:   %{rebalance_ms => %{sym => :full | :half}}
  #               :half when entering below 50w SMA (early recovery)
  #               :full when entering above 50w SMA (confirmed trend)

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

    # Need: 50w SMA (largest window) + momentum lookback + 1
    needed = @size_gate_weeks + @momentum_lookback_weeks + 1

    {position_map, sizing_map, _last_targets} =
      Enum.reduce(all_weeks, {%{}, %{}, []}, fn week_ms, {pos_acc, sz_acc, last_targets} ->
        prior_weeks =
          all_weeks
          |> Enum.filter(&(&1 < week_ms))
          |> Enum.take(-needed)

        if length(prior_weeks) < needed do
          {pos_acc, sz_acc, last_targets}
        else
          candidates =
            Enum.flat_map(symbols_str, fn sym ->
              closes = weekly_closes[sym] || %{}
              history = Enum.map(prior_weeks, &Map.get(closes, &1))

              if Enum.any?(history, &is_nil/1) do
                []
              else
                close_last = List.last(history)

                sma_20w = Enum.sum(Enum.take(history, -@exit_gate_weeks)) / @exit_gate_weeks
                sma_13w = Enum.sum(Enum.take(history, -@entry_gate_weeks)) / @entry_gate_weeks
                sma_50w = Enum.sum(Enum.take(history, -@size_gate_weeks)) / @size_gate_weeks

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
                      Enum.sum(
                        Enum.map(weekly_returns, fn r -> (r - mean_r) * (r - mean_r) end)
                      ) / n

                    :math.sqrt(variance)
                  else
                    @vol_floor
                  end

                sharpe_score = momentum / max(stdev, @vol_floor)

                # Asymmetric gate: entry at 13w SMA, exit at 20w SMA
                is_holding = sym in last_targets

                gate_ok =
                  if is_holding,
                    do: close_last > sma_20w,
                    else: close_last > sma_13w

                if gate_ok do
                  # Size signal: below 50w SMA = early recovery, half-size
                  size = if close_last > sma_50w, do: :full, else: :half
                  [{sym, sharpe_score, size}]
                else
                  []
                end
              end
            end)

          top =
            candidates
            |> Enum.sort_by(fn {_, s, _} -> s end, :desc)
            |> Enum.take(@hold_count)

          top_syms = Enum.map(top, fn {sym, _, _} -> sym end)
          top_sizing = Map.new(top, fn {sym, _, size} -> {sym, size} end)

          is_rebalance_week = rem(week_ms, @rebalance_ms) == 0
          new_last_targets = if is_rebalance_week, do: top_syms, else: last_targets

          {
            Map.put(pos_acc, week_ms, top_syms),
            Map.put(sz_acc, week_ms, top_sizing),
            new_last_targets
          }
        end
      end)

    {position_map, sizing_map}
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
