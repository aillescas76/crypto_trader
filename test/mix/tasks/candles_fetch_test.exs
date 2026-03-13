defmodule Mix.Tasks.Candles.FetchTest do
  use ExUnit.Case

  alias CriptoTrader.CandleDB
  alias CriptoTrader.CandleDB.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  @fixture Path.expand("../../fixtures/candles.csv", __DIR__)

  describe "--file mode (CSV import)" do
    test "imports all rows from CSV and writes to DB" do
      Mix.Tasks.Candles.Fetch.run(["--symbol", "BTCUSDC", "--interval", "1h", "--file", @fixture])

      rows = CandleDB.range("BTCUSDC", "1h", 0, :os.system_time(:millisecond))
      assert length(rows) == 3
      assert hd(rows).symbol == "BTCUSDC"
      assert hd(rows).interval == "1h"
      assert hd(rows).open_time == 1_718_409_600_000
    end

    test "sets volume fields correctly from CSV" do
      Mix.Tasks.Candles.Fetch.run(["--symbol", "BTCUSDC", "--interval", "1h", "--file", @fixture])

      [row | _] = CandleDB.range("BTCUSDC", "1h", 0, :os.system_time(:millisecond))
      assert Decimal.equal?(row.volume, Decimal.new("100.5"))
      assert Decimal.equal?(row.quote_volume, Decimal.new("5050000.0"))
      assert row.trade_count == 1200
    end

    test "exits non-zero when file does not exist" do
      assert catch_exit(
               Mix.Tasks.Candles.Fetch.run([
                 "--symbol", "BTCUSDC",
                 "--interval", "1h",
                 "--file", "/nonexistent/path.csv"
               ])
             ) == {:shutdown, 1}
    end
  end
end
