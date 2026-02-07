defmodule CriptoTrader.Binance.Spot do
  @moduledoc false

  alias CriptoTrader.Binance.Client

  @spec ping(Client.t()) :: {:ok, map()} | {:error, term()}
  def ping(client \\ Client.new()) do
    Client.public_get(client, "/api/v3/ping")
  end

  @spec time(Client.t()) :: {:ok, map()} | {:error, term()}
  def time(client \\ Client.new()) do
    Client.public_get(client, "/api/v3/time")
  end

  @spec exchange_info(Client.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def exchange_info(client \\ Client.new(), params \\ %{}) do
    Client.public_get(client, "/api/v3/exchangeInfo", params)
  end

  @spec klines(Client.t(), map() | keyword()) :: {:ok, list()} | {:error, term()}
  def klines(client \\ Client.new(), params) do
    Client.public_get(client, "/api/v3/klines", params)
  end

  @spec account(Client.t()) :: {:ok, map()} | {:error, term()}
  def account(client \\ Client.new()) do
    Client.signed_request(client, :get, "/api/v3/account")
  end

  @spec new_order(Client.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def new_order(client \\ Client.new(), params) do
    Client.signed_request(client, :post, "/api/v3/order", params)
  end

  @spec cancel_order(Client.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def cancel_order(client \\ Client.new(), params) do
    Client.signed_request(client, :delete, "/api/v3/order", params)
  end
end
