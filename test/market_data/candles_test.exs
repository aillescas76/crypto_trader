defmodule CriptoTrader.MarketData.CandlesTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.MarketData.Candles

  test "paginates by startTime and accumulates normalized candles" do
    parent = self()

    first_batch = [
      raw_kline(1_000, 1_059),
      raw_kline(2_000, 2_059)
    ]

    second_batch = [
      raw_kline(3_000, 3_059)
    ]

    klines_fun = fn _client, params ->
      send(parent, {:request, params})

      case Keyword.get(params, :startTime) do
        nil -> {:ok, first_batch}
        2_001 -> {:ok, second_batch}
        other -> {:error, {:unexpected_cursor, other}}
      end
    end

    assert {:ok, %{"BTCUSDT" => candles}} =
             Candles.fetch(
               symbols: ["BTCUSDT"],
               interval: "1m",
               limit: 2,
               klines_fun: klines_fun
             )

    assert Enum.map(candles, & &1.open_time) == [1_000, 2_000, 3_000]
    assert [%{open: "100.0", close: "101.0"}, %{open: "100.0", close: "101.0"} | _] = candles

    assert_receive {:request, [symbol: "BTCUSDT", interval: "1m", limit: 2]}
    assert_receive {:request, [symbol: "BTCUSDT", interval: "1m", limit: 2, startTime: 2_001]}
  end

  test "sorts out-of-order batches before pagination cursor advancement" do
    parent = self()

    first_batch = [
      raw_kline(3_000, 3_059),
      raw_kline(1_000, 1_059),
      raw_kline(2_000, 2_059)
    ]

    klines_fun = fn _client, params ->
      send(parent, {:request, params})

      case Keyword.get(params, :startTime) do
        nil -> {:ok, first_batch}
        3_001 -> {:ok, []}
        other -> {:error, {:unexpected_cursor, other}}
      end
    end

    assert {:ok, %{"BTCUSDT" => candles}} =
             Candles.fetch(
               symbols: ["BTCUSDT"],
               interval: "1m",
               limit: 3,
               klines_fun: klines_fun
             )

    assert Enum.map(candles, & &1.open_time) == [1_000, 2_000, 3_000]

    assert_receive {:request, [symbol: "BTCUSDT", interval: "1m", limit: 3]}
    assert_receive {:request, [symbol: "BTCUSDT", interval: "1m", limit: 3, startTime: 3_001]}
  end

  test "preserves stable order for tied open_time values within one batch" do
    tied_batch = [
      raw_kline(1_000, 1_059, "101.0"),
      raw_kline(1_000, 1_059, "102.0"),
      raw_kline(2_000, 2_059, "103.0")
    ]

    klines_fun = fn _client, _params ->
      {:ok, tied_batch}
    end

    assert {:ok, %{"BTCUSDT" => candles}} =
             Candles.fetch(
               symbols: ["BTCUSDT"],
               interval: "1m",
               limit: 10,
               klines_fun: klines_fun
             )

    assert Enum.map(candles, & &1.open_time) == [1_000, 1_000, 2_000]
    assert Enum.map(candles, & &1.close) == ["101.0", "102.0", "103.0"]
  end

  test "supports fetching multiple symbols in a single run" do
    klines_fun = fn _client, params ->
      case Keyword.fetch!(params, :symbol) do
        "BTCUSDT" -> {:ok, [raw_kline(10_000, 10_059)]}
        "ETHUSDT" -> {:ok, [raw_kline(20_000, 20_059)]}
      end
    end

    assert {:ok, result} =
             Candles.fetch(
               symbols: ["BTCUSDT", "ETHUSDT"],
               interval: "15m",
               limit: 1000,
               klines_fun: klines_fun
             )

    assert Enum.map(result["BTCUSDT"], & &1.open_time) == [10_000]
    assert Enum.map(result["ETHUSDT"], & &1.open_time) == [20_000]
  end

  test "fetches multiple symbols concurrently" do
    parent = self()

    klines_fun = fn _client, params ->
      symbol = Keyword.fetch!(params, :symbol)
      send(parent, {:fetch_started, symbol, self()})

      receive do
        {:release_fetch, ^symbol} ->
          {:ok, [raw_kline(if(symbol == "BTCUSDT", do: 10_000, else: 20_000), 10_059)]}
      after
        1_000 ->
          {:error, :fetch_release_timeout}
      end
    end

    fetch_task =
      Task.async(fn ->
        Candles.fetch(
          symbols: ["BTCUSDT", "ETHUSDT"],
          interval: "1m",
          limit: 2,
          klines_fun: klines_fun
        )
      end)

    fetch_starts = collect_fetch_starts(2, %{})
    assert Map.keys(fetch_starts) |> MapSet.new() == MapSet.new(["BTCUSDT", "ETHUSDT"])

    Enum.each(fetch_starts, fn {symbol, pid} ->
      send(pid, {:release_fetch, symbol})
    end)

    assert {:ok, result} = Task.await(fetch_task, 5_000)
    assert Enum.map(result["BTCUSDT"], & &1.open_time) == [10_000]
    assert Enum.map(result["ETHUSDT"], & &1.open_time) == [20_000]
  end

  test "fails fast when pagination cursor does not advance" do
    stale_batch = [
      raw_kline(1_000, 1_059),
      raw_kline(2_000, 2_059)
    ]

    klines_fun = fn _client, _params ->
      {:ok, stale_batch}
    end

    assert {:error, %{symbol: "BTCUSDT", reason: {:pagination_stalled, 2_001, 2_001}}} =
             Candles.fetch(
               symbols: ["BTCUSDT"],
               interval: "1m",
               limit: 2,
               klines_fun: klines_fun
             )
  end

  test "validates chronological time range" do
    assert {:error, :invalid_time_range} =
             Candles.fetch(
               symbols: ["BTCUSDT"],
               interval: "1m",
               start_time: 2_000,
               end_time: 1_000
             )
  end

  test "filters out candles outside requested time range" do
    parent = self()

    klines_fun = fn _client, params ->
      send(parent, {:request, params})

      {:ok,
       [
         raw_kline(1_000, 1_059),
         raw_kline(2_000, 2_059),
         raw_kline(3_000, 3_059),
         raw_kline(4_000, 4_059)
       ]}
    end

    assert {:ok, %{"BTCUSDT" => candles}} =
             Candles.fetch(
               symbols: ["BTCUSDT"],
               interval: "1m",
               start_time: 2_000,
               end_time: 3_000,
               limit: 10,
               klines_fun: klines_fun
             )

    assert Enum.map(candles, & &1.open_time) == [2_000, 3_000]

    assert_receive {:request,
                    [
                      symbol: "BTCUSDT",
                      interval: "1m",
                      limit: 10,
                      startTime: 2_000,
                      endTime: 3_000
                    ]}
  end

  defp raw_kline(open_time, close_time, close \\ "101.0") do
    [
      open_time,
      "100.0",
      "102.0",
      "99.0",
      close,
      "10.5",
      close_time,
      "1050.0",
      25,
      "5.2",
      "520.0",
      "0"
    ]
  end

  defp collect_fetch_starts(0, acc), do: acc

  defp collect_fetch_starts(remaining, acc) do
    assert_receive {:fetch_started, symbol, pid}
    collect_fetch_starts(remaining - 1, Map.put(acc, symbol, pid))
  end
end
