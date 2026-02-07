defmodule Mix.Tasks.Binance.FetchCandles do
  use Mix.Task

  alias CriptoTrader.MarketData.{ArchiveCandles, Candles}

  @shortdoc "Fetch Binance Spot candles (klines) for one or more symbols"
  @max_limit 1_000
  @csv_columns [
    :source,
    :interval,
    :start_time,
    :end_time,
    :symbol,
    :open_time,
    :open,
    :high,
    :low,
    :close,
    :volume,
    :close_time,
    :quote_asset_volume,
    :number_of_trades,
    :taker_buy_base_volume,
    :taker_buy_quote_volume
  ]

  @impl Mix.Task
  def run(args) do
    maybe_start_app()

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        switches: [
          symbol: :keep,
          symbols: :string,
          source: :string,
          format: :string,
          interval: :string,
          start_time: :string,
          end_time: :string,
          limit: :integer
        ],
        aliases: [s: :symbol, i: :interval]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    symbols = parse_symbols(opts)
    source = parse_source!(Keyword.get(opts, :source, "rest"))
    format = parse_format!(Keyword.get(opts, :format, "json"))
    interval = required_string!(opts, :interval)
    start_time = parse_time!(Keyword.get(opts, :start_time))
    end_time = parse_time!(Keyword.get(opts, :end_time))
    fetch_opts = fetch_opts!(source, symbols, interval, start_time, end_time, opts)
    fetch_fun = candles_fetch_fun(source)

    case fetch_fun.(fetch_opts) do
      {:ok, candles_by_symbol} ->
        payload =
          %{
            source: output_source(source),
            interval: interval,
            start_time: start_time,
            end_time: end_time,
            symbols:
              Enum.map(symbols, fn symbol ->
                %{symbol: symbol, candles: Map.fetch!(candles_by_symbol, symbol)}
              end)
          }

        Mix.shell().info(render_output(payload, format))

      {:error, reason} ->
        Mix.raise("Failed to fetch candles: #{inspect(reason)}")
    end
  end

  defp fetch_opts!(:rest, symbols, interval, start_time, end_time, opts) do
    limit = parse_limit!(Keyword.get(opts, :limit, @max_limit))

    [
      symbols: symbols,
      interval: interval,
      start_time: start_time,
      end_time: end_time,
      limit: limit
    ]
  end

  defp fetch_opts!(:archive, symbols, interval, start_time, end_time, _opts) do
    ensure_archive_range!(start_time, end_time)

    [
      symbols: symbols,
      interval: interval,
      start_time: start_time,
      end_time: end_time
    ]
  end

  defp parse_symbols(opts) do
    explicit =
      opts
      |> Keyword.get_values(:symbol)
      |> Enum.map(&String.upcase/1)

    grouped =
      opts
      |> Keyword.get(:symbols, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.upcase/1)

    symbols = Enum.uniq(explicit ++ grouped)

    if symbols == [] do
      Mix.raise("At least one symbol is required (--symbol BTCUSDT or --symbols BTCUSDT,ETHUSDT)")
    end

    symbols
  end

  defp parse_source!(source) when is_binary(source) do
    case source |> String.trim() |> String.downcase() do
      "rest" -> :rest
      "archive" -> :archive
      _ -> Mix.raise("Invalid --source. Accepted values: rest, archive")
    end
  end

  defp parse_source!(_), do: Mix.raise("Invalid --source. Accepted values: rest, archive")

  defp parse_format!(format) when is_binary(format) do
    case format |> String.trim() |> String.downcase() do
      "json" -> :json
      "csv" -> :csv
      _ -> Mix.raise("Invalid --format. Accepted values: json, csv")
    end
  end

  defp parse_format!(_), do: Mix.raise("Invalid --format. Accepted values: json, csv")

  defp required_string!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        Mix.raise("Missing required option --#{key |> to_string() |> String.replace("_", "-")}")
    end
  end

  defp parse_time!(nil), do: nil

  defp parse_time!(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 ->
        int

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          _ -> Mix.raise("Invalid timestamp #{inspect(value)}. Use unix ms or ISO8601.")
        end
    end
  end

  defp parse_limit!(limit) when is_integer(limit) and limit > 0 and limit <= @max_limit, do: limit

  defp parse_limit!(_), do: Mix.raise("Invalid --limit. Accepted range: 1..#{@max_limit}")

  defp ensure_archive_range!(start_time, end_time)
       when is_integer(start_time) and is_integer(end_time) do
    :ok
  end

  defp ensure_archive_range!(_start_time, _end_time) do
    Mix.raise("--source archive requires both --start-time and --end-time")
  end

  defp maybe_start_app do
    unless Application.get_env(:cripto_trader, :skip_mix_app_start, false) do
      Mix.Task.run("app.start")
    end
  end

  defp candles_fetch_fun(:rest) do
    case Application.get_env(:cripto_trader, :candles_fetch_fun) do
      nil -> &Candles.fetch/1
      fun when is_function(fun, 1) -> fun
      other -> Mix.raise("Invalid :candles_fetch_fun config: #{inspect(other)}")
    end
  end

  defp candles_fetch_fun(:archive) do
    case Application.get_env(:cripto_trader, :archive_candles_fetch_fun) do
      nil -> &ArchiveCandles.fetch/1
      fun when is_function(fun, 1) -> fun
      other -> Mix.raise("Invalid :archive_candles_fetch_fun config: #{inspect(other)}")
    end
  end

  defp output_source(:rest), do: "binance_spot_rest"
  defp output_source(:archive), do: "binance_spot_archive"

  defp render_output(payload, :json), do: Jason.encode!(payload, pretty: true)

  defp render_output(payload, :csv) do
    header = Enum.map_join(@csv_columns, ",", &Atom.to_string/1)

    rows =
      payload.symbols
      |> Enum.flat_map(fn %{symbol: symbol, candles: candles} ->
        Enum.map(candles, fn candle ->
          [
            payload.source,
            payload.interval,
            payload.start_time,
            payload.end_time,
            symbol,
            candle_field(candle, :open_time),
            candle_field(candle, :open),
            candle_field(candle, :high),
            candle_field(candle, :low),
            candle_field(candle, :close),
            candle_field(candle, :volume),
            candle_field(candle, :close_time),
            candle_field(candle, :quote_asset_volume),
            candle_field(candle, :number_of_trades),
            candle_field(candle, :taker_buy_base_volume),
            candle_field(candle, :taker_buy_quote_volume)
          ]
          |> Enum.map_join(",", &csv_cell/1)
        end)
      end)

    Enum.join([header | rows], "\n")
  end

  defp candle_field(candle, key) when is_map(candle) do
    Map.get(candle, key) || Map.get(candle, Atom.to_string(key))
  end

  defp csv_cell(nil), do: ""
  defp csv_cell(value) when is_integer(value), do: Integer.to_string(value)
  defp csv_cell(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact])

  defp csv_cell(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\"", "\"\"")

    if String.contains?(escaped, [",", "\"", "\n", "\r"]) do
      ~s("#{escaped}")
    else
      escaped
    end
  end
end
