defmodule CriptoTrader.CandleDB.Repo.Migrations.CreateCandles do
  use Ecto.Migration

  def change do
    create table(:candles) do
      add :symbol, :string, null: false
      add :interval, :string, null: false
      add :open_time, :integer, null: false
      add :close_time, :integer
      add :open, :decimal, null: false
      add :high, :decimal, null: false
      add :low, :decimal, null: false
      add :close, :decimal, null: false
      add :volume, :decimal
      add :quote_volume, :decimal
      add :trade_count, :integer
      add :taker_buy_volume, :decimal
      add :taker_buy_quote, :decimal

      timestamps(type: :utc_datetime)
    end

    create unique_index(:candles, [:symbol, :interval, :open_time])
  end
end
