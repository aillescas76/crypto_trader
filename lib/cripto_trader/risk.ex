defmodule CriptoTrader.Risk do
  @moduledoc false

  alias CriptoTrader.Risk.Config

  @type order_params :: map() | keyword()
  @type context :: map()

  @spec check_order(order_params(), Config.t(), context()) :: :ok | {:error, term()}
  def check_order(order_params, config \\ Config.default(), context \\ %{}) do
    with :ok <- check_circuit_breaker(config, context),
         :ok <- check_drawdown(config, context),
         :ok <- check_max_order_quote(config, order_params, context) do
      :ok
    end
  end

  defp check_circuit_breaker(%Config{circuit_breaker: true}, _context) do
    {:error, {:risk, :circuit_breaker}}
  end

  defp check_circuit_breaker(_config, %{circuit_breaker: true}) do
    {:error, {:risk, :circuit_breaker}}
  end

  defp check_circuit_breaker(_config, _context), do: :ok

  defp check_drawdown(%Config{max_drawdown_pct: nil}, _context), do: :ok

  defp check_drawdown(%Config{max_drawdown_pct: max}, %{drawdown_pct: drawdown})
       when is_number(drawdown) and drawdown > max do
    {:error, {:risk, :max_drawdown}}
  end

  defp check_drawdown(_config, _context), do: :ok

  defp check_max_order_quote(%Config{max_order_quote: nil}, _order, _context), do: :ok

  defp check_max_order_quote(%Config{max_order_quote: max}, order_params, context) do
    case order_quote(order_params, context) do
      nil -> :ok
      quote when is_number(quote) and quote > max -> {:error, {:risk, :max_order_quote}}
      _ -> :ok
    end
  end

  defp order_quote(order_params, context) when is_map(context) do
    context_quote = Map.get(context, :order_quote) || Map.get(context, "order_quote")

    cond do
      is_number(context_quote) -> context_quote
      true -> order_quote_from_params(order_params)
    end
  end

  defp order_quote_from_params(params) when is_map(params) do
    quote = Map.get(params, :quote_order_qty) || Map.get(params, "quoteOrderQty")

    cond do
      is_number(quote) ->
        quote

      is_binary(quote) ->
        parse_float(quote)

      true ->
        quantity = Map.get(params, :quantity) || Map.get(params, "quantity")
        price = Map.get(params, :price) || Map.get(params, "price")
        compute_notional(quantity, price)
    end
  end

  defp order_quote_from_params(params) when is_list(params) do
    order_quote_from_params(Enum.into(params, %{}))
  end

  defp compute_notional(quantity, price) do
    with qty when is_number(qty) <- parse_number(quantity),
         pr when is_number(pr) <- parse_number(price) do
      qty * pr
    else
      _ -> nil
    end
  end

  defp parse_number(value) when is_number(value), do: value
  defp parse_number(value) when is_binary(value), do: parse_float(value)
  defp parse_number(_value), do: nil

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_float(_value), do: nil
end
