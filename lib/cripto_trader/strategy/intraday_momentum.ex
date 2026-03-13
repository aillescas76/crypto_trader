defmodule CriptoTrader.Strategy.IntradayMomentum do
  @moduledoc """
  Adaptive intraday momentum strategy.

  Learns the best buy and sell hours from the previous 10 days of price history
  for each symbol independently. If no clear intraday pattern is detected,
  no trades are placed.

  **Pattern discovery:**
  - Accumulates hourly close prices day by day.
  - When a day completes, records the hour with the lowest close (`low_hour`)
    and the hour with the highest close *after* `low_hour` (`high_hour`).
  - After 10 days, selects modal `buy_hour` and `sell_hour`. Both must appear
    in ≥60% of recent days and `buy_hour < sell_hour` — otherwise no trades.

  **Buy phase** (at `buy_hour`):
  - Tracks the lowest price seen during the hour.
  - Sets a trailing trigger at `lowest * (1 + trail_pct)`.
  - Buys when price crosses above the trigger (confirming the dip reversal).

  **Sell phase** (at `sell_hour`):
  - Tracks the highest price seen during the hour.
  - Sets a trailing trigger at `highest * (1 - trail_pct)`.
  - Sells when price drops below the trigger (capturing the rally peak).

  **Stop loss**: Sells immediately if price drops `stop_loss_pct` below entry.

  **Force sell**: Any hour past `sell_hour`, remaining positions are closed.
  """

  @history_days 10
  @confidence_threshold 0.6

  @default_quote_per_trade 100.0
  @default_stop_loss_pct 0.02
  @default_trail_pct 0.003

  @spec new_state([String.t()], keyword() | number()) :: map()
  def new_state(symbols, opts \\ [])

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
      tracking: %{},
      # symbol -> [{low_hour, high_hour}, ...] (up to @history_days entries, newest first)
      day_history: %{},
      # symbol -> {day_index, %{hour => close}}
      current_day: %{},
      # symbol -> {buy_hour, sell_hour} | {nil, nil}
      best_hours: %{}
    }
  end

  @spec signal(map(), map()) :: {[map()], map()}
  def signal(%{symbol: symbol, open_time: open_time, candle: candle}, state) do
    close = parse_number(candle[:close] || candle["close"])
    hour = utc_hour(open_time)
    day_index = utc_day(open_time)

    state = update_day_history(state, symbol, day_index, hour, close)

    case Map.get(state.best_hours, symbol, {nil, nil}) do
      {nil, nil} -> {[], state}
      {buy_hour, sell_hour} -> apply_trading_logic(symbol, hour, close, buy_hour, sell_hour, state)
    end
  end

  def signal(_event, state), do: {[], state}

  # -- Day history accumulation --

  defp update_day_history(state, symbol, day_index, hour, close) do
    case Map.get(state.current_day, symbol) do
      nil ->
        new_current = {day_index, %{hour => close}}
        %{state | current_day: Map.put(state.current_day, symbol, new_current)}

      {^day_index, hourly_closes} ->
        new_hourly = Map.put(hourly_closes, hour, close)
        %{state | current_day: Map.put(state.current_day, symbol, {day_index, new_hourly})}

      {_old_day, hourly_closes} ->
        state = finalize_day(state, symbol, hourly_closes)
        new_current = {day_index, %{hour => close}}
        %{state | current_day: Map.put(state.current_day, symbol, new_current)}
    end
  end

  defp finalize_day(state, _symbol, hourly_closes) when map_size(hourly_closes) < 3 do
    state
  end

  defp finalize_day(state, symbol, hourly_closes) do
    sorted = Enum.sort_by(hourly_closes, fn {h, _} -> h end)

    {low_hour, _} = Enum.min_by(sorted, fn {_, c} -> c end)

    after_low = Enum.filter(sorted, fn {h, _} -> h > low_hour end)

    case after_low do
      [] ->
        state

      _ ->
        {high_hour, _} = Enum.max_by(after_low, fn {_, c} -> c end)

        history = Map.get(state.day_history, symbol, [])
        new_history = Enum.take([{low_hour, high_hour} | history], @history_days)

        new_day_history = Map.put(state.day_history, symbol, new_history)
        new_best_hours = Map.put(state.best_hours, symbol, compute_best_hours(new_history))

        %{state | day_history: new_day_history, best_hours: new_best_hours}
    end
  end

  defp compute_best_hours(history) when length(history) < @history_days do
    {nil, nil}
  end

  defp compute_best_hours(history) do
    n = length(history)

    low_hours = Enum.map(history, fn {low, _} -> low end)
    high_hours = Enum.map(history, fn {_, high} -> high end)

    {modal_low, low_freq} = modal_value(low_hours, n)
    {modal_high, high_freq} = modal_value(high_hours, n)

    if low_freq >= @confidence_threshold and high_freq >= @confidence_threshold and modal_low < modal_high do
      {modal_low, modal_high}
    else
      {nil, nil}
    end
  end

  defp modal_value(values, n) do
    {modal, count} = values |> Enum.frequencies() |> Enum.max_by(fn {_, c} -> c end)
    {modal, count / n}
  end

  # -- Trading logic --

  defp apply_trading_logic(symbol, hour, close, buy_hour, sell_hour, state) do
    has_position = Map.has_key?(state.positions, symbol)
    in_buy_window = hour == buy_hour
    in_sell_window = hour == sell_hour
    past_sell_window = hour > sell_hour

    cond do
      has_position and stop_loss_triggered?(state, symbol, close) ->
        sell_and_clear(symbol, state)

      not has_position and in_buy_window and close > 0 ->
        handle_buy_window(symbol, close, state)

      has_position and in_sell_window ->
        handle_sell_window(symbol, close, state)

      has_position and past_sell_window ->
        sell_and_clear(symbol, state)

      not in_buy_window and not in_sell_window ->
        {[], clear_tracking(symbol, state)}

      true ->
        {[], state}
    end
  end

  # -- Buy window logic --

  defp handle_buy_window(symbol, close, state) do
    tracking = Map.get(state.tracking, symbol)

    case tracking do
      nil ->
        new_tracking = %{low: close, high: close}
        {[], %{state | tracking: Map.put(state.tracking, symbol, new_tracking)}}

      %{low: low} ->
        if close < low do
          new_tracking = %{tracking | low: close}
          {[], %{state | tracking: Map.put(state.tracking, symbol, new_tracking)}}
        else
          trigger = low * (1.0 + state.trail_pct)

          if close >= trigger do
            buy_and_clear(symbol, close, state)
          else
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
        new_tracking = %{low: close, high: close}
        {[], %{state | tracking: Map.put(state.tracking, symbol, new_tracking)}}

      %{high: high} ->
        if close > high do
          new_tracking = %{tracking | high: close}
          {[], %{state | tracking: Map.put(state.tracking, symbol, new_tracking)}}
        else
          trigger = high * (1.0 - state.trail_pct)

          if close <= trigger do
            sell_and_clear(symbol, state)
          else
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

  # -- Time helpers --

  defp utc_hour(open_time) when is_integer(open_time) do
    seconds = div(open_time, 1000)
    rem(div(seconds, 3600), 24)
  end

  defp utc_day(open_time) when is_integer(open_time) do
    div(open_time, 86_400_000)
  end

  # -- Value parsing --

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
