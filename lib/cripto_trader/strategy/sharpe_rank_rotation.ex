defmodule CriptoTrader.Strategy.SharpeRankRotation do
  @moduledoc """
  Cross-sectional momentum rotation with Sharpe-normalized ranking and per-asset
  20-week SMA trend gate. Rebalances every 3 weeks into the top-2 ranked assets.

  Validated results (6 USDC pairs, $10k, 2020-2024 train / 2025 validation):
    Train  +151.3%  |  Sharpe 0.35  |  MaxDD 26.1%
    Val    +33.81%  |  Sharpe 0.28  |  MaxDD 37.1%
    BnH    +42.2%   /  −16.93%

  Mechanism:
  - Per-asset 20w SMA gate: asset is only eligible to hold when close > 20w SMA.
    All assets below SMA → full cash (bear-market protection).
  - Sharpe-normalized ranking: rank by 4w_return / max(stdev(4w_weekly_returns), 0.02).
    Prefers persistent, low-noise trends over high-vol spikes.
  - 3-week rebalance cadence: quality×time synergy — shorter intervals generate
    costly churn in choppy markets; 4w+ overshoots into missed reversals.
  - Hold top 2 of N assets (concentrates in bull leaders, avoids correlated
    diversification benefit in a high-correlation universe).

  Key params (opts keyword list):
    :quote_per_position  — USDC per position (default 5_000.0)
    :hold_count          — number of assets to hold simultaneously (default 2)
    :ma_period_weeks     — SMA gate period in weeks (default 20)
    :momentum_lookback   — ranking lookback in weeks (default 4)
    :rebalance_weeks     — rebalance cadence in weeks (default 3)
    :vol_floor           — minimum stdev for Sharpe normalization (default 0.02)
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @week_ms 7 * 24 * 60 * 60 * 1000

  # -- Initialisation --

  def new_state(symbols, opts \\ []) do
    symbols_str = Enum.map(symbols, &to_string/1)

    cfg = build_config(opts)

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
          build_position_map(symbols_str, daily_candles_by_symbol, cfg)

        _ ->
          %{}
      end

    %{
      cfg: cfg,
      position_map: position_map,
      current_holdings: %{},
      symbol_last_rebalance: %{}
    }
  end

  # -- Signal --

  def signal(%{symbol: symbol, candle: candle}, state) do
    sym = to_string(symbol)
    open_time = candle[:open_time] || candle["open_time"]
    rebalance_ms = div(open_time, state.cfg.rebalance_ms) * state.cfg.rebalance_ms

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
          qty = state.cfg.quote_per_position / close
          order = %{symbol: sym, side: "BUY", quantity: qty}
          new_state2 = put_in(new_state, [:current_holdings, sym], qty)
          {[order], new_state2}

        true ->
          {[], new_state}
      end
    end
  end

  def signal(_event, state), do: {[], state}

  # -- Config --

  defp build_config(opts) do
    ma_period_weeks    = Keyword.get(opts, :ma_period_weeks, 20)
    momentum_lookback  = Keyword.get(opts, :momentum_lookback, 4)
    rebalance_weeks    = Keyword.get(opts, :rebalance_weeks, 3)

    %{
      quote_per_position: Keyword.get(opts, :quote_per_position, 5_000.0),
      hold_count:         Keyword.get(opts, :hold_count, 2),
      ma_period_weeks:    ma_period_weeks,
      momentum_lookback:  momentum_lookback,
      vol_floor:          Keyword.get(opts, :vol_floor, 0.02),
      rebalance_ms:       rebalance_weeks * @week_ms,
      # weeks needed before the first valid ranking is available
      needed_weeks:       ma_period_weeks + momentum_lookback + 1
    }
  end

  # -- Position map --
  # Pre-computes weekly position targets using Sharpe-normalized ranking.
  # Signal resolves at rebalance_ms-aligned boundaries, which are a subset of
  # weekly keys, so every 3-week boundary has a valid target.

  defp build_position_map(symbols_str, daily_candles_by_symbol, cfg) do
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

    Enum.reduce(all_weeks, %{}, fn week_ms, acc ->
      prior_weeks =
        all_weeks
        |> Enum.filter(&(&1 < week_ms))
        |> Enum.take(-cfg.needed_weeks)

      if length(prior_weeks) < cfg.needed_weeks do
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
              sma = Enum.sum(Enum.take(history, -cfg.ma_period_weeks)) / cfg.ma_period_weeks

              if close_last <= sma do
                []
              else
                mom_base = Enum.at(history, length(history) - cfg.momentum_lookback - 1)

                momentum =
                  if mom_base && mom_base > 0,
                    do: (close_last - mom_base) / mom_base,
                    else: -999.0

                last_n_closes = Enum.take(history, -(cfg.momentum_lookback + 1))

                weekly_returns =
                  last_n_closes
                  |> Enum.chunk_every(2, 1, :discard)
                  |> Enum.map(fn [a, b] -> if a > 0, do: (b - a) / a, else: 0.0 end)

                stdev =
                  case length(weekly_returns) do
                    n when n >= 2 ->
                      mean_r = Enum.sum(weekly_returns) / n
                      variance = Enum.sum(Enum.map(weekly_returns, &((&1 - mean_r) ** 2))) / n
                      :math.sqrt(variance)

                    _ ->
                      cfg.vol_floor
                  end

                sharpe_score = momentum / max(stdev, cfg.vol_floor)
                [{sym, sharpe_score}]
              end
            end
          end)

        top =
          candidates
          |> Enum.sort_by(fn {_, s} -> s end, :desc)
          |> Enum.take(cfg.hold_count)
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
