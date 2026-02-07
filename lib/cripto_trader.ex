defmodule CriptoTrader do
  @moduledoc """
  Entry points for order placement and configuration helpers.
  """

  alias CriptoTrader.{Config, OrderManager}

  @spec trading_mode() :: :paper | :live
  def trading_mode do
    Config.trading_mode()
  end

  @spec place_order(map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def place_order(params, opts \\ []) do
    OrderManager.place_order(params, opts)
  end
end
