# ADR Polling Trading Robot With Finite Iterations

Date: 2026-02-07
Status: accepted
ID: 0006

## Context
Project requirements call for a trading robot that can run one strategy across one or more Binance Spot symbols while preserving safety and testability. The project already had deterministic simulation, but no dedicated runtime trading loop for paper/live operation.

## Decision
Add a polling trading runner and CLI:
- `CriptoTrader.Trading.Robot.run/1` executes a finite number of iterations, fetches candles per symbol, evaluates one strategy function, and routes orders through an injected executor (default `CriptoTrader.OrderManager`).
- `mix binance.trade` provides a user-facing command with Spot-only symbols/interval inputs.
- Trading mode defaults to `paper`; live mode requires explicit `--mode live`.
- Runner behavior is deterministic in tests via injectable `candles_fetch_fun`, `order_executor`, and `sleep_fun`.

## Consequences
The project now has a concrete trading robot path aligned with existing separation of concerns:
- Market ingestion remains in market-data modules.
- Strategy logic stays pure and injectable.
- Risk checks remain enforced by order manager in both paper and live modes.

Finite-iteration defaults improve safety and deterministic testing, but long-running daemon behavior (continuous supervision/restart semantics) remains future work.
