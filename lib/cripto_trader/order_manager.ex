defmodule CriptoTrader.OrderManager do
  @moduledoc false

  require Logger

  alias CriptoTrader.{Config, Risk}
  alias CriptoTrader.Binance.{Client, Spot}
  alias CriptoTrader.Paper.Orders

  @spec place_order(map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def place_order(params, opts \\ []) do
    risk_config = Keyword.get(opts, :risk_config, Risk.Config.default())
    context = Keyword.get(opts, :context, %{})
    trading_mode = Keyword.get(opts, :trading_mode, Config.trading_mode())
    normalized_mode = normalize_trading_mode(trading_mode)

    with :ok <- Risk.check_order(params, risk_config, context),
         :ok <- validate_trading_mode(normalized_mode) do
      params
      |> submit_order(normalized_mode, opts)
      |> log_order_result(params, normalized_mode, context)
    else
      {:error, {:risk, risk_reason}} = error ->
        log_rejection(params, normalized_mode, :risk, risk_reason, context)
        error

      {:error, reason} = error ->
        log_rejection(params, normalized_mode, :pre_submit, reason, context)
        error
    end
  end

  defp submit_order(params, :paper, _opts), do: Orders.submit(params)
  defp submit_order(params, :live, opts), do: Spot.new_order(client_from_opts(opts), params)

  defp client_from_opts(opts) do
    Keyword.get(opts, :client, Client.new())
  end

  defp validate_trading_mode(:paper), do: :ok
  defp validate_trading_mode(:live), do: :ok
  defp validate_trading_mode(:invalid), do: {:error, :invalid_trading_mode}

  defp log_order_result({:ok, response} = result, params, trading_mode, context) do
    payload =
      order_payload(params, trading_mode, context)
      |> Map.merge(%{
        event: "order_submitted",
        status: response_status(response)
      })

    Logger.info(fn -> "order_event " <> Jason.encode!(payload) end)
    result
  end

  defp log_order_result({:error, reason} = result, params, trading_mode, context) do
    log_rejection(params, trading_mode, :execution, reason, context)
    result
  end

  defp log_rejection(params, trading_mode, phase, reason, context) do
    payload =
      order_payload(params, trading_mode, context)
      |> Map.merge(%{
        event: "order_rejected",
        phase: to_string(phase),
        reason: format_reason(reason)
      })

    Logger.warning(fn -> "order_event " <> Jason.encode!(payload) end)
  end

  defp order_payload(params, trading_mode, context) do
    map = params_to_map(params)
    context_map = params_to_map(context)

    %{
      symbol: field(map, :symbol, "symbol"),
      side: field(map, :side, "side"),
      type: field(map, :type, "type"),
      quantity: field(map, :quantity, "quantity"),
      price: field(map, :price, "price"),
      trading_mode: output_mode(trading_mode),
      drawdown_pct: field(context_map, :drawdown_pct, "drawdown_pct"),
      order_quote: field(context_map, :order_quote, "order_quote")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp params_to_map(params) when is_map(params), do: params
  defp params_to_map(params) when is_list(params), do: Enum.into(params, %{})
  defp params_to_map(_params), do: %{}

  defp output_mode(:paper), do: "paper"
  defp output_mode(:live), do: "live"
  defp output_mode(:invalid), do: "invalid"

  defp response_status(response) when is_map(response) do
    field(response, :status, "status") || "ok"
  end

  defp response_status(_response), do: "ok"

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp field(map, atom_key, string_key) when is_map(map) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end

  defp normalize_trading_mode(mode) when mode in [:paper, :live], do: mode

  defp normalize_trading_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "paper" -> :paper
      "live" -> :live
      _ -> :invalid
    end
  end

  defp normalize_trading_mode(_mode), do: :invalid
end
