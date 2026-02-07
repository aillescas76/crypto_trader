defmodule CriptoTrader.Risk.Config do
  @moduledoc false

  alias CriptoTrader.Config

  defstruct max_order_quote: 100.0,
            max_drawdown_pct: 0.2,
            circuit_breaker: false

  @type t :: %__MODULE__{
          max_order_quote: float() | nil,
          max_drawdown_pct: float() | nil,
          circuit_breaker: boolean()
        }

  @spec default() :: t()
  def default do
    risk = Config.risk_config()

    %__MODULE__{
      max_order_quote: parse_float(Keyword.get(risk, :max_order_quote), 100.0),
      max_drawdown_pct: parse_float(Keyword.get(risk, :max_drawdown_pct), 0.2),
      circuit_breaker: parse_bool(Keyword.get(risk, :circuit_breaker), false)
    }
  end

  defp parse_float(nil, default), do: default
  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value * 1.0

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_float(_value, default), do: default

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when is_boolean(value), do: value

  defp parse_bool(value, default) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "1" -> true
      "yes" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      _ -> default
    end
  end

  defp parse_bool(_value, default), do: default
end
