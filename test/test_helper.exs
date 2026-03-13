ExUnit.start()

{:ok, _} = CriptoTrader.CandleDB.Repo.start_link()
Ecto.Migrator.run(CriptoTrader.CandleDB.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.mode(CriptoTrader.CandleDB.Repo, :manual)
