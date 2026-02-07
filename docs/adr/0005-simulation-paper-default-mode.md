# ADR Simulation Uses Paper Mode by Default

Date: 2026-02-07
Status: accepted
ID: 0005

## Context
Simulation should be safe by default and must not place live Binance orders unless a user explicitly opts in. Previously, simulation order execution depended on global `trading_mode`, which could route simulation orders to live endpoints if the environment was set to live.

## Decision
Use explicit per-run trading mode for simulation:
- `CriptoTrader.Simulation.Runner` now injects `trading_mode: :paper` into order executor options by default.
- `mix binance.simulate` adds `--mode paper|live` (default: `paper`) and passes it to the runner.
- `CriptoTrader.OrderManager.place_order/2` accepts an optional `:trading_mode` override, falling back to global config when omitted.

## Consequences
Simulation runs remain paper-safe by default, independent of deployment-wide mode. Live simulation order routing is still possible, but only with explicit opt-in. Existing non-simulation order flows keep their current behavior unless they pass an override.
