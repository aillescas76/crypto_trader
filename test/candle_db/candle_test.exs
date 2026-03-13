defmodule CriptoTrader.CandleDB.CandleTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.CandleDB.Candle

  @valid %{
    symbol: "BTCUSDC",
    interval: "1h",
    open_time: 1_718_409_600_000,
    open: "50000.0",
    high: "51000.0",
    low: "49500.0",
    close: "50500.0"
  }

  test "valid attrs produce a valid changeset" do
    assert Candle.changeset(@valid).valid?
  end

  test "missing required field is invalid" do
    cs = Candle.changeset(Map.delete(@valid, :symbol))
    refute cs.valid?
    assert :symbol in Keyword.keys(cs.errors)
  end

  test "open/high/low/close are coerced from strings to Decimal" do
    cs = Candle.changeset(@valid)
    assert cs.changes.open == Decimal.new("50000.0")
    assert cs.changes.close == Decimal.new("50500.0")
  end

  test "normalises quote_asset_volume -> quote_volume" do
    cs = Candle.changeset(Map.put(@valid, :quote_asset_volume, "12345.0"))
    assert cs.changes.quote_volume == Decimal.new("12345.0")
    refute Map.has_key?(cs.changes, :quote_asset_volume)
  end

  test "normalises number_of_trades -> trade_count" do
    cs = Candle.changeset(Map.put(@valid, :number_of_trades, 999))
    assert cs.changes.trade_count == 999
  end

  test "normalises taker_buy_base_volume -> taker_buy_volume" do
    cs = Candle.changeset(Map.put(@valid, :taker_buy_base_volume, "100.0"))
    assert cs.changes.taker_buy_volume == Decimal.new("100.0")
  end

  test "normalises taker_buy_quote_volume -> taker_buy_quote" do
    cs = Candle.changeset(Map.put(@valid, :taker_buy_quote_volume, "5000000.0"))
    assert cs.changes.taker_buy_quote == Decimal.new("5000000.0")
  end

  test "accepts string keys from CSV parsing" do
    attrs = %{
      "symbol" => "ETHUSDC",
      "interval" => "15m",
      "open_time" => 1_718_409_600_000,
      "open" => "3000.0",
      "high" => "3100.0",
      "low" => "2950.0",
      "close" => "3050.0"
    }
    assert Candle.changeset(attrs).valid?
  end

  test "optional fields can be absent" do
    cs = Candle.changeset(@valid)
    assert cs.valid?
    refute Map.has_key?(cs.changes, :volume)
    refute Map.has_key?(cs.changes, :trade_count)
  end
end
