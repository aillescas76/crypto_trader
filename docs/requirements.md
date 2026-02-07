# Requirements: Binance Trading Bot

Date: 2026-02-06

## Goals
- Provide a command to extract Binance data for analysis and simulations.
- Provide a simulation mode that replays historical data as if live, with accelerated time.
- Provide a trading robot that can operate on one or more cryptocurrencies and can get a profit.

## Scope
- Binance Spot only.
- Paper trading by default. Live trading only when explicitly enabled.
- Clear separation between: data ingestion, strategy, order management, and risk controls.

## Functional Requirements

### Data Extraction
- Provide a CLI command to fetch market data from Binance for analysis.
- Support at minimum:
  - Candles (klines) with configurable interval and symbol(s).
  - Date range selection with pagination (start/end time).
- Output formats:
  - JSON (default).
  - CSV (optional, second phase).
- Data source options:
  - REST API (primary for recent history).
  - Bulk historical archive (for long ranges) as a separate command or flag.

### Simulation / Backtesting
- Provide a simulation runner that:
  - Replays historical market data in order.
  - Emits events at accelerated time (configurable speed, e.g., 10x, 100x).
  - Uses the same strategy and order pipeline as live mode.
- Simulation inputs:
  - Symbol list (one or more).
  - Interval (e.g., 1m, 15m, 1h).
  - Date range (start/end).
  - Speed factor.
- Outputs:
  - Trade log.
  - Performance summary (PnL, win rate, drawdown).
  - Optional equity curve series.

### Trading Robot
- Must handle one or multiple symbols concurrently.
- Strategy logic is pure (no IO) and testable.
- Order manager applies risk checks before submitting orders.
- Modes:
  - Paper (default).
  - Live (explicit flag).

## Non-Functional Requirements
- Safety: risk controls for max order size, max drawdown, circuit breaker.
- Reliability: deterministic simulation runs.
- Observability: structured logging of decisions, orders, and risk rejections.
- Config: use environment variables for secrets and runtime options.

## Assumptions
- API credentials are provided via environment variables.
- Binance Spot API and public data archives are available.

## Out of Scope (for now)
- Futures/margin trading.
- Multi-exchange routing.
- UI or web dashboard.

## Future Improvements
- Add a `signals-only` advisory mode for the trading robot.
- In advisory mode, the system must evaluate strategy signals and report buy/sell opportunities without submitting orders.
- Advisory output should include at least: symbol, side (`BUY`/`SELL`), timestamp, reference price, and strategy rationale/metadata.
- Advisory mode should work for one or multiple symbols and preserve the same risk context visibility used by execution modes.

## Acceptance Criteria
- A CLI command fetches candles for at least one symbol and interval.
- A simulation run can process 3 months of 15m candles in under 5 minutes on a dev machine.
- A single strategy can run against multiple symbols in simulation.
- All risk checks are enforced in both paper and live modes.
