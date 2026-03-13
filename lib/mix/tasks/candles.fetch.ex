defmodule Mix.Tasks.Candles.Fetch do
  @shortdoc "Populate the candle history DB from Binance archive or local CSV"

  @moduledoc """
  Fetches and stores OHLCV candles into the SQLite database.

  ## Archive mode (downloads from Binance Vision monthly archives)

      mix candles.fetch --symbol BTCUSDC --interval 1h --from 2024-01-01 --to 2024-12-31

  ## CSV import mode (Binance Vision column format)

      mix candles.fetch --symbol BTCUSDC --interval 1h --file /path/to/data.csv

  CSV column order (no header, 11 columns):
      open_time, open, high, low, close, volume, close_time,
      quote_asset_volume, number_of_trades, taker_buy_base_volume, taker_buy_quote_volume

  Options:
    --symbol    Required. Trading pair, e.g. BTCUSDC
    --interval  Required. Candle interval: 15m | 1h | 4h | 1d
    --from      Archive mode: start date (YYYY-MM-DD, inclusive)
    --to        Archive mode: end date (YYYY-MM-DD, defaults to today)
    --file      CSV mode: path to local CSV file
  """

  use Mix.Task

  alias CriptoTrader.CandleDB
  alias CriptoTrader.MarketData.ArchiveCandles

  # Use atom keys to avoid mixed-key maps rejected by Ecto.Changeset.cast/4.
  # Names match Binance field names; Candle.normalize/1 handles aliases.
  @csv_columns ~w(open_time open high low close volume close_time
                  quote_asset_volume number_of_trades
                  taker_buy_base_volume taker_buy_quote_volume)a

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [symbol: :string, interval: :string, from: :string, to: :string, file: :string]
      )

    symbol = opts[:symbol] || abort("--symbol is required")
    interval = opts[:interval] || abort("--interval is required")

    cond do
      opts[:file] -> import_csv(symbol, interval, opts[:file])
      opts[:from] -> fetch_archive(symbol, interval, opts[:from], opts[:to] || Date.to_string(Date.utc_today()))
      true -> abort("Provide --file for CSV import or --from/--to for archive fetch")
    end
  end

  # -- CSV import --

  defp import_csv(symbol, interval, path) do
    unless File.exists?(path), do: abort("File not found: #{path}")

    Mix.shell().info("Importing #{path} for #{symbol} #{interval}...")

    candles =
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&parse_csv_row(&1, symbol, interval))
      |> Enum.reject(&is_nil/1)

    case CandleDB.insert_candles(candles) do
      {:ok, count} -> Mix.shell().info("Done — #{count} candle(s) inserted/updated.")
      {:error, reason} -> abort("DB error: #{inspect(reason)}")
    end
  end

  defp parse_csv_row(line, symbol, interval) do
    # Take at most 11 values — Binance Vision files may have a trailing comma
    values = line |> String.split(",") |> Enum.take(11)

    if length(values) < 11 do
      nil
    else
      @csv_columns
      |> Enum.zip(values)
      |> Map.new()
      |> Map.merge(%{symbol: symbol, interval: interval})
      |> coerce_integers([:open_time, :close_time, :number_of_trades])
    end
  end

  defp coerce_integers(map, keys) do
    Enum.reduce(keys, map, fn k, acc ->
      case Map.get(acc, k) do
        nil -> acc
        v -> Map.put(acc, k, String.to_integer(String.trim(v)))
      end
    end)
  end

  # -- Archive fetch --

  defp fetch_archive(symbol, interval, from_str, to_str) do
    start_ms = parse_date!(from_str)
    end_ms = parse_date!(to_str)

    Mix.shell().info("Fetching #{symbol} #{interval} #{from_str}..#{to_str} from Binance archive...")

    case ArchiveCandles.fetch(symbols: [symbol], interval: interval, start_time: start_ms, end_time: end_ms) do
      {:ok, candles_by_symbol} ->
        candles =
          candles_by_symbol
          |> Map.get(symbol, [])
          |> Enum.map(&Map.merge(&1, %{symbol: symbol, interval: interval}))

        case CandleDB.insert_candles(candles) do
          {:ok, count} -> Mix.shell().info("Done — #{count} candle(s) inserted/updated.")
          {:error, reason} -> abort("DB error: #{inspect(reason)}")
        end

      {:error, reason} ->
        abort("Fetch failed: #{inspect(reason)}")
    end
  end

  defp parse_date!(str) do
    str
    |> Date.from_iso8601!()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp abort(msg) do
    Mix.shell().error(msg)
    exit({:shutdown, 1})
  end
end
