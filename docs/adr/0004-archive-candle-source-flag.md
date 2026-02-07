# ADR Archive Candle Source Flag

Date: 2026-02-07
Status: accepted
ID: 0004

## Context
`docs/requirements.md` requires candle extraction to support two data-source paths:
- REST as the primary source for recent history.
- Bulk historical archive support for long ranges as a separate command or flag.

The project already had a REST-based extraction command. Long-range archive extraction was still missing.

## Decision
Add archive ingestion as a source flag on the existing extraction command:
- Extend `mix binance.fetch_candles` with `--source rest|archive` (default: `rest`).
- Implement `CriptoTrader.MarketData.ArchiveCandles` to download Binance Spot monthly archive zip files, parse CSV klines, and filter by requested `start_time`/`end_time`.
- Require explicit `--start-time` and `--end-time` for archive mode to keep runs bounded and deterministic.

## Consequences
The extraction flow now supports both short-range REST pulls and long-range archive pulls without introducing a second CLI surface. Data ingestion responsibilities stay isolated in `CriptoTrader.MarketData` modules, and strategy/risk/order modules remain untouched.
