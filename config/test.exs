import Config

config :cripto_trader, CriptoTrader.CandleDB.Repo,
  database: Path.expand("../priv/repo/test_candles.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox
