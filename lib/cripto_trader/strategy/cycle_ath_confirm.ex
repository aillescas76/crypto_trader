defmodule CriptoTrader.Strategy.CycleAthConfirm do
  @moduledoc """
  Like CycleAth but requires `confirm_candles` consecutive closes below
  prev_ath before buying. Reduces whipsaw entries at the exact level.
  """

  @default_multiplier 2.0
  @default_trail_pct 0.20
  @default_quote_per_trade 1000.0
  @default_confirm_candles 3

  @type phase :: :watching | :in_position | :trailing

  @type position :: %{entry_price: float(), quantity: float()}

  @type state :: %{
          multiplier: float(),
          trail_pct: float(),
          quote_per_trade: float(),
          confirm_candles: pos_integer(),
          ath: %{optional(String.t()) => float()},
          prev_ath: %{optional(String.t()) => float()},
          positions: %{optional(String.t()) => position()},
          trail_high: %{optional(String.t()) => float()},
          phase: %{optional(String.t()) => phase()},
          confirm_count: %{optional(String.t()) => non_neg_integer()}
        }

  @spec new_state([String.t()], keyword()) :: state()
  def new_state(_symbols, opts \\ []) do
    %{
      multiplier: Keyword.get(opts, :multiplier, @default_multiplier),
      trail_pct: Keyword.get(opts, :trail_pct, @default_trail_pct),
      quote_per_trade: Keyword.get(opts, :quote_per_trade, @default_quote_per_trade),
      confirm_candles: Keyword.get(opts, :confirm_candles, @default_confirm_candles),
      ath: %{},
      prev_ath: %{},
      positions: %{},
      trail_high: %{},
      phase: %{},
      confirm_count: %{}
    }
  end

  @spec signal(map(), state()) :: {[map()], state()}
  def signal(%{symbol: symbol, candle: candle}, state) do
    close = parse_number(candle[:close] || candle["close"])

    if close <= 0 do
      {[], state}
    else
      state = update_ath(symbol, close, state)
      evaluate(symbol, close, state)
    end
  end

  def signal(_event, state), do: {[], state}

  defp update_ath(symbol, close, state) do
    current_ath = Map.get(state.ath, symbol)

    cond do
      current_ath == nil ->
        %{state | ath: Map.put(state.ath, symbol, close)}

      close > current_ath ->
        state
        |> Map.update!(:ath, &Map.put(&1, symbol, close))
        |> Map.update!(:prev_ath, &Map.put(&1, symbol, current_ath))
        |> Map.update!(:confirm_count, &Map.put(&1, symbol, 0))

      true ->
        state
    end
  end

  defp evaluate(symbol, close, state) do
    phase = Map.get(state.phase, symbol, :watching)
    prev_ath = Map.get(state.prev_ath, symbol)

    case phase do
      :watching ->
        cond do
          prev_ath == nil ->
            {[], state}

          close < prev_ath ->
            count = Map.get(state.confirm_count, symbol, 0) + 1
            state = Map.update!(state, :confirm_count, &Map.put(&1, symbol, count))

            if count >= state.confirm_candles do
              buy(symbol, close, state)
            else
              {[], state}
            end

          true ->
            state = Map.update!(state, :confirm_count, &Map.put(&1, symbol, 0))
            {[], state}
        end

      :in_position ->
        position = state.positions[symbol]

        if close >= position.entry_price * state.multiplier do
          state =
            state
            |> Map.update!(:trail_high, &Map.put(&1, symbol, close))
            |> Map.update!(:phase, &Map.put(&1, symbol, :trailing))

          {[], state}
        else
          {[], state}
        end

      :trailing ->
        trail_high = Map.get(state.trail_high, symbol, close)
        new_trail_high = max(trail_high, close)
        state = Map.update!(state, :trail_high, &Map.put(&1, symbol, new_trail_high))

        if close < new_trail_high * (1.0 - state.trail_pct) do
          sell_and_clear(symbol, state)
        else
          {[], state}
        end
    end
  end

  defp buy(symbol, close, state) do
    quantity = state.quote_per_trade / close
    order = %{symbol: symbol, side: "BUY", quantity: quantity}
    position = %{entry_price: close, quantity: quantity}

    new_state = %{
      state
      | positions: Map.put(state.positions, symbol, position),
        phase: Map.put(state.phase, symbol, :in_position),
        confirm_count: Map.put(state.confirm_count, symbol, 0)
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
            trail_high: Map.delete(state.trail_high, symbol),
            phase: Map.put(state.phase, symbol, :watching),
            confirm_count: Map.put(state.confirm_count, symbol, 0)
        }

        {[order], new_state}

      :error ->
        {[], state}
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
end
