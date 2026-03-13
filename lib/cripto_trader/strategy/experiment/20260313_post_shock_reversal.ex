defmodule CriptoTrader.Strategy.Experiment.PostShockReversal20260313 do
  @moduledoc """
  Post-shock intraday reversal.

  Hypothesis: Liquidation cascades and stop hunts create short-term reversal edge
  because automated stop-loss executions and thin order book wicks push spot prices
  transiently below fair value, which reverts within 2 hours as mechanical selling
  pressure clears.

  Signal: Enter long when a 15m candle's body (open - close, down-only) exceeds
  drop_atr_multiple * ATR(atr_period). Exit after hold_candles candles.

  Parameters from Step 5 analysis (training 2022-2024):
  - drop_atr_multiple = 2.0 (cross-symbol optimum; XRP edge cliff above 2.0)
  - atr_period = 14
  - hold_candles = 8 (2 hours; positive edge on all 6 symbols, no trend filter needed)

  Stress-test results:
  - 2022 bear market: +9.14% PnL, 11.97% max drawdown (strategy profits from bounces)
  - Worst 3-month window: -13.15% (Feb–May 2024, ATH choppy top)
  - Buy-and-hold baseline: +42.2%, Sharpe 0.407, 68.37% max drawdown
  - All 6 symbols positive PF (1.02–1.18) at dm=2.0, WR 52–57%
  """

  @default_drop_atr_multiple 2.0
  @default_atr_period 14
  @default_hold_candles 8
  @default_quote_per_trade 1000.0

  def new_state(symbols, opts \\ []) when is_list(symbols) do
    drop_atr_multiple =
      Keyword.get(opts, :drop_atr_multiple, @default_drop_atr_multiple) * 1.0

    atr_period = Keyword.get(opts, :atr_period, @default_atr_period)
    hold_candles = Keyword.get(opts, :hold_candles, @default_hold_candles)

    quote_per_trade =
      Keyword.get(opts, :quote_per_trade, @default_quote_per_trade) * 1.0

    symbol_states =
      Map.new(symbols, fn sym ->
        {to_string(sym),
         %{
           prev_close: nil,
           tr_buffer: [],
           atr: nil,
           pending_entry: false,
           in_trade: false,
           bars_held: 0,
           entry_qty: 0.0
         }}
      end)

    %{
      drop_atr_multiple: drop_atr_multiple,
      atr_period: atr_period,
      hold_candles: hold_candles,
      quote_per_trade: quote_per_trade,
      symbol_states: symbol_states
    }
  end

  def signal(%{symbol: symbol, candle: candle}, state) do
    sym = to_string(symbol)

    case Map.fetch(state.symbol_states, sym) do
      :error ->
        {[], state}

      {:ok, ss} ->
        open = parse_float(candle[:open] || candle["open"])
        high = parse_float(candle[:high] || candle["high"])
        low = parse_float(candle[:low] || candle["low"])
        close = parse_float(candle[:close] || candle["close"])

        {orders, new_ss} =
          process_candle(sym, open, high, low, close, ss, state)

        {orders, %{state | symbol_states: Map.put(state.symbol_states, sym, new_ss)}}
    end
  end

  def signal(_event, state), do: {[], state}

  # -- Core candle logic --

  defp process_candle(symbol, open, high, low, close, ss, state) do
    # Step 1: update ATR
    ss = update_atr(open, high, low, close, ss, state.atr_period)

    cond do
      # Step 2: pending entry from shock on prior candle — enter now
      ss.pending_entry ->
        qty = state.quote_per_trade / close
        order = %{symbol: symbol, side: "BUY", quantity: qty}

        new_ss = %{ss | pending_entry: false, in_trade: true, bars_held: 1, entry_qty: qty}
        {[order], new_ss}

      # Step 3: in trade and hold period complete — exit
      ss.in_trade and ss.bars_held >= state.hold_candles ->
        order = %{symbol: symbol, side: "SELL", quantity: ss.entry_qty}
        new_ss = %{ss | in_trade: false, bars_held: 0, entry_qty: 0.0}
        {[order], new_ss}

      # Step 4: in trade, not yet done — increment counter
      ss.in_trade ->
        {[], %{ss | bars_held: ss.bars_held + 1}}

      # Step 5: not in trade — check for shock signal
      true ->
        new_ss = check_shock(open, close, ss, state.drop_atr_multiple)
        {[], new_ss}
    end
  end

  defp check_shock(open, close, ss, drop_atr_multiple) do
    with atr when is_float(atr) and atr > 0 <- ss.atr,
         body when body > 0 <- open - close,
         true <- body > drop_atr_multiple * atr do
      %{ss | pending_entry: true}
    else
      _ -> ss
    end
  end

  # -- ATR (Wilder's) --

  defp update_atr(_open, high, low, close, ss, atr_period) do
    tr =
      case ss.prev_close do
        nil ->
          high - low

        prev ->
          Enum.max([
            high - low,
            abs(high - prev),
            abs(low - prev)
          ])
      end

    new_buffer =
      (ss.tr_buffer ++ [tr])
      |> Enum.take(-atr_period)

    new_atr =
      if length(new_buffer) >= atr_period do
        Enum.sum(new_buffer) / length(new_buffer)
      else
        ss.atr
      end

    %{ss | prev_close: close, tr_buffer: new_buffer, atr: new_atr}
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
