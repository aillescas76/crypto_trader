defmodule CriptoTrader.Strategy.BuyAndHold do
  @moduledoc """
  Buy-and-hold baseline strategy.

  Buys with `quote_per_trade` on the first candle for each symbol and never sells.
  Used to benchmark other strategies against passive holding.
  """

  @default_quote_per_trade 100.0

  @type state :: %{
          quote_per_trade: float(),
          bought: %{optional(String.t()) => boolean()}
        }

  @spec new_state([String.t()], keyword()) :: state()
  def new_state(_symbols, opts \\ []) do
    %{
      quote_per_trade: Keyword.get(opts, :quote_per_trade, @default_quote_per_trade),
      bought: %{}
    }
  end

  @spec signal(map(), state()) :: {[map()], state()}
  def signal(%{symbol: symbol, candle: %{close: close}}, state)
      when is_binary(symbol) and is_number(close) do
    if Map.get(state.bought, symbol, false) do
      {[], state}
    else
      quantity = state.quote_per_trade / close
      order = %{symbol: symbol, side: "BUY", quantity: quantity}
      new_state = %{state | bought: Map.put(state.bought, symbol, true)}
      {[order], new_state}
    end
  end

  def signal(_event, state), do: {[], state}
end
