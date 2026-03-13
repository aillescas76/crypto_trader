defmodule CriptoTrader.CandleDBTest do
  use ExUnit.Case

  alias CriptoTrader.CandleDB
  alias CriptoTrader.CandleDB.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  @base %{
    symbol: "BTCUSDC",
    interval: "1h",
    open: "50000.0",
    high: "51000.0",
    low: "49500.0",
    close: "50500.0"
  }

  # Returns a candle map with open_time set to N days ago (in ms).
  defp candle(days_ago, overrides \\ %{}) do
    open_time = System.os_time(:millisecond) - days_ago * 86_400_000
    Map.merge(@base, Map.put(overrides, :open_time, open_time))
  end

  defp ts(days_ago), do: System.os_time(:millisecond) - days_ago * 86_400_000

  describe "insert_candles/1" do
    test "inserts candles and returns count" do
      assert {:ok, 2} = CandleDB.insert_candles([candle(5), candle(4)])
    end

    test "returns {:ok, 0} for empty list" do
      assert {:ok, 0} = CandleDB.insert_candles([])
    end

    test "deduplicates on (symbol, interval, open_time) — second insert does not error" do
      c = candle(5)
      assert {:ok, _} = CandleDB.insert_candles([c])
      assert {:ok, _} = CandleDB.insert_candles([c])
      # Only one row exists despite two inserts
      assert length(CandleDB.range("BTCUSDC", "1h", ts(6), ts(4))) == 1
    end

    test "upsert updates non-key fields but preserves inserted_at" do
      c = candle(5, %{close: "50000.0"})
      CandleDB.insert_candles([c])
      [row] = CandleDB.range("BTCUSDC", "1h", ts(6), ts(4))
      original_inserted_at = row.inserted_at

      CandleDB.insert_candles([candle(5, %{close: "99999.0"})])
      [row2] = CandleDB.range("BTCUSDC", "1h", ts(6), ts(4))
      assert Decimal.equal?(row2.close, Decimal.new("99999.0"))
      assert row2.inserted_at == original_inserted_at
    end

    test "normalises Binance archive field names" do
      c = Map.merge(@base, %{
        open_time: ts(5),
        quote_asset_volume: "1234.5",
        number_of_trades: 42,
        taker_buy_base_volume: "500.0",
        taker_buy_quote_volume: "25000000.0"
      })
      CandleDB.insert_candles([c])
      [row] = CandleDB.range("BTCUSDC", "1h", ts(6), ts(4))
      assert Decimal.equal?(row.quote_volume, Decimal.new("1234.5"))
      assert row.trade_count == 42
      assert Decimal.equal?(row.taker_buy_volume, Decimal.new("500.0"))
    end

    test "skips invalid candles without crashing" do
      bad = %{symbol: "BTCUSDC"}
      assert {:ok, 1} = CandleDB.insert_candles([bad, candle(5)])
    end
  end

  describe "recent/3" do
    test "returns candles within last N days, ordered by open_time ASC" do
      Enum.each([15, 8, 3, 1], fn d -> CandleDB.insert_candles([candle(d)]) end)
      rows = CandleDB.recent("BTCUSDC", "1h", days: 10)
      assert length(rows) == 3
      times = Enum.map(rows, & &1.open_time)
      assert times == Enum.sort(times)
    end

    test "returns empty list when no data in range" do
      assert [] = CandleDB.recent("BTCUSDC", "1h", days: 5)
    end

    test "filters by symbol and interval" do
      CandleDB.insert_candles([candle(3)])
      CandleDB.insert_candles([Map.merge(@base, %{symbol: "ETHUSDC", open_time: ts(3)})])
      CandleDB.insert_candles([Map.merge(@base, %{interval: "15m", open_time: ts(3)})])

      rows = CandleDB.recent("BTCUSDC", "1h", days: 10)
      assert length(rows) == 1
      assert hd(rows).symbol == "BTCUSDC"
      assert hd(rows).interval == "1h"
    end
  end

  describe "range/4" do
    test "returns candles within [from_ms, to_ms] inclusive, ordered ASC" do
      Enum.each([5, 3, 1], fn d -> CandleDB.insert_candles([candle(d)]) end)
      rows = CandleDB.range("BTCUSDC", "1h", ts(4), ts(2))
      assert length(rows) == 1
      assert_in_delta hd(rows).open_time, ts(3), 5_000
    end

    test "returns empty list when no candles in range" do
      assert [] = CandleDB.range("BTCUSDC", "1h", ts(2), ts(1))
    end
  end
end
