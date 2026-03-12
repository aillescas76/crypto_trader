# CLAUDE.md — Cripto Trader

Quick-reference for Claude Code. Always loaded — keep this lean.

---

## Project

Elixir/OTP Binance spot trading bot with a Phoenix LiveView experiment dashboard and an autonomous strategy backtesting loop driven by Claude Code.

---

## Key Directories

```
lib/cripto_trader/
  experiments/          ← experiment engine (config, state, runner, metrics, evaluator, engine)
  strategy/             ← production strategies
  strategy/experiment/  ← experimental strategies (YYYYMMDD_<concept>.ex)
  simulation/runner.ex  ← core backtest engine
  market_data/archive_candles.ex ← Binance archive candle fetcher (cached)

lib/cripto_trader_web/live/experiments_live/  ← Feed, Findings, Feedback LiveViews

priv/experiments/       ← JSON state (git-tracked, no DB)

.claude/skills/         ← skill protocols (/loop, /analyse-traces)
.claude/context/        ← per-skill quick-reference (APIs, constants, examples)
```

---

## File Write Limits (Enforced by Hook)

A `PreToolUse` hook **automatically denies** any write, edit, or shell write operation outside this project directory. There are no exceptions for system paths or home directory files.

**Allowed destinations:**
- `$PROJECT_DIR/**` — anywhere inside this repo
- `/tmp/**` — temp scripts and analysis files
- `/dev/null`, `/dev/stderr` — standard sinks
- `~/.claude/projects/*/memory/**` — Claude project memory

**Blocked:** `~/.bashrc`, `/etc/*`, `~/any_other_path`, etc.

Shell commands are scanned too: `>` redirections, `tee`, `cp`/`mv` destinations, `rm`, `sed -i` to blocked paths are all denied. Use `/tmp/` for intermediate files.

---

## Safety Rules (Never Break)

- Trading mode defaults to **paper** — never switch to live without explicit user instruction
- Never hardcode API keys — use environment variables
- Assets: USDC or EUR pairs only; spot trading only

---

## Running Tests

```bash
mix test              # all tests
mix test test/strategy/
mix test --failed
```

Web/PubSub/Engine children are gated off in `MIX_ENV=test`.

---

## Skills

| Skill | Purpose | Context file |
|-------|---------|--------------|
| `/loop` | Autonomous strategy experiment iteration | `.claude/context/experiment-loop.md` |
| `/analyse-traces` | Review experiment session traces for process improvements | `.claude/skills/analyse-traces/SKILL.md` |
