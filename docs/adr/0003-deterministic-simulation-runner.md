# ADR Deterministic Multi-Symbol Simulation Runner

Date: 2026-02-07
Status: accepted
ID: 0003

## Context
The requirements define a simulation mode that replays historical candles with accelerated time, supports one strategy across multiple symbols, and reports trading performance. The project also requires deterministic behavior and reuse of existing risk/order controls.

## Decision
Add `CriptoTrader.Simulation.Runner` as the core simulation execution module:
- Input candles are provided per symbol and merged into one deterministic timeline (sorted by `open_time`, then symbol input order).
- A single pure `strategy_fun` is invoked for every replayed event, regardless of symbol.
- Orders are sent through an injectable executor, defaulting to `CriptoTrader.OrderManager.place_order/2`, so risk checks stay in the order path.
- Replay emits accelerated simulated timestamps via a `speed` factor without wall-clock sleeping.
- Outputs include `trade_log`, performance `summary` (`pnl`, `win_rate`, `max_drawdown_pct`), and optional `equity_curve`.

## Consequences
Simulation behavior is deterministic and test-friendly, while staying aligned with the existing paper/live and risk architecture. The module remains extensible for future strategy adapters or CLI orchestration without changing the core replay model.
