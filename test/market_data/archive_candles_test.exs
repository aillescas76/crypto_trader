defmodule CriptoTrader.MarketData.ArchiveCandlesTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.MarketData.ArchiveCandles

  test "fetches monthly archive candles across a range and filters by start/end time" do
    parent = self()
    base_url = "https://archive.test/data/spot/monthly/klines"
    jan_10 = unix_ms!("2024-01-10T00:00:00Z")
    jan_20 = unix_ms!("2024-01-20T00:00:00Z")
    feb_10 = unix_ms!("2024-02-10T00:00:00Z")
    start_time = unix_ms!("2024-01-15T00:00:00Z")
    end_time = unix_ms!("2024-02-15T00:00:00Z")

    jan_zip = archive_zip([kline_csv_line(jan_10), kline_csv_line(jan_20)])
    feb_zip = archive_zip([kline_csv_line(feb_10)])

    download_fun = fn url ->
      send(parent, {:download_url, url})

      cond do
        String.ends_with?(url, "BTCUSDT-1h-2024-01.zip") -> {:ok, jan_zip}
        String.ends_with?(url, "BTCUSDT-1h-2024-02.zip") -> {:ok, feb_zip}
        true -> {:error, :not_found}
      end
    end

    assert {:ok, %{"BTCUSDT" => candles}} =
             ArchiveCandles.fetch(
               symbols: ["BTCUSDT"],
               interval: "1h",
               start_time: start_time,
               end_time: end_time,
               base_url: base_url,
               download_fun: download_fun
             )

    assert Enum.map(candles, & &1.open_time) == [jan_20, feb_10]

    assert_receive {:download_url, url_1}
    assert_receive {:download_url, url_2}

    assert url_1 == "#{base_url}/BTCUSDT/1h/BTCUSDT-1h-2024-01.zip"
    assert url_2 == "#{base_url}/BTCUSDT/1h/BTCUSDT-1h-2024-02.zip"
  end

  test "treats missing archive months as empty data and continues" do
    start_time = unix_ms!("2024-01-01T00:00:00Z")
    end_time = unix_ms!("2024-02-01T00:00:00Z")
    jan_15 = unix_ms!("2024-01-15T00:00:00Z")
    jan_zip = archive_zip([kline_csv_line(jan_15)])

    download_fun = fn url ->
      if String.ends_with?(url, "ETHUSDT-15m-2024-01.zip"),
        do: {:ok, jan_zip},
        else: {:error, :not_found}
    end

    assert {:ok, %{"BTCUSDT" => [], "ETHUSDT" => candles}} =
             ArchiveCandles.fetch(
               symbols: ["BTCUSDT", "ETHUSDT"],
               interval: "15m",
               start_time: start_time,
               end_time: end_time,
               download_fun: download_fun
             )

    assert Enum.map(candles, & &1.open_time) == [jan_15]
  end

  test "requires a valid closed time range" do
    assert {:error, :invalid_time_range} =
             ArchiveCandles.fetch(
               symbols: ["BTCUSDT"],
               interval: "1h",
               start_time: 2_000,
               end_time: 1_000
             )
  end

  defp kline_csv_line(open_time) do
    close_time = open_time + 59_999

    [
      open_time,
      "100.0",
      "101.0",
      "99.0",
      "100.5",
      "10.0",
      close_time,
      "1005.0",
      42,
      "4.0",
      "402.0",
      "0"
    ]
    |> Enum.map(&to_string/1)
    |> Enum.join(",")
  end

  describe "local disk cache" do
    test "caches downloaded zip to disk and reuses on subsequent calls" do
      cache_dir = Path.join(System.tmp_dir!(), "archive_cache_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(cache_dir) end)

      parent = self()
      start_time = unix_ms!("2024-01-01T00:00:00Z")
      end_time = unix_ms!("2024-01-31T23:59:59Z")
      jan_10 = unix_ms!("2024-01-10T00:00:00Z")
      jan_zip = archive_zip([kline_csv_line(jan_10)])

      download_fun = fn url ->
        send(parent, {:download_url, url})
        {:ok, jan_zip}
      end

      fetch_opts = [
        symbols: ["BTCUSDT"],
        interval: "1h",
        start_time: start_time,
        end_time: end_time,
        download_fun: download_fun,
        cache_dir: cache_dir
      ]

      # First call: hits network
      assert {:ok, %{"BTCUSDT" => [_]}} = ArchiveCandles.fetch(fetch_opts)
      assert_receive {:download_url, _}
      refute_receive {:download_url, _}, 50

      # Second call: reads from disk cache, no network
      assert {:ok, %{"BTCUSDT" => [_]}} = ArchiveCandles.fetch(fetch_opts)
      refute_receive {:download_url, _}, 50
    end

    test "stores zip file at a predictable path derived from symbol/interval/month" do
      cache_dir = Path.join(System.tmp_dir!(), "archive_cache_path_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(cache_dir) end)

      start_time = unix_ms!("2024-03-01T00:00:00Z")
      end_time = unix_ms!("2024-03-31T23:59:59Z")
      mar_5 = unix_ms!("2024-03-05T00:00:00Z")
      mar_zip = archive_zip([kline_csv_line(mar_5)])

      download_fun = fn _url -> {:ok, mar_zip} end

      ArchiveCandles.fetch(
        symbols: ["ETHUSDT"],
        interval: "15m",
        start_time: start_time,
        end_time: end_time,
        download_fun: download_fun,
        cache_dir: cache_dir
      )

      expected_path = Path.join([cache_dir, "ETHUSDT", "15m", "ETHUSDT-15m-2024-03.zip"])
      assert File.exists?(expected_path)
    end

    test "does not cache when download fails" do
      cache_dir = Path.join(System.tmp_dir!(), "archive_cache_fail_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(cache_dir) end)

      start_time = unix_ms!("2024-01-01T00:00:00Z")
      end_time = unix_ms!("2024-01-31T23:59:59Z")

      download_fun = fn _url -> {:error, :not_found} end

      assert {:ok, %{"BTCUSDT" => []}} =
               ArchiveCandles.fetch(
                 symbols: ["BTCUSDT"],
                 interval: "1h",
                 start_time: start_time,
                 end_time: end_time,
                 download_fun: download_fun,
                 cache_dir: cache_dir
               )

      # Nothing should have been cached
      assert not File.exists?(cache_dir)
    end
  end

  defp archive_zip(lines) do
    csv = Enum.join(lines, "\n") <> "\n"
    {:ok, {_name, binary}} = :zip.create(~c"klines.zip", [{~c"klines.csv", csv}], [:memory])
    binary
  end

  defp unix_ms!(iso8601) do
    {:ok, datetime, 0} = DateTime.from_iso8601(iso8601)
    DateTime.to_unix(datetime, :millisecond)
  end
end
