import Config

config :cripto_trader, :trading_mode, System.get_env("TRADING_MODE") || "paper"

config :cripto_trader, :binance,
  base_url: System.get_env("BINANCE_BASE_URL") || "https://api.binance.com",
  recv_window: System.get_env("BINANCE_RECV_WINDOW")

config :cripto_trader, :risk,
  max_order_quote: System.get_env("MAX_ORDER_QUOTE"),
  max_drawdown_pct: System.get_env("MAX_DRAWDOWN_PCT"),
  circuit_breaker: System.get_env("CIRCUIT_BREAKER")

config :cripto_trader, :improvement,
  storage_dir: System.get_env("IMPROVEMENT_STORAGE_DIR") || "priv/improvement",
  adr_dir: System.get_env("IMPROVEMENT_ADR_DIR") || "docs/adr",
  weekly_budget_seconds: System.get_env("IMPROVEMENT_WEEKLY_BUDGET_SECONDS") || 18_000,
  codex_cmd: System.get_env("CODEX_CMD") || "codex",
  codex_timeout_ms: System.get_env("IMPROVEMENT_CODEX_TIMEOUT_MS") || 3_600_000

config :cripto_trader, CriptoTraderWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4000")],
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "ExperimentLoopDevKeyNotForProd00000000000000000000000000000000000000",
  pubsub_server: CriptoTrader.PubSub,
  live_view: [signing_salt: "xp_loop_salt"],
  render_errors: [formats: [html: CriptoTraderWeb.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason

config :cripto_trader, CriptoTrader.ExperimentLoop.Runner,
  auto_start: false,
  sleep_ms: 300_000,
  improve_every: 5,
  timeout_ms: 5_400_000,
  iterations: 0,
  budget_usd: nil

config :cripto_trader, ecto_repos: [CriptoTrader.CandleDB.Repo]

config :cripto_trader, CriptoTrader.CandleDB.Repo,
  database: Path.expand("../priv/repo/candles.db", __DIR__),
  pool_size: 5

if File.exists?(Path.expand("#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end
