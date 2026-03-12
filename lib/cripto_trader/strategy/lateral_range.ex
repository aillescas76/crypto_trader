defmodule CriptoTrader.Strategy.LateralRange do
  @moduledoc """
  Lateral (range-bound) strategy with adaptive bounds and stop-loss.

  The strategy keeps a rolling close-price window per symbol and computes:
  - `lower`: rolling minimum
  - `upper`: rolling maximum

  It considers the market lateral when the range width is small relative to
  the mid price:

      (upper - lower) / mid <= max_range_pct

  Trading rules:
  - Enter long near the lower bound.
  - Exit near the upper bound.
  - Always enforce stop-loss while holding.
  - Exit on downside breakout to avoid holding in a regime shift.

  Uses `quote_per_trade` for stable quote-currency sizing.
  """

  @default_lookback 30
  @default_max_range_pct 0.02
  @default_quote_per_trade 100.0
  @default_stop_loss_pct 0.015
  @default_entry_buffer_pct 0.0025
  @default_exit_buffer_pct 0.0025
  @default_breakout_pct 0.005

  @type position :: %{entry_price: float(), quantity: float()}

  @type state :: %{
          lookback: pos_integer(),
          max_range_pct: float(),
          quote_per_trade: float(),
          stop_loss_pct: float(),
          entry_buffer_pct: float(),
          exit_buffer_pct: float(),
          breakout_pct: float(),
          positions: %{optional(String.t()) => position()},
          closes: %{optional(String.t()) => [float()]}
        }

  @spec new_state([String.t()], keyword()) :: state()
  def new_state(_symbols, opts \\ []) when is_list(opts) do
    %{
      lookback:
        normalize_pos_int(Keyword.get(opts, :lookback, @default_lookback), @default_lookback),
      max_range_pct:
        normalize_pct(
          Keyword.get(opts, :max_range_pct, @default_max_range_pct),
          @default_max_range_pct
        ),
      quote_per_trade:
        normalize_positive(
          Keyword.get(opts, :quote_per_trade, @default_quote_per_trade),
          @default_quote_per_trade
        ),
      stop_loss_pct:
        normalize_pct(
          Keyword.get(opts, :stop_loss_pct, @default_stop_loss_pct),
          @default_stop_loss_pct
        ),
      entry_buffer_pct:
        normalize_pct(
          Keyword.get(opts, :entry_buffer_pct, @default_entry_buffer_pct),
          @default_entry_buffer_pct
        ),
      exit_buffer_pct:
        normalize_pct(
          Keyword.get(opts, :exit_buffer_pct, @default_exit_buffer_pct),
          @default_exit_buffer_pct
        ),
      breakout_pct:
        normalize_pct(
          Keyword.get(opts, :breakout_pct, @default_breakout_pct),
          @default_breakout_pct
        ),
      positions: %{},
      closes: %{}
    }
  end

  @spec signal(map(), state()) :: {[map()], state()}
  def signal(%{symbol: symbol, candle: candle}, state)
      when is_binary(symbol) and is_map(candle) do
    close = parse_number(candle[:close] || candle["close"])

    if close <= 0 do
      {[], state}
    else
      range = compute_range(state, symbol)
      has_position = Map.has_key?(state.positions, symbol)

      {orders, next_state} =
        cond do
          has_position and stop_loss_triggered?(state, symbol, close) ->
            sell_and_clear(symbol, state)

          has_position and downside_breakout?(state, close, range) ->
            sell_and_clear(symbol, state)

          has_position and take_profit_triggered?(state, close, range) ->
            sell_and_clear(symbol, state)

          not has_position and entry_triggered?(state, close, range) ->
            buy(symbol, close, state)

          true ->
            {[], state}
        end

      {orders, update_closes(symbol, close, next_state)}
    end
  end

  def signal(_event, state), do: {[], state}

  defp entry_triggered?(state, close, %{lateral?: true, lower: lower}) do
    close <= lower * (1.0 + state.entry_buffer_pct)
  end

  defp entry_triggered?(_state, _close, _), do: false

  defp take_profit_triggered?(state, close, %{upper: upper}) when is_number(upper) do
    close >= upper * (1.0 - state.exit_buffer_pct)
  end

  defp take_profit_triggered?(_state, _close, _), do: false

  defp downside_breakout?(state, close, %{lower: lower}) when is_number(lower) do
    close < lower * (1.0 - state.breakout_pct)
  end

  defp downside_breakout?(_state, _close, _), do: false

  defp stop_loss_triggered?(state, symbol, current_price) do
    case Map.fetch(state.positions, symbol) do
      {:ok, %{entry_price: entry_price}} when entry_price > 0 ->
        (entry_price - current_price) / entry_price >= state.stop_loss_pct

      _ ->
        false
    end
  end

  defp buy(symbol, close, state) do
    quantity = state.quote_per_trade / close
    order = %{symbol: symbol, side: "BUY", quantity: quantity}

    new_state = %{
      state
      | positions: Map.put(state.positions, symbol, %{entry_price: close, quantity: quantity})
    }

    {[order], new_state}
  end

  defp sell_and_clear(symbol, state) do
    case Map.fetch(state.positions, symbol) do
      {:ok, %{quantity: quantity}} ->
        order = %{symbol: symbol, side: "SELL", quantity: quantity}
        {[order], %{state | positions: Map.delete(state.positions, symbol)}}

      :error ->
        {[], state}
    end
  end

  defp update_closes(symbol, close, state) do
    closes = Map.get(state.closes, symbol, [])
    updated = Enum.take([close | closes], state.lookback)
    %{state | closes: Map.put(state.closes, symbol, updated)}
  end

  defp compute_range(state, symbol) do
    closes = Map.get(state.closes, symbol, [])

    if length(closes) < state.lookback do
      nil
    else
      lower = Enum.min(closes)
      upper = Enum.max(closes)
      mid = (upper + lower) / 2.0

      width_pct =
        if mid <= 0.0 do
          0.0
        else
          (upper - lower) / mid
        end

      %{
        lower: lower,
        upper: upper,
        width_pct: width_pct,
        lateral?: width_pct <= state.max_range_pct
      }
    end
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

  defp normalize_pos_int(v, _default) when is_integer(v) and v > 0, do: v
  defp normalize_pos_int(_, default), do: default

  defp normalize_positive(v, _default) when is_number(v) and v > 0, do: v * 1.0
  defp normalize_positive(_, default), do: default * 1.0

  defp normalize_pct(v, _default) when is_number(v) and v > 0 and v < 1, do: v * 1.0
  defp normalize_pct(_, default), do: default * 1.0
end
