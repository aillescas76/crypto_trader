defmodule CriptoTrader.Strategy.Experiment.DailyMaRegime20260313 do
  @moduledoc """
  Daily 200-period SMA regime filter.

  Hypothesis: Deep crypto bear markets create a regime-protection edge because a
  200-day SMA on per-symbol daily closes reliably separates bull and bear macro
  phases. The signal fires approximately 0.4 regime transitions per month per
  pair. When each symbol's daily close is above its own 200-day SMA, the strategy
  holds full long; when it drops below SMA × 0.97 (3% exit buffer), it exits to
  cash. Expected to beat buy-and-hold (+66% equal-weight training average) AND
  achieve max_drawdown < 40% (BTCUSDC measured 23%) on both training (pre-2025)
  and validation (2025+) splits.

  Parameters from Step 5a/5b analysis (training 2022-2024):
  - ma_period: 200 (daily candles, per-pair own SMA)
  - exit_buffer_pct: 0.03 (exit when daily close < SMA200 × 0.97)
  - Per-pair own SMA200 beats BTCUSDC signal by +37pp portfolio average
  - 3% buffer improves over 2% buffer: fewer whipsaws, higher PnL
  """

  alias CriptoTrader.MarketData.ArchiveCandles

  @ma_period 200
  @exit_buffer 0.03
  @default_quote_per_trade 1500.0

  # -- Initialisation --

  def new_state(symbols, opts \\ []) do
    quote_per_trade = Keyword.get(opts, :quote_per_trade, @default_quote_per_trade) * 1.0

    # Pre-load daily candles to build regime map covering full date range.
    # This avoids 200-day warmup in the validation split.
    cache_dir = Path.join(System.user_home!(), ".cripto_trader/archive_cache")
    # Start from 2021-01-01 to ensure 200-day warmup before 2022 training data.
    fetch_start_ms = 1_609_459_200_000
    fetch_end_ms = System.system_time(:millisecond)

    regime_maps =
      case ArchiveCandles.fetch(
             symbols: symbols,
             interval: "1d",
             start_time: fetch_start_ms,
             end_time: fetch_end_ms,
             cache_dir: cache_dir
           ) do
        {:ok, daily_candles_by_symbol} ->
          Map.new(symbols, fn sym ->
            sym_str = to_string(sym)
            candles = Map.get(daily_candles_by_symbol, sym_str, [])
            {sym_str, build_regime_map(candles)}
          end)

        _ ->
          # Fallback: empty maps — strategy will remain :unknown (in cash)
          Map.new(symbols, fn sym -> {to_string(sym), %{}} end)
      end

    symbol_states =
      Map.new(symbols, fn sym ->
        {to_string(sym),
         %{
           regime: :unknown,
           in_position: false,
           entry_qty: 0.0,
           last_day_ms: nil
         }}
      end)

    %{
      quote_per_trade: quote_per_trade,
      regime_maps: regime_maps,
      symbol_states: symbol_states
    }
  end

  # -- Signal --

  def signal(%{symbol: symbol, candle: candle}, state) do
    sym = to_string(symbol)

    case Map.fetch(state.symbol_states, sym) do
      :error ->
        {[], state}

      {:ok, ss} ->
        open_time = candle[:open_time] || candle["open_time"]
        close = parse_float(candle[:close] || candle["close"])

        # Each 15m candle belongs to the day that started at midnight UTC
        day_ms = div(open_time, 86_400_000) * 86_400_000

        # Only act on the first candle of each new day
        if ss.last_day_ms == day_ms do
          {[], state}
        else
          regime = Map.get(state.regime_maps[sym] || %{}, day_ms, :unknown)

          {orders, new_ss} = apply_regime(sym, regime, ss, close, state.quote_per_trade)

          updated_ss = %{new_ss | last_day_ms: day_ms}

          {orders, %{state | symbol_states: Map.put(state.symbol_states, sym, updated_ss)}}
        end
    end
  end

  def signal(_event, state), do: {[], state}

  # -- Regime logic --

  defp apply_regime(_symbol, same, %{regime: same} = ss, _close, _quote) do
    {[], ss}
  end

  defp apply_regime(symbol, :long, ss, close, quote_per_trade) when ss.regime != :long do
    qty = quote_per_trade / close
    order = %{symbol: symbol, side: "BUY", quantity: qty}
    new_ss = %{ss | regime: :long, in_position: true, entry_qty: qty}
    {[order], new_ss}
  end

  defp apply_regime(symbol, :cash, %{regime: :long} = ss, _close, _quote) do
    order = %{symbol: symbol, side: "SELL", quantity: ss.entry_qty}
    new_ss = %{ss | regime: :cash, in_position: false, entry_qty: 0.0}
    {[order], new_ss}
  end

  defp apply_regime(_symbol, new_regime, ss, _close, _quote) do
    {[], %{ss | regime: new_regime}}
  end

  # -- Pre-compute regime map from daily candles --
  # Maps day_start_ms → :long | :cash | :unknown
  # Regime for day D is determined by the close of day D-1 vs SMA200.

  defp build_regime_map(daily_candles) do
    sorted =
      Enum.sort_by(daily_candles, fn c ->
        c[:open_time] || c["open_time"]
      end)

    {regime_map, _buffer, _prev_regime} =
      Enum.reduce(sorted, {%{}, [], :unknown}, fn candle, {acc, buffer, prev_regime} ->
        day_ms = candle[:open_time] || candle["open_time"]
        close = parse_float(candle[:close] || candle["close"])

        new_buffer = (buffer ++ [close]) |> Enum.take(-@ma_period)

        sma200 =
          if length(new_buffer) >= @ma_period do
            Enum.sum(new_buffer) / length(new_buffer)
          else
            nil
          end

        # Regime computed from today's close applies starting TOMORROW
        next_day_ms = day_ms + 86_400_000

        next_regime =
          cond do
            sma200 == nil ->
              :unknown

            close > sma200 ->
              :long

            close < sma200 * (1.0 - @exit_buffer) ->
              :cash

            # Hysteresis: stay in previous regime when between thresholds
            true ->
              prev_regime
          end

        new_acc = Map.put(acc, next_day_ms, next_regime)
        {new_acc, new_buffer, next_regime}
      end)

    regime_map
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
