# Strategy Experiments

This directory contains experimental strategies written by Claude Code during the autonomous experiment loop.

## Naming Convention

Files are named: `YYYYMMDD_<concept>.ex`

For example: `20260312_volatility_breakout.ex`

Module names follow: `CriptoTrader.Strategy.Experiment.YYYYMMDD<Concept>`

For example: `CriptoTrader.Strategy.Experiment.20260312VolatilityBreakout`

## Lifecycle

1. **Experimental** — strategy lives here while being tested
2. **Graduated** — if an experiment passes, the strategy may be promoted to `lib/cripto_trader/strategy/` and become a production candidate
3. **Archived** — failed strategies stay here for reference (do not delete — they record what was tried)

## Interface

Every strategy must implement:

```elixir
@spec new_state([String.t()], keyword()) :: state()
def new_state(symbols, opts \\ [])

@spec signal(map(), state()) :: {[map()], state()}
def signal(event, state)
```

The `signal/2` function must be pure — no IO, no HTTP, no side effects.
