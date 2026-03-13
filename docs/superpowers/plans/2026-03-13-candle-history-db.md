# Candle History Database Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent SQLite candle store that any strategy can query, populated via Binance archive fetch, local CSV import, or the live WebSocket feed.

**Architecture:** Ecto + `ecto_sqlite3` targeting `priv/repo/candles.db`. A `CandleDB` context module is the single public interface — all reads and writes go through it. The Repo is supervised unconditionally (including test env — do NOT start it manually in tests). Tests use a file-based test DB (`priv/repo/test_candles.db`) with `Ecto.Adapters.SQL.Sandbox` for transaction isolation. `LiveSim.Manager` writes each incoming live candle via a fire-and-forget `Task.start`.

**Tech Stack:** Elixir, Ecto 3.12, ecto_sql 3.12, ecto_sqlite3 0.17, SQLite, mix tasks.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `mix.exs` | Add ecto, ecto_sql, ecto_sqlite3 deps |
| Modify | `config/config.exs` | Repo config + conditional import_config |
| Create | `config/test.exs` | File-based test DB + Sandbox pool |
| Modify | `test/test_helper.exs` | Run migrations, set sandbox mode |
| Modify | `.gitignore` | Ignore DB runtime files |
| Create | `priv/repo/migrations/20260313000000_create_candles.exs` | Schema migration |
| Create | `lib/cripto_trader/candle_db/repo.ex` | Ecto Repo |
| Create | `lib/cripto_trader/candle_db/candle.ex` | Ecto schema + changeset + field normalisation |
| Create | `lib/cripto_trader/candle_db.ex` | Public context: insert_candles, recent, range |
| Modify | `lib/cripto_trader/application.ex` | Add Repo to main supervision tree |
| Create | `test/candle_db/candle_test.exs` | Changeset unit tests (async, no DB) |
| Create | `test/candle_db/candle_db_test.exs` | Context integration tests (sandbox) |
| Create | `lib/mix/tasks/candles.fetch.ex` | `mix candles.fetch` task |
| Create | `test/fixtures/candles.csv` | Fixture for mix task tests |
| Create | `test/mix/tasks/candles_fetch_test.exs` | Mix task tests |
| Modify | `lib/cripto_trader/live_sim/manager.ex` | Fire-and-forget DB write per candle |

---

## Chunk 1: Infrastructure — Deps, Config, Migration, Repo, Schema, Supervision

### Task 1: Add dependencies and configure Ecto

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`
- Create: `config/test.exs`
- Modify: `test/test_helper.exs`
- Modify: `.gitignore`

- [ ] **Step 1: Add deps to `mix.exs`**

In the `deps/0` function, add after `{:websockex, "~> 0.4"}`:

```elixir
{:ecto_sqlite3, "~> 0.17"},
{:ecto_sql, "~> 3.12"},
{:ecto, "~> 3.12"},
```

`ecto_sql` is listed explicitly because `test_helper.exs` calls `Ecto.Migrator` and `Ecto.Adapters.SQL.Sandbox`, both of which live in `ecto_sql` — not `ecto`.

- [ ] **Step 2: Add Repo config to `config/config.exs`**

Append the Repo config block:

```elixir
config :cripto_trader, CriptoTrader.CandleDB.Repo,
  database: Path.expand("../priv/repo/candles.db", __DIR__),
  pool_size: 5
```

Then append as the **final line** of `config/config.exs` — this must be last so env-specific values override the defaults above:

```elixir
if File.exists?(Path.expand("#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end
```

The conditional form avoids a crash in `dev` and `prod` environments where no env-specific config file exists.

- [ ] **Step 3: Create `config/test.exs`**

Use a file-based test DB (not `:memory:`) so that `Ecto.Adapters.SQL.Sandbox` can share a real connection pool across queries:

```elixir
import Config

config :cripto_trader, CriptoTrader.CandleDB.Repo,
  database: Path.expand("../priv/repo/test_candles.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox
```

- [ ] **Step 4: Update `test/test_helper.exs`**

The Repo is supervised unconditionally (added in Task 4), so it is already running when tests execute — do **not** call `Repo.start_link` here. Just run migrations and configure the sandbox:

```elixir
ExUnit.start()

Ecto.Migrator.with_repo(CriptoTrader.CandleDB.Repo, &Ecto.Migrator.run(&1, :up, all: true))
Ecto.Adapters.SQL.Sandbox.mode(CriptoTrader.CandleDB.Repo, :manual)
```

- [ ] **Step 5: Add DB files to `.gitignore`**

Append to `.gitignore`:

```
# Candle history database (runtime artifacts — not committed)
/priv/repo/candles.db
/priv/repo/candles.db-shm
/priv/repo/candles.db-wal
/priv/repo/test_candles.db
/priv/repo/test_candles.db-shm
/priv/repo/test_candles.db-wal
```

- [ ] **Step 6: Fetch deps**

```bash
mix deps.get
```

Expected: resolves ecto, ecto_sql, ecto_sqlite3 and transitive deps.

- [ ] **Step 7: Commit**

```bash
git add mix.exs mix.lock config/config.exs config/test.exs test/test_helper.exs .gitignore
git commit -m "chore: add ecto_sqlite3 deps and Repo config"
```

---

### Task 2: Create migration

**Files:**
- Create: `priv/repo/migrations/20260313000000_create_candles.exs`

- [ ] **Step 1: Create the migrations directory and file**

```bash
mkdir -p priv/repo/migrations
```

Then create `priv/repo/migrations/20260313000000_create_candles.exs`:

```elixir
defmodule CriptoTrader.CandleDB.Repo.Migrations.CreateCandles do
  use Ecto.Migration

  def change do
    create table(:candles) do
      add :symbol, :string, null: false
      add :interval, :string, null: false
      add :open_time, :integer, null: false
      add :close_time, :integer
      add :open, :decimal, null: false
      add :high, :decimal, null: false
      add :low, :decimal, null: false
      add :close, :decimal, null: false
      add :volume, :decimal
      add :quote_volume, :decimal
      add :trade_count, :integer
      add :taker_buy_volume, :decimal
      add :taker_buy_quote, :decimal

      timestamps(type: :utc_datetime)
    end

    create unique_index(:candles, [:symbol, :interval, :open_time])
  end
end
```

- [ ] **Step 2: Create the production DB and run migration**

```bash
mix ecto.create
mix ecto.migrate
```

Expected:
```
The database for CriptoTrader.CandleDB.Repo has been created
[info] == Running 20260313000000 CreateCandles.change/0 forward
[info] create table candles
[info] create index candles_symbol_interval_open_time_index
[info] == Migrated 20260313000000 in 0.0s
```

- [ ] **Step 3: Create the test DB and run migration**

```bash
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
```

Expected: same output for the test database.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/
git commit -m "feat: add candles table migration"
```

---

### Task 3: Create Repo and Candle schema

**Files:**
- Create: `lib/cripto_trader/candle_db/repo.ex`
- Create: `lib/cripto_trader/candle_db/candle.ex`
- Create: `test/candle_db/candle_test.exs`

- [ ] **Step 1: Write failing changeset tests**

These tests are pure unit tests — they never touch the database. `async: true` is safe.

Create `test/candle_db/candle_test.exs`:

```elixir
defmodule CriptoTrader.CandleDB.CandleTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.CandleDB.Candle

  @valid %{
    symbol: "BTCUSDC",
    interval: "1h",
    open_time: 1_718_409_600_000,
    open: "50000.0",
    high: "51000.0",
    low: "49500.0",
    close: "50500.0"
  }

  test "valid attrs produce a valid changeset" do
    assert Candle.changeset(@valid).valid?
  end

  test "missing required field is invalid" do
    cs = Candle.changeset(Map.delete(@valid, :symbol))
    refute cs.valid?
    assert :symbol in Keyword.keys(cs.errors)
  end

  test "open/high/low/close are coerced from strings to Decimal" do
    cs = Candle.changeset(@valid)
    assert cs.changes.open == Decimal.new("50000.0")
    assert cs.changes.close == Decimal.new("50500.0")
  end

  test "normalises quote_asset_volume -> quote_volume" do
    cs = Candle.changeset(Map.put(@valid, :quote_asset_volume, "12345.0"))
    assert cs.changes.quote_volume == Decimal.new("12345.0")
    refute Map.has_key?(cs.changes, :quote_asset_volume)
  end

  test "normalises number_of_trades -> trade_count" do
    cs = Candle.changeset(Map.put(@valid, :number_of_trades, 999))
    assert cs.changes.trade_count == 999
  end

  test "normalises taker_buy_base_volume -> taker_buy_volume" do
    cs = Candle.changeset(Map.put(@valid, :taker_buy_base_volume, "100.0"))
    assert cs.changes.taker_buy_volume == Decimal.new("100.0")
  end

  test "normalises taker_buy_quote_volume -> taker_buy_quote" do
    cs = Candle.changeset(Map.put(@valid, :taker_buy_quote_volume, "5000000.0"))
    assert cs.changes.taker_buy_quote == Decimal.new("5000000.0")
  end

  test "accepts string keys from CSV parsing" do
    attrs = %{
      "symbol" => "ETHUSDC",
      "interval" => "15m",
      "open_time" => 1_718_409_600_000,
      "open" => "3000.0",
      "high" => "3100.0",
      "low" => "2950.0",
      "close" => "3050.0"
    }
    assert Candle.changeset(attrs).valid?
  end

  test "optional fields can be absent" do
    cs = Candle.changeset(@valid)
    assert cs.valid?
    refute Map.has_key?(cs.changes, :volume)
    refute Map.has_key?(cs.changes, :trade_count)
  end
end
```

- [ ] **Step 2: Run test — expect module-not-found error**

```bash
mix test test/candle_db/candle_test.exs 2>&1 | head -5
```

Expected: error because `CriptoTrader.CandleDB.Candle` does not exist yet.

- [ ] **Step 3: Create `lib/cripto_trader/candle_db/repo.ex`**

```elixir
defmodule CriptoTrader.CandleDB.Repo do
  use Ecto.Repo,
    otp_app: :cripto_trader,
    adapter: Ecto.Adapters.SQLite3
end
```

- [ ] **Step 4: Create `lib/cripto_trader/candle_db/candle.ex`**

```elixir
defmodule CriptoTrader.CandleDB.Candle do
  use Ecto.Schema
  import Ecto.Changeset

  @required [:symbol, :interval, :open_time, :open, :high, :low, :close]
  @optional [:close_time, :volume, :quote_volume, :trade_count, :taker_buy_volume, :taker_buy_quote]

  schema "candles" do
    field :symbol, :string
    field :interval, :string
    field :open_time, :integer
    field :close_time, :integer
    field :open, :decimal
    field :high, :decimal
    field :low, :decimal
    field :close, :decimal
    field :volume, :decimal
    field :quote_volume, :decimal
    field :trade_count, :integer
    field :taker_buy_volume, :decimal
    field :taker_buy_quote, :decimal

    timestamps(type: :utc_datetime)
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(normalize(attrs), @required ++ @optional)
    |> validate_required(@required)
  end

  # Rename Binance field names to DB column names.
  # Handles both atom and string keys; Map.put_new/3 means the first match wins.
  defp normalize(attrs) do
    attrs
    |> rename(:quote_asset_volume, :quote_volume)
    |> rename("quote_asset_volume", :quote_volume)
    |> rename(:number_of_trades, :trade_count)
    |> rename("number_of_trades", :trade_count)
    |> rename(:taker_buy_base_volume, :taker_buy_volume)
    |> rename("taker_buy_base_volume", :taker_buy_volume)
    |> rename(:taker_buy_quote_volume, :taker_buy_quote)
    |> rename("taker_buy_quote_volume", :taker_buy_quote)
  end

  defp rename(attrs, from, to) do
    case Map.pop(attrs, from) do
      {nil, _} -> attrs
      {val, rest} -> Map.put_new(rest, to, val)
    end
  end
end
```

- [ ] **Step 5: Run changeset tests**

```bash
mix test test/candle_db/candle_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/cripto_trader/candle_db/ test/candle_db/candle_test.exs
git commit -m "feat: add CandleDB.Repo and Candle schema with field normalisation"
```

---

### Task 4: Wire Repo into the supervision tree

**Files:**
- Modify: `lib/cripto_trader/application.ex`

- [ ] **Step 1: Add Repo as an unconditional child**

In `lib/cripto_trader/application.ex`, change:

```elixir
children =
  [
    {Finch, name: CriptoTrader.Finch},
    CriptoTrader.Paper.Orders
  ] ++ web_children()
```

To:

```elixir
children =
  [
    {Finch, name: CriptoTrader.Finch},
    CriptoTrader.Paper.Orders,
    CriptoTrader.CandleDB.Repo
  ] ++ web_children()
```

The Repo must be in the unconditional list (not inside `web_children`), so it starts in every env including `MIX_ENV=test`. It must also appear **before** `LiveSim.Manager` (which is inside `web_children` after it) to guarantee the Repo is ready when Manager starts.

- [ ] **Step 2: Compile to check for errors**

```bash
mix compile
```

Expected: clean compile.

- [ ] **Step 3: Run the full test suite**

```bash
mix test
```

Expected: all existing tests pass. The Repo starts under the supervisor in test env; `test_helper.exs` runs migrations against the already-running Repo, then configures the sandbox.

- [ ] **Step 4: Commit**

```bash
git add lib/cripto_trader/application.ex
git commit -m "feat: add CandleDB.Repo to supervision tree"
```

---

## Chunk 2: CandleDB Context + Tests

### Task 5: Create the CandleDB context

**Files:**
- Create: `lib/cripto_trader/candle_db.ex`
- Create: `test/candle_db/candle_db_test.exs`

- [ ] **Step 1: Write failing context tests**

These tests write to and read from the real SQLite test DB. Each test checks out a sandboxed connection (transaction that rolls back on exit), so tests are isolated.

Create `test/candle_db/candle_db_test.exs`:

```elixir
defmodule CriptoTrader.CandleDBTest do
  use ExUnit.Case

  alias CriptoTrader.CandleDB
  alias CriptoTrader.CandleDB.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  @base %{
    symbol: "BTCUSDC",
    interval: "1h",
    open: "50000.0",
    high: "51000.0",
    low: "49500.0",
    close: "50500.0"
  }

  # Returns a candle map with open_time set to N days ago (in ms).
  defp candle(days_ago, overrides \\ %{}) do
    open_time = System.os_time(:millisecond) - days_ago * 86_400_000
    Map.merge(@base, Map.put(overrides, :open_time, open_time))
  end

  defp ts(days_ago), do: System.os_time(:millisecond) - days_ago * 86_400_000

  describe "insert_candles/1" do
    test "inserts candles and returns count" do
      assert {:ok, 2} = CandleDB.insert_candles([candle(5), candle(4)])
    end

    test "returns {:ok, 0} for empty list" do
      assert {:ok, 0} = CandleDB.insert_candles([])
    end

    test "deduplicates on (symbol, interval, open_time) — second insert does not error" do
      c = candle(5)
      assert {:ok, _} = CandleDB.insert_candles([c])
      assert {:ok, _} = CandleDB.insert_candles([c])
      # Only one row exists despite two inserts
      assert length(CandleDB.range("BTCUSDC", "1h", ts(6), ts(4))) == 1
    end

    test "upsert updates non-key fields but preserves inserted_at" do
      c = candle(5, %{close: "50000.0"})
      CandleDB.insert_candles([c])
      [row] = CandleDB.range("BTCUSDC", "1h", ts(6), ts(4))
      original_inserted_at = row.inserted_at

      CandleDB.insert_candles([candle(5, %{close: "99999.0"})])
      [row2] = CandleDB.range("BTCUSDC", "1h", ts(6), ts(4))
      assert Decimal.equal?(row2.close, Decimal.new("99999.0"))
      assert row2.inserted_at == original_inserted_at
    end

    test "normalises Binance archive field names" do
      c = Map.merge(@base, %{
        open_time: ts(5),
        quote_asset_volume: "1234.5",
        number_of_trades: 42,
        taker_buy_base_volume: "500.0",
        taker_buy_quote_volume: "25000000.0"
      })
      CandleDB.insert_candles([c])
      [row] = CandleDB.range("BTCUSDC", "1h", ts(6), ts(4))
      assert Decimal.equal?(row.quote_volume, Decimal.new("1234.5"))
      assert row.trade_count == 42
      assert Decimal.equal?(row.taker_buy_volume, Decimal.new("500.0"))
    end

    test "skips invalid candles without crashing" do
      bad = %{symbol: "BTCUSDC"}
      assert {:ok, 1} = CandleDB.insert_candles([bad, candle(5)])
    end
  end

  describe "recent/3" do
    test "returns candles within last N days, ordered by open_time ASC" do
      Enum.each([15, 8, 3, 1], fn d -> CandleDB.insert_candles([candle(d)]) end)
      rows = CandleDB.recent("BTCUSDC", "1h", days: 10)
      assert length(rows) == 3
      times = Enum.map(rows, & &1.open_time)
      assert times == Enum.sort(times)
    end

    test "returns empty list when no data in range" do
      assert [] = CandleDB.recent("BTCUSDC", "1h", days: 5)
    end

    test "filters by symbol and interval" do
      CandleDB.insert_candles([candle(3)])
      CandleDB.insert_candles([Map.merge(@base, %{symbol: "ETHUSDC", open_time: ts(3)})])
      CandleDB.insert_candles([Map.merge(@base, %{interval: "15m", open_time: ts(3)})])

      rows = CandleDB.recent("BTCUSDC", "1h", days: 10)
      assert length(rows) == 1
      assert hd(rows).symbol == "BTCUSDC"
      assert hd(rows).interval == "1h"
    end
  end

  describe "range/4" do
    test "returns candles within [from_ms, to_ms] inclusive, ordered ASC" do
      Enum.each([5, 3, 1], fn d -> CandleDB.insert_candles([candle(d)]) end)
      rows = CandleDB.range("BTCUSDC", "1h", ts(4), ts(2))
      assert length(rows) == 1
      assert_in_delta hd(rows).open_time, ts(3), 5_000
    end

    test "returns empty list when no candles in range" do
      assert [] = CandleDB.range("BTCUSDC", "1h", ts(2), ts(1))
    end
  end
end
```

- [ ] **Step 2: Run tests — expect module-not-found error**

```bash
mix test test/candle_db/candle_db_test.exs 2>&1 | head -5
```

Expected: error because `CriptoTrader.CandleDB` does not exist yet.

- [ ] **Step 3: Create `lib/cripto_trader/candle_db.ex`**

```elixir
defmodule CriptoTrader.CandleDB do
  @moduledoc """
  Public interface to the candle history database.

  All candle reads and writes go through this module. The underlying Repo and
  schema are private implementation details — do not call them directly.

  Decimal fields (open, high, low, close, volume, etc.) are returned as
  `Decimal` structs, not floats. Use `Decimal.to_float/1` if float
  arithmetic is required downstream.
  """

  import Ecto.Query

  alias CriptoTrader.CandleDB.{Candle, Repo}

  @doc """
  Bulk upsert candles. Accepts raw Binance maps from any source (archive,
  REST, or live feed) — field normalisation is handled internally.

  On conflict on `(symbol, interval, open_time)`, all fields except `id` and
  `inserted_at` are updated. Invalid candles are skipped silently.

  Returns `{:ok, count}` where count is rows inserted or updated.
  """
  @spec insert_candles([map()]) :: {:ok, integer()} | {:error, term()}
  def insert_candles([]), do: {:ok, 0}

  def insert_candles(candles) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      candles
      |> Enum.map(&to_row(&1, now))
      |> Enum.reject(&is_nil/1)

    if rows == [] do
      {:ok, 0}
    else
      {count, _} =
        Repo.insert_all(
          Candle,
          rows,
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:symbol, :interval, :open_time]
        )

      {:ok, count}
    end
  end

  @doc """
  Returns candles for the last `days` calendar days for the given symbol
  and interval, ordered by `open_time` ascending.
  """
  @spec recent(String.t(), String.t(), [{:days, integer()}]) :: [Candle.t()]
  def recent(symbol, interval, days: n) do
    cutoff_ms =
      DateTime.utc_now()
      |> DateTime.add(-n * 86_400, :second)
      |> DateTime.to_unix(:millisecond)

    Repo.all(
      from c in Candle,
        where:
          c.symbol == ^symbol and
            c.interval == ^interval and
            c.open_time >= ^cutoff_ms,
        order_by: [asc: c.open_time]
    )
  end

  @doc """
  Returns candles in the closed interval `[from_ms, to_ms]` (Unix ms),
  ordered by `open_time` ascending.
  """
  @spec range(String.t(), String.t(), integer(), integer()) :: [Candle.t()]
  def range(symbol, interval, from_ms, to_ms) do
    Repo.all(
      from c in Candle,
        where:
          c.symbol == ^symbol and
            c.interval == ^interval and
            c.open_time >= ^from_ms and
            c.open_time <= ^to_ms,
        order_by: [asc: c.open_time]
    )
  end

  # -- Private --

  defp to_row(raw, now) do
    cs = Candle.changeset(raw)

    if cs.valid? do
      cs
      |> Ecto.Changeset.apply_changes()
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
      |> Map.merge(%{inserted_at: now, updated_at: now})
    else
      nil
    end
  end
end
```

- [ ] **Step 4: Run the context tests**

```bash
mix test test/candle_db/candle_db_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/cripto_trader/candle_db.ex test/candle_db/candle_db_test.exs
git commit -m "feat: add CandleDB context with insert_candles, recent, range"
```

---

## Chunk 3: Mix Task + LiveSim Integration

### Task 6: Create `mix candles.fetch`

**Files:**
- Create: `lib/mix/tasks/candles.fetch.ex`
- Create: `test/fixtures/candles.csv`
- Create: `test/mix/tasks/candles_fetch_test.exs`

- [ ] **Step 1: Create the fixture CSV**

Create `test/fixtures/candles.csv`. Column order (no header): `open_time, open, high, low, close, volume, close_time, quote_asset_volume, number_of_trades, taker_buy_base_volume, taker_buy_quote_volume`.

```
1718409600000,50000.0,51000.0,49500.0,50500.0,100.5,1718413199999,5050000.0,1200,50.0,2525000.0
1718413200000,50500.0,52000.0,50200.0,51800.0,200.0,1718416799999,10360000.0,2400,100.0,5180000.0
1718416800000,51800.0,53000.0,51500.0,52500.0,150.0,1718420399999,7875000.0,1800,75.0,3937500.0
```

- [ ] **Step 2: Write failing task tests**

Create `test/mix/tasks/candles_fetch_test.exs`:

```elixir
defmodule Mix.Tasks.Candles.FetchTest do
  use ExUnit.Case

  alias CriptoTrader.CandleDB
  alias CriptoTrader.CandleDB.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  @fixture Path.expand("../../fixtures/candles.csv", __DIR__)

  describe "--file mode (CSV import)" do
    test "imports all rows from CSV and writes to DB" do
      Mix.Tasks.Candles.Fetch.run(["--symbol", "BTCUSDC", "--interval", "1h", "--file", @fixture])

      rows = CandleDB.range("BTCUSDC", "1h", 0, :os.system_time(:millisecond))
      assert length(rows) == 3
      assert hd(rows).symbol == "BTCUSDC"
      assert hd(rows).interval == "1h"
      assert hd(rows).open_time == 1_718_409_600_000
    end

    test "sets volume fields correctly from CSV" do
      Mix.Tasks.Candles.Fetch.run(["--symbol", "BTCUSDC", "--interval", "1h", "--file", @fixture])

      [row | _] = CandleDB.range("BTCUSDC", "1h", 0, :os.system_time(:millisecond))
      assert Decimal.equal?(row.volume, Decimal.new("100.5"))
      assert Decimal.equal?(row.quote_volume, Decimal.new("5050000.0"))
      assert row.trade_count == 1200
    end

    test "exits non-zero when file does not exist" do
      assert catch_exit(
               Mix.Tasks.Candles.Fetch.run([
                 "--symbol", "BTCUSDC",
                 "--interval", "1h",
                 "--file", "/nonexistent/path.csv"
               ])
             ) == {:shutdown, 1}
    end
  end
end
```

- [ ] **Step 3: Run tests — expect module-not-found error**

```bash
mix test test/mix/tasks/candles_fetch_test.exs 2>&1 | head -5
```

- [ ] **Step 4: Create `lib/mix/tasks/candles.fetch.ex`**

```elixir
defmodule Mix.Tasks.Candles.Fetch do
  @shortdoc "Populate the candle history DB from Binance archive or local CSV"

  @moduledoc """
  Fetches and stores OHLCV candles into the SQLite database.

  ## Archive mode (downloads from Binance Vision monthly archives)

      mix candles.fetch --symbol BTCUSDC --interval 1h --from 2024-01-01 --to 2024-12-31

  ## CSV import mode (Binance Vision column format)

      mix candles.fetch --symbol BTCUSDC --interval 1h --file /path/to/data.csv

  CSV column order (no header, 11 columns):
      open_time, open, high, low, close, volume, close_time,
      quote_asset_volume, number_of_trades, taker_buy_base_volume, taker_buy_quote_volume

  Options:
    --symbol    Required. Trading pair, e.g. BTCUSDC
    --interval  Required. Candle interval: 15m | 1h | 4h | 1d
    --from      Archive mode: start date (YYYY-MM-DD, inclusive)
    --to        Archive mode: end date (YYYY-MM-DD, defaults to today)
    --file      CSV mode: path to local CSV file
  """

  use Mix.Task

  alias CriptoTrader.CandleDB
  alias CriptoTrader.MarketData.ArchiveCandles

  @csv_columns ~w(open_time open high low close volume close_time
                  quote_asset_volume number_of_trades
                  taker_buy_base_volume taker_buy_quote_volume)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [symbol: :string, interval: :string, from: :string, to: :string, file: :string]
      )

    symbol = opts[:symbol] || abort("--symbol is required")
    interval = opts[:interval] || abort("--interval is required")

    cond do
      opts[:file] -> import_csv(symbol, interval, opts[:file])
      opts[:from] -> fetch_archive(symbol, interval, opts[:from], opts[:to] || Date.to_string(Date.utc_today()))
      true -> abort("Provide --file for CSV import or --from/--to for archive fetch")
    end
  end

  # -- CSV import --

  defp import_csv(symbol, interval, path) do
    unless File.exists?(path), do: abort("File not found: #{path}")

    Mix.shell().info("Importing #{path} for #{symbol} #{interval}...")

    candles =
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&parse_csv_row(&1, symbol, interval))
      |> Enum.reject(&is_nil/1)

    case CandleDB.insert_candles(candles) do
      {:ok, count} -> Mix.shell().info("Done — #{count} candle(s) inserted/updated.")
      {:error, reason} -> abort("DB error: #{inspect(reason)}")
    end
  end

  defp parse_csv_row(line, symbol, interval) do
    # Take at most 11 values — Binance Vision files may have a trailing comma
    values = line |> String.split(",") |> Enum.take(11)

    if length(values) < 11 do
      nil
    else
      @csv_columns
      |> Enum.zip(values)
      |> Map.new()
      |> Map.merge(%{"symbol" => symbol, "interval" => interval})
      |> coerce_integers(["open_time", "close_time", "number_of_trades"])
    end
  end

  defp coerce_integers(map, keys) do
    Enum.reduce(keys, map, fn k, acc ->
      case Map.get(acc, k) do
        nil -> acc
        v -> Map.put(acc, k, String.to_integer(String.trim(v)))
      end
    end)
  end

  # -- Archive fetch --

  defp fetch_archive(symbol, interval, from_str, to_str) do
    start_ms = parse_date!(from_str)
    end_ms = parse_date!(to_str)

    Mix.shell().info("Fetching #{symbol} #{interval} #{from_str}..#{to_str} from Binance archive...")

    case ArchiveCandles.fetch(symbols: [symbol], interval: interval, start_time: start_ms, end_time: end_ms) do
      {:ok, candles_by_symbol} ->
        candles =
          candles_by_symbol
          |> Map.get(symbol, [])
          |> Enum.map(&Map.merge(&1, %{symbol: symbol, interval: interval}))

        case CandleDB.insert_candles(candles) do
          {:ok, count} -> Mix.shell().info("Done — #{count} candle(s) inserted/updated.")
          {:error, reason} -> abort("DB error: #{inspect(reason)}")
        end

      {:error, reason} ->
        abort("Fetch failed: #{inspect(reason)}")
    end
  end

  defp parse_date!(str) do
    str
    |> Date.from_iso8601!()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp abort(msg) do
    Mix.shell().error(msg)
    exit({:shutdown, 1})
  end
end
```

- [ ] **Step 5: Run task tests**

```bash
mix test test/mix/tasks/candles_fetch_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Smoke-test the task manually**

```bash
mix candles.fetch --symbol TESTUSDC --interval 1h --file test/fixtures/candles.csv
```

Expected:
```
Importing test/fixtures/candles.csv for TESTUSDC 1h...
Done — 3 candle(s) inserted/updated.
```

- [ ] **Step 7: Commit**

```bash
git add lib/mix/tasks/candles.fetch.ex test/mix/tasks/candles_fetch_test.exs test/fixtures/candles.csv
git commit -m "feat: add mix candles.fetch task (archive + CSV modes)"
```

---

### Task 7: Integrate LiveSim.Manager

**Files:**
- Modify: `lib/cripto_trader/live_sim/manager.ex`

- [ ] **Step 1: Locate the candle cast handler**

Open `lib/cripto_trader/live_sim/manager.ex` and find `handle_cast({:candle, event}, state)` (around line 103). It reads:

```elixir
def handle_cast({:candle, event}, state) do
  symbol = event.symbol
  close = get_candle_float(event.candle, :close)
  ...
  {:noreply, new_state}
end
```

- [ ] **Step 2: Add fire-and-forget DB write**

Add `require Logger` near the top of the file alongside the existing `require Logger` (if already present, skip). Then just before the `{:noreply, new_state}` return, add:

```elixir
candle_map =
  Map.merge(event.candle, %{
    symbol: event.symbol,
    interval: "15m",
    open_time: event.open_time
  })

Task.start(fn ->
  case CriptoTrader.CandleDB.insert_candles([candle_map]) do
    {:ok, _} -> :ok
    {:error, reason} -> Logger.warning("CandleDB write failed: #{inspect(reason)}")
  end
end)
```

`interval` is hardcoded to `"15m"` because `BinanceStream` subscribes only to `kline_15m`. The write is fire-and-forget so the live loop is never blocked. Failures are logged as warnings — they are not retried, since the archive fetcher can backfill gaps.

- [ ] **Step 3: Compile**

```bash
mix compile
```

Expected: clean compile with no warnings.

- [ ] **Step 4: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cripto_trader/live_sim/manager.ex
git commit -m "feat: write live candles to CandleDB on each BinanceStream event"
```

---

## Final Verification

- [ ] **Run full test suite**

```bash
mix test
```

Expected: all tests pass, no warnings.

- [ ] **Verify DB setup from scratch**

```bash
mix ecto.drop && mix ecto.create && mix ecto.migrate
```

Expected: clean run, no errors.

- [ ] **Verify CSV import end-to-end**

```bash
mix candles.fetch --symbol BTCUSDC --interval 1h --file test/fixtures/candles.csv
```

Expected: `Done — 3 candle(s) inserted/updated.`
