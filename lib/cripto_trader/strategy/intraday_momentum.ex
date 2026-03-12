defmodule CriptoTrader.Strategy.IntradayMomentum do
  @moduledoc """
  Intraday momentum strategy with trailing entry/exit.

  Exploits the "late night rally" pattern observed across BTC, ETH, SOL,
  and ADA in 2024 data:

  **Buy phase** (19:00-20:00 UTC):
  - Tracks the lowest price seen during the window.
  - Sets a trailing trigger at `lowest * (1 + trail_pct)`.
  - Buys when price crosses above the trigger (confirming the dip reversal).

  **Sell phase** (21:00-22:00 UTC):
  - Tracks the highest price seen during the window.
  - Sets a trailing trigger at `highest * (1 - trail_pct)`.
  - Sells when price drops below the trigger (capturing the rally peak).

  **Stop loss**: Sells immediately if price drops `stop_loss_pct` below entry
  at any time while holding.

  **Force sell**: At 22:00 UTC, any remaining position is sold at market
  to avoid overnight exposure.

  Uses `quote_per_trade` for uniform dollar sizing across all symbols.
  """

  @default_quote_per_trade 100.0
  @default_stop_loss_pct 0.02
  @default_trail_pct 0.003

  @buy_start_hour 19
  @buy_end_hour 20
  @sell_start_hour 21
  @sell_end_hour 22

  @type tracking :: %{
          low: float(),
          high: float()
        }

  @type position :: %{
          entry_price: float(),
          quantity: float()
        }

  @type state :: %{
          quote_per_trade: float(),
          stop_loss_pct: float(),
          trail_pct: float(),
          positions: %{optional(String.t()) => position()},
          tracking: %{optional(String.t()) => tracking()}
        }

  @spec new_state([String.t()], keyword() | number()) :: state()
  def new_state(symbols, opts \\ [])

  # Legacy arity: new_state(symbols, quote_per_trade_number)
  def new_state(symbols, quote_per_trade) when is_number(quote_per_trade) do
    new_state(symbols, quote_per_trade: quote_per_trade)
  end

  def new_state(_symbols, opts) when is_list(opts) do
    %{
      quote_per_trade:
        normalize_positive(Keyword.get(opts, :quote_per_trade, @default_quote_per_trade), @default_quote_per_trade),
      stop_loss_pct:
        normalize_pct(Keyword.get(opts, :stop_loss_pct, @default_stop_loss_pct), @default_stop_loss_pct),
      trail_pct:
        normalize_pct(Keyword.get(opts, :trail_pct, @default_trail_pct), @default_trail_pct),
      positions: %{},
      tracking: %{}
    }
  end

  @spec signal(map(), state()) :: {[map()], state()}
  def signal(%{symbol: symbol, open_time: open_time, candle: candle}, state) do
    hour = utc_hour(open_time)
    close = parse_number(candle[:close] || candle["close"])
    has_position = Map.has_key?(state.positions, symbol)
    in_buy_window = hour >= @buy_start_hour and hour < @buy_end_hour
    in_sell_window = hour >= @sell_start_hour and hour < @sell_end_hour
    past_sell_window = hour >= @sell_end_hour

    cond do
      # Stop loss — any time while holding
      has_position and stop_loss_triggered?(state, symbol, close) ->
        sell_and_clear(symbol, state)

      # Buy window — track low, buy on bounce
      not has_position and in_buy_window and close > 0 ->
        handle_buy_window(symbol, close, state)

      # Sell window — track high, sell on pullback
      has_position and in_sell_window ->
        handle_sell_window(symbol, close, state)

      # Force sell at end of sell window
      has_position and past_sell_window ->
        sell_and_clear(symbol, state)

      # Outside windows — clear any stale tracking
      not in_buy_window and not in_sell_window ->
        {[], clear_tracking(symbol, state)}

      true ->
        {[], state}
    end
  end

  def signal(_event, state), do: {[], state}

  # -- Buy window logic --

  defp handle_buy_window(symbol, close, state) do
    tracking = Map.get(state.tracking, symbol)

    case tracking do
      nil ->
        # First candle in window — start tracking
        new_tracking = %{low: close, high: close}
        {[], %{state | tracking: Map.put(state.tracking, symbol, new_tracking)}}

      %{low: low} ->
        if close < low do
          # Price still dropping — update the low
          new_tracking = %{tracking | low: close}
          {[], %{state | tracking: Map.put(state.tracking, symbol, new_tracking)}}
        else
          # Check if price bounced above trigger
          trigger = low * (1.0 + state.trail_pct)

          if close >= trigger do
            # Bounce confirmed — buy
            buy_and_clear(symbol, close, state)
          else
            # Not enough bounce yet
            {[], state}
          end
        end
    end
  end

  # -- Sell window logic --

  defp handle_sell_window(symbol, close, state) do
    tracking = Map.get(state.tracking, symbol)

    case tracking do
      nil ->
        # First candle in sell window — start tracking the high
        new_tracking = %{low: close, high: close}
        {[], %{state | tracking: Map.put(state.tracking, symbol, new_tracking)}}

      %{high: high} ->
        if close > high do
          # Price still rising — update the high
          new_tracking = %{tracking | high: close}
          {[], %{state | tracking: Map.put(state.tracking, symbol, new_tracking)}}
        else
          # Check if price pulled back below trigger
          trigger = high * (1.0 - state.trail_pct)

          if close <= trigger do
            # Pullback confirmed — sell
            sell_and_clear(symbol, state)
          else
            # Still near the peak
            {[], state}
          end
        end
    end
  end

  # -- Order helpers --

  defp buy_and_clear(symbol, entry_price, state) do
    quantity = state.quote_per_trade / entry_price
    order = %{symbol: symbol, side: "BUY", quantity: quantity}
    position = %{entry_price: entry_price, quantity: quantity}

    new_state = %{
      state
      | positions: Map.put(state.positions, symbol, position),
        tracking: Map.delete(state.tracking, symbol)
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
            tracking: Map.delete(state.tracking, symbol)
        }

        {[order], new_state}

      :error ->
        {[], clear_tracking(symbol, state)}
    end
  end

  defp clear_tracking(symbol, state) do
    if Map.has_key?(state.tracking, symbol) do
      %{state | tracking: Map.delete(state.tracking, symbol)}
    else
      state
    end
  end

  # -- Stop loss --

  defp stop_loss_triggered?(state, symbol, current_price) do
    case Map.fetch(state.positions, symbol) do
      {:ok, %{entry_price: entry_price}} when entry_price > 0 ->
        (entry_price - current_price) / entry_price >= state.stop_loss_pct

      _ ->
        false
    end
  end

  # -- Helpers --

  defp utc_hour(open_time) when is_integer(open_time) do
    seconds = div(open_time, 1000)
    rem(div(seconds, 3600), 24)
  end

  defp parse_number(value) when is_float(value), do: value
  defp parse_number(value) when is_integer(value), do: value * 1.0

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp parse_number(_), do: 0.0

  defp normalize_positive(v, _default) when is_number(v) and v > 0, do: v * 1.0
  defp normalize_positive(_, default), do: default * 1.0

  defp normalize_pct(v, _default) when is_number(v) and v > 0 and v < 1, do: v * 1.0
  defp normalize_pct(_, default), do: default * 1.0
end
