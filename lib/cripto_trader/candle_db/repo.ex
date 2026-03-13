defmodule CriptoTrader.CandleDB.Repo do
  use Ecto.Repo,
    otp_app: :cripto_trader,
    adapter: Ecto.Adapters.SQLite3
end
