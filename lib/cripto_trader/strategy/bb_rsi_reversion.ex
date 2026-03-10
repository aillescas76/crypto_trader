defmodule CriptoTrader.Strategy.BbRsiReversion do
  @moduledoc """
  Bollinger Bands + RSI Confluence Mean Reversion strategy.

  **Long entry:** Price closes below lower BB AND RSI < oversold threshold,
  then the next candle closes back inside the BB AND RSI crosses back above
  the threshold (confirmation).

  **Take profit:** Price reaches the middle BB (SMA).

  **Stop loss:** Price drops below SMA - stop_loss_mult * stddev (e.g., 3-sigma).

  Uses `quote_per_trade` for uniform dollar sizing.
  """

  @default_bb_period 20
  @default_bb_mult 2.0
  @default_rsi_period 14
  @default_rsi_oversold 30.0
  @default_rsi_overbought 70.0
  @default_quote_per_trade 100.0
  @default_stop_loss_mult 3.0

  @type position :: %{entry_price: float(), quantity: float()}

  @type rsi_state :: %{avg_gain: float(), avg_loss: float(), prev_close: float()}

  @type state :: %{
          bb_period: pos_integer(),
          bb_mult: float(),
          rsi_period: pos_integer(),
          rsi_oversold: float(),
          rsi_overbought: float(),
          quote_per_trade: float(),
          stop_loss_mult: float(),
          positions: %{optional(String.t()) => position()},
          prices: %{optional(String.t()) => [float()]},
          rsi_state: %{optional(String.t()) => rsi_state()},
          signal_pending: %{optional(String.t()) => boolean()}
        }

  @spec new_state([String.t()], keyword()) :: state()
  def new_state(_symbols, opts \\ []) do
    %{
      bb_period: Keyword.get(opts, :bb_period, @default_bb_period),
      bb_mult: Keyword.get(opts, :bb_mult, @default_bb_mult),
      rsi_period: Keyword.get(opts, :rsi_period, @default_rsi_period),
      rsi_oversold: Keyword.get(opts, :rsi_oversold, @default_rsi_oversold),
      rsi_overbought: Keyword.get(opts, :rsi_overbought, @default_rsi_overbought),
      quote_per_trade: Keyword.get(opts, :quote_per_trade, @default_quote_per_trade),
      stop_loss_mult: Keyword.get(opts, :stop_loss_mult, @default_stop_loss_mult),
      positions: %{},
      prices: %{},
      rsi_state: %{},
      signal_pending: %{}
    }
  end

  @spec signal(map(), state()) :: {[map()], state()}
  def signal(%{symbol: symbol, candle: candle}, state) do
    close = parse_number(candle[:close] || candle["close"])

    if close <= 0 do
      {[], state}
    else
      state = update_prices(symbol, close, state)
      state = update_rsi(symbol, close, state)
      evaluate(symbol, close, state)
    end
  end

  def signal(_event, state), do: {[], state}

  # -- Price buffer --

  defp update_prices(symbol, close, state) do
    prices = Map.get(state.prices, symbol, [])
    # Keep enough prices for BB calculation
    max_len = state.bb_period
    updated = Enum.take([close | prices], max_len)
    %{state | prices: Map.put(state.prices, symbol, updated)}
  end

  # -- RSI calculation (Wilder's smoothed) --

  defp update_rsi(symbol, close, state) do
    case Map.get(state.rsi_state, symbol) do
      nil ->
        # First close for this symbol — just store prev_close
        rsi = %{avg_gain: 0.0, avg_loss: 0.0, prev_close: close, count: 1}
        %{state | rsi_state: Map.put(state.rsi_state, symbol, rsi)}

      %{count: count, prev_close: prev_close} = rsi when count < state.rsi_period ->
        # Accumulation phase
        change = close - prev_close
        gain = if change > 0, do: change, else: 0.0
        loss = if change < 0, do: -change, else: 0.0

        updated =
          if count + 1 == state.rsi_period do
            # Compute initial averages
            total_gain = rsi.avg_gain + gain
            total_loss = rsi.avg_loss + loss
            %{rsi | avg_gain: total_gain / state.rsi_period, avg_loss: total_loss / state.rsi_period, prev_close: close, count: count + 1}
          else
            %{rsi | avg_gain: rsi.avg_gain + gain, avg_loss: rsi.avg_loss + loss, prev_close: close, count: count + 1}
          end

        %{state | rsi_state: Map.put(state.rsi_state, symbol, updated)}

      %{avg_gain: avg_gain, avg_loss: avg_loss, prev_close: prev_close} = rsi ->
        # Wilder's smoothing
        change = close - prev_close
        gain = if change > 0, do: change, else: 0.0
        loss = if change < 0, do: -change, else: 0.0
        period = state.rsi_period

        new_avg_gain = (avg_gain * (period - 1) + gain) / period
        new_avg_loss = (avg_loss * (period - 1) + loss) / period

        updated = %{rsi | avg_gain: new_avg_gain, avg_loss: new_avg_loss, prev_close: close}
        %{state | rsi_state: Map.put(state.rsi_state, symbol, updated)}
    end
  end

  defp compute_rsi(state, symbol) do
    case Map.get(state.rsi_state, symbol) do
      %{count: count} when count < state.rsi_period -> nil
      %{avg_gain: avg_gain, avg_loss: avg_loss} ->
        if avg_loss == 0.0 do
          100.0
        else
          rs = avg_gain / avg_loss
          100.0 - 100.0 / (1.0 + rs)
        end
      _ -> nil
    end
  end

  # -- Bollinger Bands --

  defp compute_bb(state, symbol) do
    prices = Map.get(state.prices, symbol, [])

    if length(prices) < state.bb_period do
      nil
    else
      period_prices = Enum.take(prices, state.bb_period)
      sma = Enum.sum(period_prices) / state.bb_period
      variance = Enum.reduce(period_prices, 0.0, fn p, acc -> acc + (p - sma) * (p - sma) end) / state.bb_period
      stddev = :math.sqrt(variance)
      upper = sma + state.bb_mult * stddev
      lower = sma - state.bb_mult * stddev
      %{sma: sma, upper: upper, lower: lower, stddev: stddev}
    end
  end

  # -- Trade evaluation --

  defp evaluate(symbol, close, state) do
    has_position = Map.has_key?(state.positions, symbol)
    bb = compute_bb(state, symbol)
    rsi = compute_rsi(state, symbol)

    cond do
      # Not enough data for indicators
      bb == nil or rsi == nil ->
        {[], state}

      # Stop loss while holding
      has_position and stop_loss_triggered?(state, symbol, close, bb) ->
        sell_and_clear(symbol, state)

      # Take profit: price reaches middle BB (SMA)
      has_position and close >= bb.sma ->
        sell_and_clear(symbol, state)

      # Entry: confirmation candle (price was below lower BB + RSI oversold last candle,
      # now price is back inside BB or RSI is crossing back above oversold)
      not has_position and Map.get(state.signal_pending, symbol, false) and
          close >= bb.lower and rsi >= state.rsi_oversold ->
        buy(symbol, close, state)

      # Signal setup: price below lower BB AND RSI oversold — arm the pending signal
      not has_position and close < bb.lower and rsi < state.rsi_oversold ->
        {[], %{state | signal_pending: Map.put(state.signal_pending, symbol, true)}}

      # Clear pending signal if conditions no longer hold
      not has_position and Map.get(state.signal_pending, symbol, false) ->
        {[], %{state | signal_pending: Map.put(state.signal_pending, symbol, false)}}

      true ->
        {[], state}
    end
  end

  defp stop_loss_triggered?(state, _symbol, close, bb) do
    stop_level = bb.sma - state.stop_loss_mult * bb.stddev
    close < stop_level
  end

  defp buy(symbol, close, state) do
    quantity = state.quote_per_trade / close
    order = %{symbol: symbol, side: "BUY", quantity: quantity}
    position = %{entry_price: close, quantity: quantity}

    new_state = %{
      state
      | positions: Map.put(state.positions, symbol, position),
        signal_pending: Map.delete(state.signal_pending, symbol)
    }

    {[order], new_state}
  end

  defp sell_and_clear(symbol, state) do
    case Map.fetch(state.positions, symbol) do
      {:ok, position} ->
        order = %{symbol: symbol, side: "SELL", quantity: position.quantity}

        new_state = %{
          state
          | positions: Map.delete(state.positions, symbol),
            signal_pending: Map.delete(state.signal_pending, symbol)
        }

        {[order], new_state}

      :error ->
        {[], state}
    end
  end

  # -- Helpers --

  defp parse_number(value) when is_float(value), do: value
  defp parse_number(value) when is_integer(value), do: value * 1.0

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp parse_number(_), do: 0.0
end
