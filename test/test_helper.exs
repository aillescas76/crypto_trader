ExUnit.start()

Ecto.Migrator.with_repo(CriptoTrader.CandleDB.Repo, &Ecto.Migrator.run(&1, :up, all: true))
Ecto.Adapters.SQL.Sandbox.mode(CriptoTrader.CandleDB.Repo, :manual)
