defmodule CriptoTrader.MarketData.ArchiveCandles do
  @moduledoc """
  Fetches Binance Spot monthly archive candles for long-range analysis.
  """

  @archive_base_url "https://data.binance.vision/data/spot/monthly/klines"

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
          {:start_time, integer()},
          {:end_time, integer()},
          {:base_url, String.t()},
          {:download_fun, (String.t() -> {:ok, binary()} | {:error, term()})}
        ]

  @spec fetch(fetch_opts()) :: {:ok, %{String.t() => [kline()]}} | {:error, term()}
  def fetch(opts) do
    with {:ok, symbols} <- validate_symbols(Keyword.get(opts, :symbols, [])),
         {:ok, interval} <- validate_interval(Keyword.get(opts, :interval)),
         {:ok, start_time, end_time} <-
           validate_range(Keyword.get(opts, :start_time), Keyword.get(opts, :end_time)),
         {:ok, month_keys} <- month_keys(start_time, end_time),
         {:ok, download_fun} <- validate_download_fun(Keyword.get(opts, :download_fun)) do
      base_url = Keyword.get(opts, :base_url, @archive_base_url)
      cache_dir = Keyword.get(opts, :cache_dir)
      download_fun = maybe_wrap_with_cache(download_fun, cache_dir)

      Enum.reduce_while(symbols, {:ok, %{}}, fn symbol, {:ok, acc} ->
        case fetch_symbol(
               symbol,
               interval,
               start_time,
               end_time,
               month_keys,
               base_url,
               download_fun
             ) do
          {:ok, candles} ->
            {:cont, {:ok, Map.put(acc, symbol, candles)}}

          {:error, reason} ->
            {:halt, {:error, %{symbol: symbol, reason: reason}}}
        end
      end)
    end
  end

  defp fetch_symbol(symbol, interval, start_time, end_time, month_keys, base_url, download_fun) do
    month_keys
    |> Enum.reduce_while({:ok, []}, fn {year, month}, {:ok, acc} ->
      archive_url = archive_url(base_url, symbol, interval, year, month)

      case fetch_month_archive(download_fun, archive_url) do
        {:ok, candles} -> {:cont, {:ok, candles ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, candles} ->
        filtered =
          candles
          |> Enum.filter(fn candle ->
            candle.open_time >= start_time and candle.open_time <= end_time
          end)
          |> Enum.sort_by(& &1.open_time)

        {:ok, filtered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_month_archive(download_fun, archive_url) do
    case download_fun.(archive_url) do
      {:ok, archive_binary} when is_binary(archive_binary) ->
        parse_archive(archive_binary)

      {:error, :not_found} ->
        {:ok, []}

      {:error, {:http_status, 404}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:archive_download_failed, archive_url, reason}}

      other ->
        {:error, {:invalid_archive_download_response, archive_url, other}}
    end
  end

  defp parse_archive(archive_binary) do
    with {:ok, files} <- :zip.extract(archive_binary, [:memory]),
         {:ok, csv_binary} <- find_csv(files),
         {:ok, candles} <- parse_csv_klines(csv_binary) do
      {:ok, candles}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_csv(files) when is_list(files) do
    files
    |> Enum.find_value(fn
      {name, content} ->
        filename = to_string(name)

        if String.ends_with?(filename, ".csv") do
          {:ok, IO.iodata_to_binary(content)}
        else
          nil
        end

      _ ->
        nil
    end)
    |> case do
      nil -> {:error, :archive_csv_not_found}
      result -> result
    end
  end

  defp parse_csv_klines(csv_binary) when is_binary(csv_binary) do
    csv_binary
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case parse_csv_line(line) do
        {:ok, kline} ->
          {:cont, {:ok, [kline | acc]}}

        :skip ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, klines_reversed} -> {:ok, Enum.reverse(klines_reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_csv_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :skip

      String.starts_with?(trimmed, "open_time") ->
        :skip

      true ->
        fields = String.split(trimmed, ",")

        case fields do
          [
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
            taker_buy_quote_volume
            | _ignore
          ] ->
            with {:ok, parsed_open_time} <- parse_non_neg_int(open_time),
                 {:ok, parsed_close_time} <- parse_non_neg_int(close_time),
                 {:ok, parsed_number_of_trades} <- parse_non_neg_int(number_of_trades) do
              {:ok,
               %{
                 open_time: to_milliseconds(parsed_open_time),
                 open: open,
                 high: high,
                 low: low,
                 close: close,
                 volume: volume,
                 close_time: to_milliseconds(parsed_close_time),
                 quote_asset_volume: quote_asset_volume,
                 number_of_trades: parsed_number_of_trades,
                 taker_buy_base_volume: taker_buy_base_volume,
                 taker_buy_quote_volume: taker_buy_quote_volume
               }}
            end

          _ ->
            {:error, {:invalid_archive_csv_line, line}}
        end
    end
  end

  defp validate_symbols(symbols) when is_list(symbols) do
    symbols =
      symbols
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if symbols == [], do: {:error, :symbols_required}, else: {:ok, symbols}
  end

  defp validate_symbols(_), do: {:error, :symbols_required}

  defp validate_interval(interval) when is_binary(interval) do
    interval = String.trim(interval)
    if interval == "", do: {:error, :interval_required}, else: {:ok, interval}
  end

  defp validate_interval(_), do: {:error, :interval_required}

  defp validate_range(start_time, end_time)
       when is_integer(start_time) and is_integer(end_time) and start_time <= end_time do
    {:ok, start_time, end_time}
  end

  defp validate_range(_start_time, _end_time), do: {:error, :invalid_time_range}

  defp validate_download_fun(nil), do: {:ok, &default_download/1}

  defp validate_download_fun(download_fun) when is_function(download_fun, 1),
    do: {:ok, download_fun}

  defp validate_download_fun(_), do: {:error, :invalid_download_fun}

  defp maybe_wrap_with_cache(download_fun, nil), do: download_fun

  defp maybe_wrap_with_cache(download_fun, cache_dir) when is_binary(cache_dir) do
    fn url ->
      cache_path = cache_path(cache_dir, url)

      if File.exists?(cache_path) do
        {:ok, File.read!(cache_path)}
      else
        case download_fun.(url) do
          {:ok, binary} ->
            cache_path |> Path.dirname() |> File.mkdir_p!()
            File.write!(cache_path, binary)
            {:ok, binary}

          other ->
            other
        end
      end
    end
  end

  defp cache_path(cache_dir, url) do
    # Extract last 3 path segments: symbol/interval/filename.zip
    segments = url |> URI.parse() |> Map.get(:path, url) |> String.split("/") |> Enum.take(-3)
    Path.join([cache_dir | segments])
  end

  defp default_download(url) when is_binary(url) do
    case Req.get(url: url, decode_body: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp archive_url(base_url, symbol, interval, year, month) do
    suffix =
      "#{symbol}-#{interval}-#{year}-#{month |> Integer.to_string() |> String.pad_leading(2, "0")}.zip"

    "#{String.trim_trailing(base_url, "/")}/#{symbol}/#{interval}/#{suffix}"
  end

  defp month_keys(start_time, end_time) do
    start_date = DateTime.from_unix!(start_time, :millisecond) |> DateTime.to_date()
    end_date = DateTime.from_unix!(end_time, :millisecond) |> DateTime.to_date()

    {:ok, do_month_keys({start_date.year, start_date.month}, {end_date.year, end_date.month}, [])}
  end

  defp do_month_keys({year, month}, {end_year, end_month}, acc) do
    cond do
      year > end_year or (year == end_year and month > end_month) ->
        Enum.reverse(acc)

      true ->
        do_month_keys(next_month(year, month), {end_year, end_month}, [{year, month} | acc])
    end
  end

  defp next_month(year, 12), do: {year + 1, 1}
  defp next_month(year, month), do: {year, month + 1}

  defp parse_non_neg_int(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_non_neg_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_non_neg_int(_), do: {:error, :invalid_integer}

  # Binance switched from milliseconds to microseconds in 2025 archive files.
  # Normalize to milliseconds by dividing microsecond timestamps (16 digits) by 1000.
  defp to_milliseconds(ts) when ts > 9_999_999_999_999, do: div(ts, 1000)
  defp to_milliseconds(ts), do: ts
end
