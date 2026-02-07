defmodule CriptoTrader.Config do
  @moduledoc false

  @default_trading_mode :paper
  @default_base_url "https://api.binance.com"
  @default_recv_window 5_000

  @spec trading_mode() :: :paper | :live
  def trading_mode do
    case get_env(:trading_mode, Atom.to_string(@default_trading_mode))
         |> to_string()
         |> String.downcase() do
      "live" -> :live
      _ -> :paper
    end
  end

  @spec binance_base_url() :: String.t()
  def binance_base_url do
    get_env(:binance, [])
    |> Keyword.get(:base_url, System.get_env("BINANCE_BASE_URL") || @default_base_url)
  end

  @spec binance_recv_window() :: non_neg_integer()
  def binance_recv_window do
    value =
      get_env(:binance, [])
      |> Keyword.get(:recv_window, System.get_env("BINANCE_RECV_WINDOW"))

    parse_int(value, @default_recv_window)
  end

  @spec binance_api_key() :: String.t() | nil
  def binance_api_key, do: System.get_env("BINANCE_API_KEY")

  @spec binance_api_secret() :: String.t() | nil
  def binance_api_secret, do: System.get_env("BINANCE_API_SECRET")

  @spec risk_config() :: keyword()
  def risk_config do
    get_env(:risk, [])
  end

  defp get_env(key, default) do
    Application.get_env(:cripto_trader, key, default)
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default
end
