defmodule CriptoTrader.LiveSim.OrderFill do
  @moduledoc """
  Pure fill simulation for live strategy paper trading.

  Volume check prevents unrealistic fills on thin candles:
  - Limit BUY: fills only if order_value <= 5% of taker buy quote volume
  - Limit SELL: fills only if order_value <= 5% of taker sell quote volume
  """

  @doc """
  Try to fill a pending order against a closed candle.
  Returns `{:filled, price}` or `:pending`.
  """
  def try_fill(order, candle) do
    low = get_float(candle, :low)
    high = get_float(candle, :high)
    close = get_float(candle, :close)
    taker_buy_vol = get_float(candle, :taker_buy_quote_volume)
    quote_vol = get_float(candle, :quote_volume)
    taker_sell_vol = quote_vol - taker_buy_vol

    type = Map.get(order, :type, "MARKET")
    side = Map.get(order, :side, "")
    price = parse_float(Map.get(order, :price))
    qty = parse_float(Map.get(order, :quantity))

    case {type, side} do
      {"MARKET", _} ->
        {:filled, close}

      {"LIMIT", "BUY"} ->
        order_value = price * qty

        if low <= price and order_value <= taker_buy_vol * 0.05 do
          {:filled, price}
        else
          :pending
        end

      {"LIMIT", "SELL"} ->
        order_value = price * qty

        if high >= price and order_value <= taker_sell_vol * 0.05 do
          {:filled, price}
        else
          :pending
        end

      _ ->
        {:filled, close}
    end
  end

  defp get_float(map, key) when is_map(map) do
    parse_float(Map.get(map, key) || Map.get(map, Atom.to_string(key)))
  end

  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v * 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(_), do: 0.0
end
