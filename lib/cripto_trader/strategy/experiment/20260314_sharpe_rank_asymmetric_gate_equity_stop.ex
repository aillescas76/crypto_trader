defmodule CriptoTrader.Strategy.Experiment.SharpeRankAsymmetricGateEquityStop20260314 do
  @moduledoc """
  Asymmetric SMA gate + Sharpe-normalized rotation + portfolio equity circuit breaker.

  Hypothesis: SharpeRankAsymmetricGate (Val +34.99%, MaxDD 94.31%) passes on Sharpe but
  has catastrophic training MaxDD due to entering early-recovery positions that subsequently
  decline further before the 20w exit gate fires. Prior MaxDD fixes were self-defeating:
  - HalfSizeRecovery: half-sizing early entries reduced MaxDD (39.38%) but cost -15pp val
  - QualityThreshold: Sharpe>=0.5 gate blocked the mechanism's core purpose, -19pp val
  Both failed because early recovery captures ARE the primary source of validation edge.

  This variant adds a portfolio-level equity circuit breaker: halt ALL new BUY entries
  when estimated portfolio equity (cash + mark-to-market holdings) drops below 65% of
  initial balance ($6,500). Existing positions are unaffected — no forced exits, no sizing
  changes. Buying resumes automatically when equity recovers above the threshold. This
  differs fundamentally from HalfSizeRecovery: the equity stop prevents new capital
  deployment only during severe portfolio drawdowns, without touching the size of entries
  that do occur. Full-size recovery captures remain intact when equity is healthy.

  Changes vs SharpeRankAsymmetricGate20260314 (Train 196.38%, Val +34.99%, MaxDD 94.31%):
  - Track cash balance (decremented on BUY, incremented on SELL)
  - Track last-seen price for each symbol (updated on every candle event)
  - Block new BUY entries when cash + sum(holdings × last_prices) < 6,500 USDC
  - All other parameters unchanged:
    entry_gate_weeks: 13, exit_gate_weeks: 20, rebalance_interval: 3w,
    momentum_lookback_weeks: 4, vol_floor: 0.02, hold_count: 2, quote_per_position: 5,000
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
  @initial_balance 10_000.0
  # Halt new BUY entries when equity drops below this fraction of initial balance
  @equity_stop_threshold 0.65

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
      symbol_last_rebalance: %{},
      # Tracks available cash (initial balance minus deployed capital, plus sale proceeds)
      cash: @initial_balance,
      # Last known price per symbol — updated on every candle event for mark-to-market
      last_prices: %{}
    }
  end

  # -- Signal --

  def signal(%{symbol: symbol, candle: candle}, state) do
    sym = to_string(symbol)
    open_time = candle[:open_time] || candle["open_time"]
    close = parse_float(candle[:close] || candle["close"])

    # Always update last-known price — used for equity estimation at BUY time
    state = put_in(state, [:last_prices, sym], close)

    rebalance_ms = div(open_time, @rebalance_ms) * @rebalance_ms

    if Map.get(state.symbol_last_rebalance, sym) == rebalance_ms do
      {[], state}
    else
      state = put_in(state, [:symbol_last_rebalance, sym], rebalance_ms)
      target = Map.get(state.position_map, rebalance_ms)

      cond do
        is_nil(target) ->
          {[], state}

        Map.has_key?(state.current_holdings, sym) and sym not in target ->
          qty = state.current_holdings[sym]
          sell_proceeds = qty * close
          state = update_in(state, [:current_holdings], &Map.delete(&1, sym))
          state = update_in(state, [:cash], &(&1 + sell_proceeds))
          order = %{symbol: sym, side: "SELL", quantity: qty}
          {[order], state}

        not Map.has_key?(state.current_holdings, sym) and sym in target ->
          # Equity circuit breaker: skip BUY when portfolio equity is severely depressed
          equity = estimate_equity(state)

          if equity >= @equity_stop_threshold * @initial_balance do
            qty = @quote_per_position / close
            state = put_in(state, [:current_holdings, sym], qty)
            state = update_in(state, [:cash], &(&1 - @quote_per_position))
            order = %{symbol: sym, side: "BUY", quantity: qty}
            {[order], state}
          else
            {[], state}
          end

        true ->
          {[], state}
      end
    end
  end

  def signal(_event, state), do: {[], state}

  # -- Equity estimation --
  # cash + sum(holdings × last-known prices). Uses the most recent price seen for each
  # symbol across all candle events, so this is near-real-time mark-to-market.

  defp estimate_equity(state) do
    held_value =
      state.current_holdings
      |> Enum.map(fn {sym, qty} ->
        price = Map.get(state.last_prices, sym, 0.0)
        qty * price
      end)
      |> Enum.sum()

    state.cash + held_value
  end

  # -- Position map construction --
  # Identical to SharpeRankAsymmetricGate20260314 — asymmetric gate + Sharpe ranking.
  # The equity stop is applied at runtime in signal/2; the pre-computed position_map
  # determines WHICH assets to hold at each rebalance boundary, not WHETHER to enter.

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
