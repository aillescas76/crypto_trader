defmodule CriptoTrader.Strategy.Alternating do
  @moduledoc """
  Deterministic strategy that alternates BUY/SELL orders per symbol.

  This module is intended as a simple, pure baseline strategy for
  simulation runs and integration testing.
  """

  @type state :: %{
          quantity: float(),
          next_side_by_symbol: %{optional(String.t()) => String.t()}
        }

  @default_quantity 0.1

  @spec new_state([String.t()], number()) :: state()
  def new_state(symbols, quantity \\ @default_quantity) when is_list(symbols) do
    normalized_symbols =
      symbols
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{
      quantity: normalize_quantity(quantity),
      next_side_by_symbol: Map.new(normalized_symbols, fn symbol -> {symbol, "BUY"} end)
    }
  end

  @spec signal(map(), state()) :: {[map()], state()}
  def signal(%{symbol: symbol}, state) when is_binary(symbol) and is_map(state) do
    quantity = Map.get(state, :quantity, @default_quantity)
    next_side_by_symbol = Map.get(state, :next_side_by_symbol, %{})
    side = Map.get(next_side_by_symbol, symbol, "BUY")

    order = %{symbol: symbol, side: side, quantity: quantity}

    updated_state = %{
      state
      | next_side_by_symbol: Map.put(next_side_by_symbol, symbol, toggle_side(side))
    }

    {[order], updated_state}
  end

  def signal(_event, state), do: {[], state}

  defp toggle_side("BUY"), do: "SELL"
  defp toggle_side(_), do: "BUY"

  defp normalize_quantity(quantity) when is_number(quantity) and quantity > 0, do: quantity * 1.0
  defp normalize_quantity(_), do: @default_quantity
end
