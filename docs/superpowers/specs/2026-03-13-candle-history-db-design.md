# Candle History Database — Design Spec

**Date:** 2026-03-13
**Status:** Approved

---

## Overview

A persistent candle history database backed by SQLite (via Ecto + `ecto_sqlite3`). Stores OHLCV data for all intervals used by the system (15m, 1h, 4h, 1d). Populated manually via a Mix task (Binance archive fetch or local CSV import) and automatically by the live Binance WebSocket feed. Strategies can query it to pre-warm their historical state at startup.

Strategy warmup integration (e.g. wiring `CandleDB.recent/3` into `IntradayMomentum.new_state/2`) is **out of scope** for this spec — it is a follow-on concern once the database exists.

---

## Data Model

Single table: `candles`

| Column             | Type         | Notes                                                    |
|--------------------|--------------|----------------------------------------------------------|
| `id`               | integer      | Autoincrement primary key                                |
| `symbol`           | string       | e.g. `"BTCUSDC"`                                        |
| `interval`         | string       | `"15m"`, `"1h"`, `"4h"`, `"1d"`                        |
| `open_time`        | integer      | Unix milliseconds (Binance native)                       |
| `close_time`       | integer      | Unix milliseconds — nullable (live feed omits it)        |
| `open`             | decimal      | Stored as TEXT in SQLite via `:decimal` Ecto type        |
| `high`             | decimal      | Stored as TEXT in SQLite — returns `Decimal` struct      |
| `low`              | decimal      | Stored as TEXT in SQLite — returns `Decimal` struct      |
| `close`            | decimal      | Stored as TEXT in SQLite — returns `Decimal` struct      |
| `volume`           | decimal      | Base asset volume (e.g. BTC) — nullable                 |
| `quote_volume`     | decimal      | Quote asset volume (e.g. USDC) — nullable               |
| `trade_count`      | integer      | Number of trades in the candle — nullable               |
| `taker_buy_volume` | decimal      | Base asset bought by takers — nullable                  |
| `taker_buy_quote`  | decimal      | Quote asset bought by takers — nullable                 |
| `inserted_at`      | utc_datetime | Ecto managed — never overwritten on upsert              |
| `updated_at`       | utc_datetime | Ecto managed                                             |

**On decimal storage:** `ecto_sqlite3` stores `:decimal` fields as TEXT and returns `Decimal` structs (not floats). All queries in this spec order by `open_time` (integer), so lexicographic ordering of decimal TEXT columns is never triggered. Do not add `ORDER BY` or `WHERE` clauses on decimal columns without handling this. Code that currently uses float arithmetic on candle prices will need to call `Decimal.to_float/1` if it queries from this store.

**Constraints & indexes:** One unique index on `(symbol, interval, open_time)`. This is both the deduplication constraint and the B-tree range query index — no second index is created.

**Database file:** `priv/repo/candles.db` — must be added to `.gitignore`.
**Migrations:** `priv/repo/migrations/` — committed to git.

---

## Field Normalisation

Binance data sources use different field names. `CandleDB.insert_candles/1` normalises all inputs to the DB schema before insertion. Callers always pass raw Binance maps.

| Binance field (archive/REST) | Binance field (live WebSocket) | DB column          |
|------------------------------|--------------------------------|--------------------|
| `quote_asset_volume`         | `quote_volume`                 | `quote_volume`     |
| `number_of_trades`           | _(absent)_                     | `trade_count`      |
| `taker_buy_base_volume`      | _(absent)_                     | `taker_buy_volume` |
| `taker_buy_quote_volume`     | `taker_buy_quote_volume`       | `taker_buy_quote`  |
| `close_time`                 | _(absent)_                     | `close_time`       |

Fields absent from the live WebSocket event are stored as `nil`. The schema permits nulls on all volume and metadata columns to accommodate partial inserts from the live feed.

### LiveSim candle shape passed to `insert_candles/1`

`BinanceStream` produces events of shape:

```elixir
%{symbol: "BTCUSDC", open_time: integer(), candle: %{open: ..., close: ..., ...}}
```

The candle sub-map does not carry `symbol`, `interval`, or `open_time`. Before calling `insert_candles/1`, `LiveSim.Manager` constructs a merged flat map:

```elixir
candle_map = Map.merge(event.candle, %{
  symbol: event.symbol,
  interval: "15m",      # BinanceStream subscribes to kline_15m only
  open_time: event.open_time
})
CandleDB.insert_candles([candle_map])
```

`insert_candles/1` normalises field names from this merged map before insertion.

### CSV import column schema

The `--file` mode of `mix candles.fetch` expects a CSV in Binance Vision export format — the same format produced by `mix binance.fetch_candles`:

```
open_time,open,high,low,close,volume,close_time,quote_asset_volume,
number_of_trades,taker_buy_base_volume,taker_buy_quote_volume
```

`symbol` and `interval` are supplied via CLI flags (`--symbol`, `--interval`) and merged with each parsed row before insertion.

---

## Components

### `CriptoTrader.CandleDB.Repo`
Module name: `CriptoTrader.CandleDB.Repo`. Standard Ecto Repo with `otp_app: :cripto_trader`. Config key: `config :cripto_trader, CriptoTrader.CandleDB.Repo, ...`.

Added to the **main** supervision tree in `Application.start/2` — unconditionally, not inside the `web_children/0` guard. Must appear **before** `LiveSim.Manager` in the child list so the Repo is available when Manager starts.

### `CriptoTrader.CandleDB.Candle`
Ecto schema + changeset. Required fields: `symbol`, `interval`, `open_time`, `open`, `high`, `low`, `close`. All other fields optional. Handles normalisation of Binance string OHLCV values to `:decimal` and field renaming per the normalisation table above.

### `CriptoTrader.CandleDB`
Public context module. All external code interacts only with this module — never with `Repo` or `Candle` directly.

```elixir
# Bulk upsert. Normalises field names then inserts with:
#   on_conflict: {:replace_all_except, [:id, :inserted_at]}
#   conflict_target: [:symbol, :interval, :open_time]
# Returns count of rows affected.
@spec insert_candles([map()]) :: {:ok, integer()} | {:error, term()}
def insert_candles(candles)

# Returns candles for the last `days` days, ordered by open_time ASC.
@spec recent(String.t(), String.t(), days: integer()) :: [Candle.t()]
def recent(symbol, interval, days: n)

# Returns candles in [from_ms, to_ms] range, ordered by open_time ASC.
@spec range(String.t(), String.t(), integer(), integer()) :: [Candle.t()]
def range(symbol, interval, from_ms, to_ms)
```

### `Mix.Tasks.Candles.Fetch`
Manual population. Two modes:

```bash
# Pull from Binance archive (wraps existing ArchiveCandles fetcher)
mix candles.fetch --symbol BTCUSDC --interval 1h --from 2024-01-01 --to 2024-12-31

# Import from a local CSV file (Binance Vision column format, see above)
mix candles.fetch --symbol BTCUSDC --interval 1h --file /path/to/data.csv
```

Prints progress (candles fetched / inserted). Exits non-zero on failure.

### `LiveSim.Manager` integration
Inside `handle_cast({:candle, event}, state)`, after the existing in-memory candle processing, add the fire-and-forget write:

```elixir
candle_map = Map.merge(event.candle, %{
  symbol: event.symbol,
  interval: "15m",        # BinanceStream subscribes to kline_15m only
  open_time: event.open_time
})
Task.start(fn -> CandleDB.insert_candles([candle_map]) end)
```

This is intentionally fire-and-forget. The live loop must never block on DB writes. A failed write logs an error and is not retried — acceptable for a 15m feed where the archive fetcher can backfill gaps manually.

---

## Data Flow

### Manual population (archive or CSV)
```
mix candles.fetch
  → ArchiveCandles.fetch() | CSV.parse()
  → CandleDB.insert_candles(candles)    # normalises fields, bulk upsert
```

### Live feed
```
BinanceStream → LiveSim.Manager (:candle cast)
  → existing in-memory logic            # unchanged
  → Task.start → CandleDB.insert_candles([merged_candle_map])
```

### Strategy queries (future — out of scope here)
```
CandleDB.recent("BTCUSDC", "1h", days: 14)
CandleDB.range("BTCUSDC", "15m", from_ms, to_ms)
```

---

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| Duplicate candle insert | Updates non-key fields; `inserted_at` preserved |
| DB unavailable during live feed | `Task.start` isolates failure; live loop unaffected |
| DB unavailable during query | Returns `{:error, reason}`; caller decides |
| `mix candles.fetch` network failure | Prints error, exits non-zero |
| Missing DB file on startup | SQLite auto-creates on first connection |

---

## Setup (fresh clone)

```bash
mix deps.get
mix ecto.create    # creates priv/repo/candles.db
mix ecto.migrate   # creates candles table + index
```

No `extra_applications` change is needed in `mix.exs` — `:ecto_sqlite3` is started automatically by Mix from the deps list.

---

## Testing

| Area | Approach |
|------|----------|
| `CandleDB` context | Ecto sandbox with in-memory SQLite — configured in `config/test.exs` |
| `Candle` changeset | Field normalisation, decimal coercion, required field validation |
| `mix candles.fetch` | Fixture CSV file matching Binance Vision column schema; no network calls |
| `LiveSim.Manager` | Existing tests unaffected; fire-and-forget write not exercised in test env |

`config/test.exs` is loaded via `import_config "#{config_env()}.exs"` appended as the **final line** of `config/config.exs` (after all other config statements so test overrides take effect).

`test/test_helper.exs` must be updated to set Ecto sandbox mode:
```elixir
Ecto.Adapters.SQL.Sandbox.mode(CriptoTrader.CandleDB.Repo, :manual)
```

---

## Dependencies to Add

```elixir
# mix.exs — no extra_applications change needed
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
| Create | `config/test.exs` |
| Modify | `lib/cripto_trader/application.ex` — add Repo unconditionally, before LiveSim.Manager |
| Modify | `lib/cripto_trader/live_sim/manager.ex` — fire-and-forget DB write after each candle |
| Modify | `mix.exs` — add deps |
| Modify | `config/config.exs` — add Repo config + `import_config "#{config_env()}.exs"` |
| Modify | `test/test_helper.exs` — add Ecto.Sandbox.mode call |
| Modify | `.gitignore` — add `priv/repo/candles.db` |
