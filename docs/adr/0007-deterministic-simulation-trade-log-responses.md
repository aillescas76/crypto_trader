# ADR Deterministic Simulation Trade Log Responses

Date: 2026-02-07
Status: accepted
ID: 0007

## Context
Simulation runs are expected to be deterministic. The default simulation order path uses `CriptoTrader.OrderManager`, which in paper mode returns response metadata such as generated order IDs and wall-clock timestamps. Writing these volatile fields into `Simulation.Runner` trade logs makes repeated runs produce different payloads even with identical candle inputs and strategy behavior.

## Decision
Sanitize filled-order responses before writing them to the simulation trade log:
- Remove volatile ID/time fields from executor responses (for both atom and string keys).
- Keep stable response fields (for example `status`, `symbol`, `side`) so logs still carry useful execution context.
- Apply this in `CriptoTrader.Simulation.Runner` only, preserving order manager behavior for other flows.

## Consequences
Simulation outputs become stable across repeated runs with the same inputs, improving reproducibility and deterministic testing. Consumers that relied on raw exchange/paper IDs or timestamps inside simulation trade logs must source those values elsewhere.
