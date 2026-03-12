# CLAUDE.md — Cripto Trader

Quick-reference for Claude Code. Read this before touching any code.

---

## Project in One Sentence

Elixir/OTP Binance spot trading bot with a Phoenix LiveView experiment dashboard and an autonomous strategy backtesting loop.

---

## Key Directories

```
lib/cripto_trader/
  experiments/          ← experiment engine (config, state, runner, metrics, evaluator, engine)
  strategy/             ← production strategies (BuyAndHold, IntradayMomentum, BbRsiReversion, …)
  strategy/experiment/  ← experimental strategies (YYYYMMDD_<concept>.ex, isolated from prod)
  simulation/runner.ex  ← core backtest engine
  market_data/archive_candles.ex ← Binance archive candle fetcher (cached)
  risk/config.ex        ← risk parameter defaults

lib/cripto_trader_web/
  endpoint.ex / router.ex
  live/experiments_live/  ← Feed, Findings, Feedback LiveViews

lib/mix/tasks/
  experiments.add.ex
  experiments.run.ex
  experiments.status.ex
  experiments.findings.add.ex
  binance.simulate.ex   ← manual backtest CLI

priv/experiments/       ← JSON state (git-tracked, no DB)
  experiments.json, hypotheses.json, findings.json, feedback.json

.claude/skills/experiment-loop/SKILL.md  ← /loop skill protocol
```

---

## Core APIs to Know

### Running a backtest

```elixir
CriptoTrader.Simulation.Runner.run(
  symbols: ["BTCUSDC"],
  interval: "15m",
  candles_by_symbol: %{"BTCUSDC" => [...]},
  strategy_fun: &MyStrategy.signal/2,
  strategy_state: MyStrategy.new_state(["BTCUSDC"]),
  initial_balance: 10_000.0,
  include_equity_curve: true,
  include_trade_log: false,
  log_strategy_decisions: false
)
# => {:ok, %{summary: %{pnl, win_rate, max_drawdown_pct, trades, ...}, equity_curve: [...]}}
```

### Fetching candles (cached)

```elixir
CriptoTrader.MarketData.ArchiveCandles.fetch(
  symbols: ["BTCUSDC", "ETHUSDC"],
  interval: "15m",
  start_time: 1_640_995_200_000,   # Unix ms
  end_time:   1_767_225_600_000,
  cache_dir: Path.join(System.user_home!(), ".cripto_trader/archive_cache")
)
# => {:ok, %{"BTCUSDC" => [%{open_time: ..., close: "...", ...}], ...}}
```

### Strategy interface

```elixir
@spec new_state([String.t()], keyword()) :: state()
def new_state(symbols, opts \\ [])

@spec signal(map(), state()) :: {[map()], state()}
def signal(%{symbol: symbol, candle: %{close: close}}, state)
```

Orders use string keys: `%{symbol: "BTCUSDC", side: "BUY", quantity: 0.5}`.

### Experiment state

```elixir
alias CriptoTrader.Experiments.State

State.upsert_experiment(map)        # insert or update by "id"
State.list_experiments()            # {:ok, [map()]}
State.add_hypothesis(map)           # {:ok, id}
State.add_finding(map)              # {:ok, id}
State.add_feedback(map)             # {:ok, id}
State.acknowledge_feedback(id)      # :ok
State.list_findings()               # {:ok, [map()]}
State.list_feedback()               # {:ok, [map()]}
```

---

## Experiment Workflow

### From the terminal

```bash
# Queue
mix experiments.add \
  --strategy CriptoTrader.Strategy.Experiment.20260312MyIdea \
  --hypothesis "If X then Y beats buy-and-hold on both splits" \
  --symbols BTCUSDC,ETHUSDC,SOLUSDC,BNBUSDC,ADAUSDC,XRPUSDC \
  --interval 15m --balance 10000

# Run
mix experiments.run --all-pending

# Check
mix experiments.status

# Record finding
mix experiments.findings.add --title "..." --experiment exp-XXX --tags tag1,tag2
```

### From Claude Code

Use `/loop` — it runs the full 9-step protocol in `.claude/skills/experiment-loop/SKILL.md`.

### Dashboard

```bash
mix phx.server   # → http://localhost:4000
```

---

## Training / Validation Split

| Split      | Date range                   | Unix ms cutoff    |
|------------|------------------------------|-------------------|
| Training   | 2022-01-01 → 2024-12-31      | < 1_735_689_600_000 |
| Validation | 2025-01-01 → present         | ≥ 1_735_689_600_000 |

**Pass criteria** (both splits must pass):
1. Strategy PnL% > BuyAndHold PnL%
2. Strategy Sharpe > BuyAndHold Sharpe **OR** max_drawdown < 40%

---

## Writing a New Experimental Strategy

1. File: `lib/cripto_trader/strategy/experiment/YYYYMMDD_<concept>.ex`
2. Module: `CriptoTrader.Strategy.Experiment.YYYYMMDD<Concept>`
3. Must implement `new_state/2` and `signal/2`
4. Pure logic only — no IO, no HTTP, no process calls
5. Typical size: 50–150 lines

```elixir
defmodule CriptoTrader.Strategy.Experiment.20260312Example do
  @moduledoc "One-line hypothesis"

  def new_state(_symbols, opts \\ []) do
    %{window: Keyword.get(opts, :window, 20), prices: %{}}
  end

  def signal(%{symbol: symbol, candle: %{close: close}}, state) do
    # compute signal, return {orders, new_state}
    {[], state}
  end

  def signal(_event, state), do: {[], state}
end
```

After writing, queue with `mix experiments.add --strategy <FullModule> ...`.

---

## Anti-Cheat Rules

These are non-negotiable for scientific validity:

1. **Fix parameters before running** — never adjust after seeing validation results
2. **No grid search on full dataset** — tune on training split only
3. **Validation is held-out** — treat as unseen until the experiment executes
4. **One hypothesis per experiment** — no cherry-picking variants
5. **Record a finding for every result** — failures teach as much as passes
6. **Overfit flag** — training pass + validation fail = do not reuse that parameterization

---

## Key Constants

```elixir
# Config defaults (CriptoTrader.Experiments.Config)
training_cutoff_ms:   1_735_689_600_000   # 2025-01-01 UTC
default_start_time_ms: 1_640_995_200_000  # 2022-01-01
default_symbols: ["BTCUSDC","ETHUSDC","SOLUSDC","BNBUSDC","ADAUSDC","XRPUSDC"]
default_interval: "15m"
default_initial_balance: 10_000.0
```

```elixir
# Sharpe annualization periods
"15m" → 35_040
"1h"  → 8_760
"1d"  → 365
```

---

## File Write Limits (Enforced by Hook)

A `PreToolUse` hook blocks all file writes, edits, and shell write operations outside the project directory. Violations are denied automatically — no exceptions for production files, system config, or home directory dotfiles.

**Allowed write destinations:**
- `$PROJECT_DIR/**` — anywhere inside this repo
- `/tmp/**` — temp scripts and analysis output
- `/dev/null`, `/dev/stderr` — standard sinks
- `~/.claude/projects/*/memory/**` — Claude project memory files

**Blocked examples:** `~/.bashrc`, `/etc/*`, `~/other_project/*`, any path outside the above.

Shell commands are also scanned: redirections (`>`), `tee`, `cp dest`, `mv dest`, `rm`, and `sed -i` to blocked paths are all denied.

---

## Safety Rules (Never Break)

- Default trading mode is **paper** — never switch to live without explicit user instruction
- Never hardcode API keys — use environment variables
- Risk controls (`max_order_quote`, `max_drawdown_pct`) are always active
- Assets: USDC or EUR pairs only
- Spot trading only — no futures or margin

---

## Running Tests

```bash
mix test                    # all tests (187 baseline)
mix test test/strategy/     # strategy tests only
mix test --failed           # re-run failures
```

Tests run with `MIX_ENV=test` — the web/PubSub/Engine children are gated off in test env.

---

## Graduated Strategies

When an experimental strategy passes, promote it:

```bash
cp lib/cripto_trader/strategy/experiment/YYYYMMDD_concept.ex \
   lib/cripto_trader/strategy/concept.ex
# Update module name, add to binance.simulate strategy map
```
