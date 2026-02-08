# Cripto Trader (Binance)

An Elixir-based trading bot for Binance, focused on clean architecture, safety-first defaults, and testable strategy logic.

## Goals
- Provide a robust foundation for building and running Binance trading strategies in Elixir.
- Keep exchange integration, strategy logic, and risk controls cleanly separated.
- Make it easy to backtest, paper trade, and then go live with minimal changes.

## Scope (Initial)
- Binance spot trading support.
- Market data ingestion (candles, order book snapshots, trades).
- Strategy engine with pluggable indicators and signals.
- Risk management (position sizing, max drawdown, circuit breakers).
- Paper trading mode and live trading mode.

## Non-Goals (Initial)
- Futures or margin trading.
- Multi-exchange routing.
- HFT/low-latency co-location features.

## Tech Stack
- Language: Elixir
- Runtime: Erlang/OTP
- Build: Mix
- Data: PostgreSQL (optional, for persistence/backtests)

## Project Layout (Planned)
- `lib/`: core application code
- `test/`: automated tests
- `config/`: configuration
- `priv/`: static assets, SQL, sample data

## Configuration
Environment variables will be used for secrets and runtime configuration.

Planned variables:
- `BINANCE_API_KEY`
- `BINANCE_API_SECRET`
- `TRADING_MODE` (`paper` or `live`)
- `BASE_ASSET` (e.g. `USDT`)

## Development
Prerequisites:
- Elixir (latest stable)
- Erlang/OTP (compatible with the chosen Elixir version)

Common commands:
```bash
mix deps.get
mix test
```

## Candle Extraction CLI
Fetch Binance Spot klines for one or more symbols:

```bash
mix binance.fetch_candles --symbol BTCUSDT --interval 15m
```

Use monthly Binance archive files for long ranges:

```bash
mix binance.fetch_candles \
  --source archive \
  --symbol BTCUSDT \
  --interval 15m \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-03-31T23:59:59Z
```

Options:
- `--symbol` (repeatable) or `--symbols BTCUSDT,ETHUSDT`
- `--source rest|archive` (default: `rest`)
- `--format json|csv` (default: `json`)
- `--interval` (required, e.g. `1m`, `15m`, `1h`)
- `--start-time` and `--end-time` (Unix ms or ISO8601)
- `--limit` (`1..1000`, defaults to `1000`, REST only)

Notes:
- `--source archive` uses Binance Spot monthly kline archives and requires both `--start-time` and `--end-time`.
- REST extraction fetches symbols concurrently while preserving deterministic, symbol-keyed output payloads.
- REST extraction clamps returned candles to the requested `--start-time`/`--end-time` bounds.
- REST extraction sorts each API page chronologically before advancing the pagination cursor, preventing out-of-order pages from skipping or duplicating ranges.
- REST pagination aborts with a clear error if the upstream cursor does not advance, preventing infinite loops.
- `--format json` outputs pretty-printed JSON containing source, interval, date range, and candles grouped by symbol.
- `--format csv` outputs one row per candle with source, interval, symbol, and kline fields.

## Simulation Runner
`CriptoTrader.Simulation.Runner` replays historical candles in deterministic order across one or more symbols and routes strategy-generated orders through the order pipeline.

Key points:
- Uses one strategy function across all configured symbols.
- Supports accelerated event time with `speed` (no wall-clock sleeps).
- Streams merged symbol events without materializing a full timeline in memory.
- Fast-paths already sorted candle inputs to avoid unnecessary O(n log n) per-symbol resorting.
- Produces `trade_log`, `summary` (`pnl`, `win_rate`, `max_drawdown_pct`), and optional `equity_curve`.
- Supports `include_trade_log: false` for throughput-sensitive runs that only need summary metrics.
- Keeps strategy decision logging opt-in (`log_strategy_decisions: false` by default) for throughput-friendly replay runs.
- Removes volatile order response fields (IDs/timestamps) from filled trade log entries to keep repeated runs deterministic.
- Keeps paper-safe defaults by using the existing order manager path.

Minimal example:
```elixir
CriptoTrader.Simulation.Runner.run(
  symbols: ["BTCUSDT", "ETHUSDT"],
  interval: "15m",
  candles_by_symbol: %{
    "BTCUSDT" => [%{open_time: 1_000, close: "100.0"}],
    "ETHUSDT" => [%{open_time: 1_000, close: "200.0"}]
  },
  strategy_fun: fn event, state ->
    orders =
      case event.symbol do
        "BTCUSDT" -> [%{side: "BUY", quantity: 0.1}]
        _ -> []
      end

    {orders, state}
  end
)
```

## Simulation CLI
Run a deterministic Binance Spot simulation over a historical date range:

```bash
mix binance.simulate \
  --source archive \
  --symbols BTCUSDT,ETHUSDT \
  --interval 15m \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-03-31T23:59:59Z \
  --speed 100 \
  --strategy alternating \
  --quantity 0.1
```

Options:
- `--symbol` (repeatable) or `--symbols BTCUSDT,ETHUSDT`
- `--source rest|archive` (default: `archive`)
- `--interval` (required)
- `--start-time` and `--end-time` (required; Unix ms or ISO8601)
- `--speed` positive integer replay acceleration (default: `100`)
- `--mode paper|live` execution mode passed to order placement (default: `paper`)
- `--strategy alternating` (default: `alternating`)
- `--quantity` positive order size used by the alternating strategy (default: `0.1`)
- `--initial-balance` positive number (default: `10000`)
- `--include-equity-curve` include per-event equity points in output
- `--log-strategy-decisions` enable per-event strategy decision debug logs (default: `false`)
- `--limit` (`1..1000`, REST source only)

Output:
- JSON payload with run metadata and simulation `result`.
- Payload includes selected `mode` (`paper` by default).
- Payload includes `log_strategy_decisions` (`false` by default for throughput-friendly runs).
- `result.summary` includes `pnl`, `win_rate`, `max_drawdown_pct`, `trades`, `rejected_orders`, `closed_trades`, and `events_processed`.
- `result.trade_log` and optional `result.equity_curve`.

## Trading Robot CLI
Run a polling Binance Spot trading loop that uses the same strategy and order pipeline as simulation:

```bash
mix binance.trade \
  --symbols BTCUSDT,ETHUSDT \
  --interval 1m \
  --iterations 5 \
  --strategy alternating \
  --quantity 0.1
```

Options:
- `--symbol` (repeatable) or `--symbols BTCUSDT,ETHUSDT`
- `--interval` (required)
- `--mode paper|live` execution mode (default: `paper`)
- `--strategy alternating` (default: `alternating`)
- `--quantity` positive order size for the alternating strategy (default: `0.1`)
- `--iterations` positive loop count (default: `1`)
- `--poll-ms` non-negative sleep between iterations (default: `0`)
- `--limit` candles fetched per symbol per iteration (default: `1`)
- `--start-time` and `--end-time` optional Unix ms or ISO8601 bounds

Behavior:
- Fetches candles for all configured symbols concurrently each iteration.
- Evaluates one pure strategy function across all symbols.
- Routes orders through `CriptoTrader.OrderManager` (paper-safe by default).
- Injects per-order risk context (`order_quote`, `drawdown_pct`) so max drawdown checks are enforced in trading runs.
- Prints JSON output with run configuration, summary counts/metrics, and trade log.

## Simulation Benchmark CLI
Run a deterministic throughput benchmark aligned to the 3-month / 15m acceptance criterion:

```bash
mix binance.simulation_benchmark
```

Options:
- `--symbols BTCUSDT,ETHUSDT,SOLUSDT` (default: those three symbols)
- `--days` positive integer lookback in days (default: `90`)
- `--speed` positive integer replay speed factor (default: `100`)
- `--max-seconds` runtime threshold in seconds (default: `300.0`)
- `--initial-balance` positive number (default: `10000`)
- `--quantity` positive number per generated order (default: `1.0`)
- `--start-time` Unix ms or ISO8601 benchmark start timestamp (default: fixed Unix ms for deterministic generation)
- `--include-equity-curve` include equity points in benchmark result output

Behavior:
- Uses deterministic synthetic 15m candles for each symbol.
- Executes through `CriptoTrader.Simulation.Runner`.
- Uses one shared `CriptoTrader.Strategy.Alternating` strategy state across all benchmark symbols.
- Disables per-event strategy decision logs and trade-log accumulation in the benchmark run to keep throughput measurements focused on replay/execution cost.
- Prints JSON with elapsed seconds, threshold, pass/fail flag, expected event count, and simulation result summary.
- Fails if processed event count does not match expected workload.
- Exits with `Mix.Error` if elapsed runtime exceeds `--max-seconds`.

## Observability
Structured log events are emitted for key execution decisions:
- `simulation_event` with `event=strategy_decision` from `CriptoTrader.Simulation.Runner` when strategy decision logging is enabled.
- `trading_event` with `event=strategy_decision` from `CriptoTrader.Trading.Robot` for each processed live/paper polling candle.
- `order_event` with `event=order_submitted` from `CriptoTrader.OrderManager` when an order is accepted and submitted.
- `order_event` with `event=order_rejected` from `CriptoTrader.OrderManager` for risk rejections, invalid mode, and downstream execution failures.

Each event includes relevant fields such as symbol, side, mode, quantity, price, and rejection reason when present.

## Improvement Loop
The project includes a file-backed improvement loop to close gaps against `docs/requirements.md`.
Detailed lifecycle documentation: `docs/improvement_loop_step_by_step.md`.

Storage:
- `priv/improvement/tasks.json` (future tasks)
- `priv/improvement/knowledge_base.json` (findings/evidence)
- `docs/adr/` (architecture decision records)

Commands:
```bash
mix improvement.tasks.seed_requirements
mix improvement.task.new --title "Investigate simulator design" --type note
mix improvement.task.list
mix improvement.task.update --id 1 --status in_progress
mix improvement.loop.run --max 5
mix improvement.budget.status
mix improvement.findings.list --limit 20
mix improvement.decision.new --title "Choose simulation event model"
```

`mix improvement.tasks.seed_requirements` is idempotent for task creation and re-queues existing failed/blocked `requirement_gap` tasks back to `pending` so requirement checks can be retried after code changes.

### Autonomous Codex Loop
Run unattended iterations where the loop invokes Codex to implement the next requirement gap, then updates tasks/findings/reports:

```bash
mix improvement.loop.autorun \
  --iterations 100 \
  --sleep-ms 300 \
  --max-tasks 10 \
  --no-stop-when-clean \
  --codex-enabled
```

`mix improvement.loop.autorun` now re-seeds requirements by default each iteration, so failed/blocked `requirement_gap` tasks are retried after code changes. Use `--no-seed-requirements` to disable this behavior.

Helper script:
```bash
scripts/run_improvement_loop.sh
```

Runtime artifacts:
- `priv/improvement/progress_report.json` (machine-readable progress and coverage)
- `priv/improvement/agent_context.json` (handoff context for the next Codex run)
- `priv/improvement/execution_budget.json` (5h/week budget tracking and reset window)
- `priv/improvement/loop_state.json` (last run state / stop reason)

Requirement checks:
- `ac-1` runs an executable candle-extraction smoke check (task entrypoint + deterministic two-page paginated kline fetch path).
- `ac-2` runs a deterministic 90-day / 15m multi-symbol throughput benchmark check against `Simulation.Runner`.
- `ac-3` runs a deterministic multi-symbol simulation smoke check to confirm one strategy function is applied across symbols.

Budget controls:
- Default execution budget is 5h/week (`18_000` seconds).
- Set `IMPROVEMENT_WEEKLY_BUDGET_SECONDS` to override.
- When the weekly budget is exhausted, the autorun loop pauses with `paused_budget_exhausted` and resumes after reset.
- Override Codex invocation with:
  - `CODEX_CMD` (default: `codex`)
  - `CODEX_ARGS` (optional shell-style args; default runs `codex exec --full-auto ...`)

## Safety Notes
This project will include guardrails to reduce risk, but trading is inherently risky.
Always test in paper mode before using real funds.

## License
TBD
