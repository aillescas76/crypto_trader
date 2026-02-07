defmodule Mix.Tasks.Binance.FetchCandlesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup_all do
    Mix.start()
    :ok
  end

  setup do
    previous_fetch_fun = Application.get_env(:cripto_trader, :candles_fetch_fun)
    previous_archive_fetch_fun = Application.get_env(:cripto_trader, :archive_candles_fetch_fun)
    previous_skip_app_start = Application.get_env(:cripto_trader, :skip_mix_app_start)
    Application.put_env(:cripto_trader, :skip_mix_app_start, true)

    on_exit(fn ->
      if previous_fetch_fun == nil do
        Application.delete_env(:cripto_trader, :candles_fetch_fun)
      else
        Application.put_env(:cripto_trader, :candles_fetch_fun, previous_fetch_fun)
      end

      if previous_archive_fetch_fun == nil do
        Application.delete_env(:cripto_trader, :archive_candles_fetch_fun)
      else
        Application.put_env(
          :cripto_trader,
          :archive_candles_fetch_fun,
          previous_archive_fetch_fun
        )
      end

      if previous_skip_app_start == nil do
        Application.delete_env(:cripto_trader, :skip_mix_app_start)
      else
        Application.put_env(:cripto_trader, :skip_mix_app_start, previous_skip_app_start)
      end
    end)

    :ok
  end

  test "fetches candles and prints JSON payload" do
    parent = self()

    Application.put_env(:cripto_trader, :candles_fetch_fun, fn opts ->
      send(parent, {:fetch_opts, opts})

      {:ok,
       %{
         "BTCUSDT" => [
           %{
             open_time: 1_704_067_200_000,
             open: "100.0",
             high: "102.0",
             low: "99.0",
             close: "101.0",
             volume: "10.0",
             close_time: 1_704_067_259_999,
             quote_asset_volume: "1010.0",
             number_of_trades: 20,
             taker_buy_base_volume: "4.0",
             taker_buy_quote_volume: "404.0"
           }
         ]
       }}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--symbol",
          "btcusdt",
          "--interval",
          "1m",
          "--start-time",
          "2024-01-01T00:00:00Z",
          "--end-time",
          "2024-01-01T00:15:00Z",
          "--limit",
          "500"
        ])
      end)

    assert_receive {:fetch_opts, opts}
    assert Keyword.fetch!(opts, :symbols) == ["BTCUSDT"]
    assert Keyword.fetch!(opts, :interval) == "1m"
    assert Keyword.fetch!(opts, :start_time) == 1_704_067_200_000
    assert Keyword.fetch!(opts, :end_time) == 1_704_068_100_000
    assert Keyword.fetch!(opts, :limit) == 500

    payload = Jason.decode!(output)
    assert payload["source"] == "binance_spot_rest"
    assert payload["interval"] == "1m"
    assert payload["start_time"] == 1_704_067_200_000
    assert payload["end_time"] == 1_704_068_100_000

    assert [%{"symbol" => "BTCUSDT", "candles" => [candle]}] = payload["symbols"]
    assert candle["open_time"] == 1_704_067_200_000
    assert candle["close"] == "101.0"
  end

  test "merges --symbol and --symbols with normalization and de-duplication" do
    parent = self()

    Application.put_env(:cripto_trader, :candles_fetch_fun, fn opts ->
      send(parent, {:fetch_opts, opts})
      {:ok, %{"ETHUSDT" => [], "BTCUSDT" => []}}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--symbol",
          "ethusdt",
          "--symbols",
          "ETHUSDT,btcusdt",
          "--interval",
          "15m"
        ])
      end)

    assert_receive {:fetch_opts, opts}
    assert Keyword.fetch!(opts, :symbols) == ["ETHUSDT", "BTCUSDT"]
    assert Keyword.fetch!(opts, :interval) == "15m"
    assert Keyword.fetch!(opts, :limit) == 1_000
    assert Keyword.get(opts, :start_time) == nil
    assert Keyword.get(opts, :end_time) == nil

    payload = Jason.decode!(output)
    assert Enum.map(payload["symbols"], & &1["symbol"]) == ["ETHUSDT", "BTCUSDT"]
  end

  test "supports archive source via --source archive" do
    parent = self()

    Application.put_env(:cripto_trader, :archive_candles_fetch_fun, fn opts ->
      send(parent, {:archive_fetch_opts, opts})
      {:ok, %{"BTCUSDT" => []}}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--source",
          "archive",
          "--symbol",
          "BTCUSDT",
          "--interval",
          "1h",
          "--start-time",
          "2024-01-01T00:00:00Z",
          "--end-time",
          "2024-02-01T00:00:00Z"
        ])
      end)

    assert_receive {:archive_fetch_opts, opts}
    assert Keyword.fetch!(opts, :symbols) == ["BTCUSDT"]
    assert Keyword.fetch!(opts, :interval) == "1h"
    assert Keyword.fetch!(opts, :start_time) == 1_704_067_200_000
    assert Keyword.fetch!(opts, :end_time) == 1_706_745_600_000
    refute Keyword.has_key?(opts, :limit)

    payload = Jason.decode!(output)
    assert payload["source"] == "binance_spot_archive"
    assert payload["interval"] == "1h"
    assert payload["symbols"] == [%{"symbol" => "BTCUSDT", "candles" => []}]
  end

  test "prints CSV payload when --format csv is selected" do
    parent = self()

    Application.put_env(:cripto_trader, :candles_fetch_fun, fn opts ->
      send(parent, {:fetch_opts, opts})

      {:ok,
       %{
         "BTCUSDT" => [
           %{
             open_time: 1_704_067_200_000,
             open: "100.0",
             high: "102.0",
             low: "99.0",
             close: "101.0",
             volume: "10.0",
             close_time: 1_704_067_259_999,
             quote_asset_volume: "1010.0",
             number_of_trades: 20,
             taker_buy_base_volume: "4.0",
             taker_buy_quote_volume: "404.0"
           }
         ]
       }}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--symbol",
          "BTCUSDT",
          "--interval",
          "1m",
          "--start-time",
          "2024-01-01T00:00:00Z",
          "--end-time",
          "2024-01-01T00:15:00Z",
          "--format",
          "csv"
        ])
      end)

    assert_receive {:fetch_opts, opts}
    assert Keyword.fetch!(opts, :symbols) == ["BTCUSDT"]
    assert Keyword.fetch!(opts, :interval) == "1m"

    lines =
      output
      |> String.trim()
      |> String.split("\n")

    assert [
             "source,interval,start_time,end_time,symbol,open_time,open,high,low,close,volume,close_time,quote_asset_volume,number_of_trades,taker_buy_base_volume,taker_buy_quote_volume",
             "binance_spot_rest,1m,1704067200000,1704068100000,BTCUSDT,1704067200000,100.0,102.0,99.0,101.0,10.0,1704067259999,1010.0,20,4.0,404.0"
           ] == lines
  end

  test "archive source requires explicit start and end times" do
    assert_raise Mix.Error, ~r/--source archive requires both --start-time and --end-time/, fn ->
      run_task([
        "--source",
        "archive",
        "--symbol",
        "BTCUSDT",
        "--interval",
        "1h"
      ])
    end
  end

  test "rejects invalid --format value" do
    assert_raise Mix.Error, ~r/Invalid --format. Accepted values: json, csv/, fn ->
      run_task([
        "--symbol",
        "BTCUSDT",
        "--interval",
        "1m",
        "--format",
        "yaml"
      ])
    end
  end

  defp run_task(args) do
    Mix.Tasks.Binance.FetchCandles.run(args)
  end
end
