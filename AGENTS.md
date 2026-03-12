## Project Intent
We are building a Binance trading bot in Elixir. Prioritize safety, testability, and clear separation between exchange integration, strategy logic, and risk controls.

## Language & Tooling
- Use Elixir and Mix for all project code and tasks.
- Prefer OTP patterns (GenServer, Supervisor, Task) where appropriate.
- Keep configs in `config/` and secrets in environment variables.

## Scope Boundaries
- Initial focus: Binance spot trading only.
- Do not add futures/margin features unless explicitly requested.
- Avoid multi-exchange abstractions until the core Binance flow is stable.
- Hard rule: use only `USDC` or `EUR` as the trading counterpart asset.

## Safety & Risk Controls
- Default to `paper` trading mode unless the user explicitly requests live trading.
- Ensure risk controls exist for position sizing, max drawdown, and circuit breakers.
- Never hardcode API keys or secrets.

## Architecture Guidance
- Separate modules for:
  - Binance API client (REST/WebSocket)
  - Market data ingestion
  - Strategy engine (signals/indicators)
  - Order management
  - Risk management
  - Persistence (optional)
- Keep strategy logic pure and testable (no direct IO in signal generation).

## Testing
- Add unit tests for indicators, signals, and risk rules.
- Use integration tests for Binance client behavior (mock network).
- Prefer deterministic tests; avoid time-based flakiness.

## Documentation
- Keep `README.md` updated with setup, configuration, and safety guidance.
- Use `docs/binance_api_investigation_2026-02-05.md` as the primary reference for Binance API/SDK notes and Elixir version checks; update it when API docs or versions change.
- Add comments only when logic is non-obvious.

## Assumptions
- Environment variables provide API credentials and runtime options.
- Elixir/Erlang versions should be recent and compatible.

## Experiment Loop

Claude Code runs an autonomous strategy research and backtesting loop using the `/loop` skill.

### Scientific Rigor
- **No data snooping.** Parameters must be fixed before running. Never tune parameters on validation data (2025-01-01+).
- **Training/validation split.** Training: before 2025-01-01. Validation: 2025-01-01 onward. Both must pass.
- **Record every result.** Use `mix experiments.findings.add` for every completed experiment — passes and failures alike. Failures are learning opportunities.
- **One hypothesis per experiment.** Do not run variants and cherry-pick. Form the hypothesis first, then run.

### Code Modification Rights
Claude Code may modify any existing code when an experiment requires it — including strategies, simulation infrastructure, and configuration. Document significant changes.

### Web Interface Constraint
The Phoenix LiveView dashboard at `localhost:4000` is a hard constraint and must always be functional. Do not remove or break it. Content and layout may evolve.

### Experiment State
All experiment state lives in `priv/experiments/` (JSON, git-tracked). No database required.
- `hypotheses.json` — research hypotheses
- `experiments.json` — experiment records with results
- `findings.json` — accumulated learnings
- `feedback.json` — user notes for next loop iteration

### Pass Criteria
An experiment passes if on BOTH training AND validation splits:
- Strategy PnL% > BuyAndHold PnL%
- AND (Strategy Sharpe > BuyAndHold Sharpe OR max_drawdown < 40%)

Graduated strategies (passing experiments) move from `lib/cripto_trader/strategy/experiment/` to `lib/cripto_trader/strategy/`.
