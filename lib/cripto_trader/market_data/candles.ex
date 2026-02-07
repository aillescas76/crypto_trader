defmodule CriptoTrader.MarketData.Candles do
  @moduledoc """
  Fetches Binance Spot candle (kline) data with deterministic pagination.
  """

  alias CriptoTrader.Binance.{Client, Spot}

  @max_limit 1_000

  @type kline :: %{
          open_time: integer(),
          open: String.t(),
          high: String.t(),
          low: String.t(),
          close: String.t(),
          volume: String.t(),
          close_time: integer(),
          quote_asset_volume: String.t(),
          number_of_trades: integer(),
          taker_buy_base_volume: String.t(),
          taker_buy_quote_volume: String.t()
        }

  @type fetch_opts :: [
          {:symbols, [String.t()]},
          {:interval, String.t()},
          {:start_time, integer() | nil},
          {:end_time, integer() | nil},
          {:limit, pos_integer()},
          {:max_concurrency, pos_integer()},
          {:client, Client.t()},
          {:klines_fun, (Client.t(), keyword() -> {:ok, list()} | {:error, term()})}
        ]

  @spec fetch(fetch_opts()) :: {:ok, %{String.t() => [kline()]}} | {:error, term()}
  def fetch(opts) do
    with {:ok, symbols} <- validate_symbols(Keyword.get(opts, :symbols, [])),
         {:ok, interval} <- validate_interval(Keyword.get(opts, :interval)),
         {:ok, limit} <- validate_limit(Keyword.get(opts, :limit, @max_limit)),
         {:ok, start_time, end_time} <-
           validate_range(Keyword.get(opts, :start_time), Keyword.get(opts, :end_time)) do
      client = Keyword.get(opts, :client, Client.new())
      klines_fun = Keyword.get(opts, :klines_fun, &Spot.klines/2)

      max_concurrency =
        parse_max_concurrency(Keyword.get(opts, :max_concurrency, length(symbols)))

      fetch_symbols_concurrently(
        symbols,
        interval,
        start_time,
        end_time,
        limit,
        client,
        klines_fun,
        max_concurrency
      )
    end
  end

  defp fetch_symbols_concurrently(
         symbols,
         interval,
         start_time,
         end_time,
         limit,
         client,
         klines_fun,
         max_concurrency
       ) do
    symbols
    |> Task.async_stream(
      fn symbol ->
        {symbol, fetch_symbol(symbol, interval, start_time, end_time, limit, client, klines_fun)}
      end,
      ordered: false,
      max_concurrency: max_concurrency,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {symbol, {:ok, candles}}}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, symbol, candles)}}

      {:ok, {symbol, {:error, reason}}}, _acc ->
        {:halt, {:error, %{symbol: symbol, reason: reason}}}

      {:exit, reason}, _acc ->
        {:halt, {:error, %{symbol: :unknown, reason: {:fetch_task_failed, reason}}}}
    end)
  end

  defp fetch_symbol(symbol, interval, start_time, end_time, limit, client, klines_fun) do
    do_fetch_symbol(
      symbol,
      interval,
      start_time,
      start_time,
      end_time,
      limit,
      client,
      klines_fun,
      []
    )
  end

  defp do_fetch_symbol(
         symbol,
         interval,
         cursor,
         range_start,
         end_time,
         limit,
         client,
         klines_fun,
         acc_rev
       ) do
    params =
      [
        symbol: symbol,
        interval: interval,
        limit: limit,
        startTime: cursor,
        endTime: end_time
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case klines_fun.(client, params) do
      {:ok, []} ->
        {:ok, Enum.reverse(acc_rev)}

      {:ok, batch} when is_list(batch) ->
        with {:ok, normalized} <- normalize_batch(batch) do
          in_range = filter_by_time_range(normalized, range_start, end_time)
          updated_acc = Enum.reduce(in_range, acc_rev, fn candle, acc -> [candle | acc] end)

          cond do
            length(batch) < limit ->
              {:ok, Enum.reverse(updated_acc)}

            true ->
              next_start = normalized |> List.last() |> Map.fetch!(:open_time) |> Kernel.+(1)

              cond do
                pagination_stalled?(cursor, next_start) ->
                  {:error, {:pagination_stalled, cursor, next_start}}

                is_integer(end_time) and next_start > end_time ->
                  {:ok, Enum.reverse(updated_acc)}

                true ->
                  do_fetch_symbol(
                    symbol,
                    interval,
                    next_start,
                    range_start,
                    end_time,
                    limit,
                    client,
                    klines_fun,
                    updated_acc
                  )
              end
          end
        end

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_batch(batch) do
    Enum.reduce_while(batch, {:ok, []}, fn raw_kline, {:ok, acc} ->
      case normalize_kline(raw_kline) do
        {:ok, kline} -> {:cont, {:ok, [kline | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} ->
        sorted =
          reversed
          |> Enum.reverse()
          |> Enum.with_index()
          |> Enum.sort_by(fn {kline, index} -> {kline.open_time, index} end)
          |> Enum.map(&elem(&1, 0))

        {:ok, sorted}

      error ->
        error
    end
  end

  defp normalize_kline([
         open_time,
         open,
         high,
         low,
         close,
         volume,
         close_time,
         quote_asset_volume,
         number_of_trades,
         taker_buy_base_volume,
         taker_buy_quote_volume,
         _ignore
       ])
       when is_integer(open_time) and is_integer(close_time) and is_integer(number_of_trades) do
    {:ok,
     %{
       open_time: open_time,
       open: open,
       high: high,
       low: low,
       close: close,
       volume: volume,
       close_time: close_time,
       quote_asset_volume: quote_asset_volume,
       number_of_trades: number_of_trades,
       taker_buy_base_volume: taker_buy_base_volume,
       taker_buy_quote_volume: taker_buy_quote_volume
     }}
  end

  defp normalize_kline(_), do: {:error, :unexpected_kline_payload}

  defp filter_by_time_range(candles, start_time, end_time) when is_list(candles) do
    Enum.filter(candles, fn candle ->
      open_time = candle.open_time
      in_lower_bound = is_nil(start_time) or open_time >= start_time
      in_upper_bound = is_nil(end_time) or open_time <= end_time
      in_lower_bound and in_upper_bound
    end)
  end

  defp pagination_stalled?(cursor, next_start)
       when is_integer(cursor) and is_integer(next_start) do
    next_start <= cursor
  end

  defp pagination_stalled?(_cursor, _next_start), do: false

  defp validate_symbols(symbols) when is_list(symbols) do
    symbols =
      symbols
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if symbols == [] do
      {:error, :symbols_required}
    else
      {:ok, symbols}
    end
  end

  defp validate_symbols(_), do: {:error, :symbols_required}

  defp validate_interval(interval) when is_binary(interval) do
    interval = String.trim(interval)

    if interval == "", do: {:error, :interval_required}, else: {:ok, interval}
  end

  defp validate_interval(_), do: {:error, :interval_required}

  defp validate_limit(limit) when is_integer(limit) and limit > 0 and limit <= @max_limit,
    do: {:ok, limit}

  defp validate_limit(_), do: {:error, :invalid_limit}

  defp parse_max_concurrency(value) when is_integer(value) and value > 0, do: value
  defp parse_max_concurrency(_value), do: 1

  defp validate_range(nil, nil), do: {:ok, nil, nil}
  defp validate_range(start_time, nil) when is_integer(start_time), do: {:ok, start_time, nil}
  defp validate_range(nil, end_time) when is_integer(end_time), do: {:ok, nil, end_time}

  defp validate_range(start_time, end_time)
       when is_integer(start_time) and is_integer(end_time) and start_time <= end_time,
       do: {:ok, start_time, end_time}

  defp validate_range(_start_time, _end_time), do: {:error, :invalid_time_range}
end
