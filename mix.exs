defmodule CriptoTrader.MixProject do
  use Mix.Project

  def project do
    [
      app: :cripto_trader,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {CriptoTrader.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"},
      {:websockex, "~> 0.4"},
      {:ecto_sqlite3, "~> 0.17"},
      {:ecto_sql, "~> 3.12"},
      {:ecto, "~> 3.12"}
    ]
  end
end
