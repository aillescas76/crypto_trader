# Candle History Database — Design Spec

**Date:** 2026-03-13
**Status:** Approved

---

## Overview

A persistent candle history database backed by SQLite (via Ecto + `ecto_sqlite3`). Stores OHLCV data for all intervals used by the system (15m, 1h, 4h, 1d). Populated manually via a Mix task (Binance archive fetch or local CSV import) and automatically by the live Binance WebSocket feed. Strategies query it at startup to pre-warm their historical state instead of accumulating data candle-by-candle at runtime.

---

## Data Model

Single table: `candles`

| Column             | Type         | Notes                                      |
|--------------------|--------------|--------------------------------------------|
| `id`               | integer      | Autoincrement primary key                  |
| `symbol`           | string       | e.g. `"BTCUSDC"`                           |
| `interval`         | string       | `"15m"`, `"1h"`, `"4h"`, `"1d"`           |
| `open_time`        | integer      | Unix milliseconds (Binance native)         |
| `close_time`       | integer      | Unix milliseconds                          |
| `open`             | decimal      | Coerced from Binance string                |
| `high`             | decimal      | Coerced from Binance string                |
| `low`              | decimal      | Coerced from Binance string                |
| `close`            | decimal      | Coerced from Binance string                |
| `volume`           | decimal      | Base asset volume (e.g. BTC)               |
| `quote_volume`     | decimal      | Quote asset volume (e.g. USDC)             |
| `trade_count`      | integer      | Number of trades in the candle             |
| `taker_buy_volume` | decimal      | Base asset bought by takers                |
| `taker_buy_quote`  | decimal      | Quote asset bought by takers               |
| `inserted_at`      | utc_datetime | Ecto managed                               |
| `updated_at`       | utc_datetime | Ecto managed                               |

**Constraints:**
- Unique index on `(symbol, interval, open_time)` — primary deduplication key
- Index on `(symbol, interval, open_time)` for range queries

**Database file:** `priv/repo/candles.db`

---

## Components

### `CriptoTrader.CandleDB.Repo`
Standard Ecto Repo targeting SQLite. Added to the OTP supervision tree in `Application`. Database file at `priv/repo/candles.db`.

### `CriptoTrader.CandleDB.Candle`
Ecto schema mapping to the `candles` table. Changeset handles coercion of Binance string fields (open, high, low, close, volume variants) to `:decimal`.

### `CriptoTrader.CandleDB`
Public context module. All external code interacts with this module only — never `Repo` or `Candle` directly.

**Public API:**

```elixir
# Bulk upsert. Idempotent — duplicate (symbol, interval, open_time) tuples
# overwrite existing rows silently (last write wins).
@spec insert_candles([map()]) :: {:ok, integer()} | {:error, term()}
def insert_candles(candles)

# Returns candles for the last `days` days, ordered by open_time ascending.
# Used by strategies at startup to pre-warm historical state.
@spec recent(String.t(), String.t(), days: integer()) :: [Candle.t()]
def recent(symbol, interval, days: n)

# Returns candles in [from_ms, to_ms] range, ordered by open_time ascending.
# Used by backtests to fetch data from the DB instead of re-fetching from Binance.
@spec range(String.t(), String.t(), integer(), integer()) :: [Candle.t()]
def range(symbol, interval, from_ms, to_ms)
```

### `Mix.Tasks.Candles.Fetch`
Manual population task. Two modes:

```bash
# Fetch from Binance archive for a symbol/interval/date range
mix candles.fetch --symbol BTCUSDC --interval 1h --from 2024-01-01 --to 2024-12-31

# Import from a local CSV file (Binance Vision format)
mix candles.fetch --symbol BTCUSDC --interval 1h --file /path/to/data.csv
```

Wraps the existing `ArchiveCandles` fetcher for archive mode. Prints progress (candles fetched / inserted). Exits non-zero on failure.

### `LiveSim.Manager` integration
After processing each closed 15m candle, writes it to the DB asynchronously:

```elixir
Task.start(fn -> CandleDB.insert_candles([candle]) end)
```

The live loop is never blocked by DB writes. DB unavailability does not affect live simulation.

---

## Data Flow

### Manual population (archive or CSV)
```
mix candles.fetch
  → ArchiveCandles.fetch() | CSV.parse()
  → CandleDB.insert_candles(candles)    # bulk upsert, idempotent
```

### Live feed
```
BinanceStream → LiveSim.Manager (:candle cast)
  → existing in-memory logic            # unchanged
  → Task.start → CandleDB.insert_candles([candle])  # fire-and-forget
```

### Strategy warmup
```
IntradayMomentum.new_state(symbols, opts)
  → CandleDB.recent("BTCUSDC", "1h", days: 14)
  → pre-seeds day_history + best_hours
  → strategy trades from candle 1 with no blind warmup period
```

### Backtests (optional future path)
`mix binance.simulate` and similar callers can query `CandleDB.range/4` as the data source instead of re-fetching from Binance archives. `Simulation.Runner` is unchanged — it still receives `candles_by_symbol` maps.

---

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| Duplicate candle insert | Silent overwrite via `on_conflict: :replace_all` |
| DB unavailable during live feed | `Task.start` isolates failure; live loop unaffected |
| DB unavailable during backtest | Returns `{:error, reason}`; caller decides |
| `mix candles.fetch` network failure | Prints error, exits non-zero |
| Missing DB file on startup | Ecto creates it; `mix ecto.migrate` creates schema |

---

## Testing

| Area | Approach |
|------|----------|
| `CandleDB` context | Unit tests against in-memory SQLite (`:memory:` in `config/test.exs`) |
| `Candle` changeset | Unit tests: decimal coercion from strings, invalid data rejection |
| `mix candles.fetch` | Fixture CSV file; no real Binance calls |
| `LiveSim.Manager` | Existing tests unaffected; fire-and-forget write not exercised in test env |

---

## Dependencies to Add

```elixir
# mix.exs
{:ecto_sqlite3, "~> 0.17"},
{:ecto, "~> 3.12"},
```

---

## Files to Create / Modify

| Action | Path |
|--------|------|
| Create | `lib/cripto_trader/candle_db/repo.ex` |
| Create | `lib/cripto_trader/candle_db/candle.ex` |
| Create | `lib/cripto_trader/candle_db.ex` |
| Create | `lib/mix/tasks/candles.fetch.ex` |
| Create | `priv/repo/migrations/YYYYMMDDHHMMSS_create_candles.exs` |
| Modify | `lib/cripto_trader/application.ex` — add Repo to supervision tree |
| Modify | `lib/cripto_trader/live_sim/manager.ex` — add fire-and-forget DB write |
| Modify | `mix.exs` — add deps + Ecto config |
| Modify | `config/config.exs` — Repo config |
| Modify | `config/test.exs` — in-memory SQLite for tests |
