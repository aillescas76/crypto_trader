# Experiment Loop — Quick Reference

Read this at the start of every `/experiment-loop` iteration alongside `priv/experiments/`.

---

## Mix Task Cheatsheet

```bash
mix experiments.status                          # overview table
mix experiments.add \
  --strategy CriptoTrader.Strategy.Experiment.YYYYMMDD<Name> \
  --hypothesis "..." \
  --symbols BTCUSDC,ETHUSDC,SOLUSDC,BNBUSDC,ADAUSDC,XRPUSDC \
  --interval 15m --balance 10000
mix experiments.run --all-pending              # run all queued
mix experiments.run --id exp-001               # run one
mix experiments.findings.add \
  --title "StrategyName: insight" \
  --experiment exp-001 \
  --tags tag1,tag2
```

---

## Elixir APIs

### Fetch candles (cached)

```elixir
{:ok, candles} = CriptoTrader.MarketData.ArchiveCandles.fetch(
  symbols: ["BTCUSDC"],
  interval: "15m",
  start_time: 1_640_995_200_000,
  end_time:   1_735_689_600_000,
  cache_dir: Path.join(System.user_home!(), ".cripto_trader/archive_cache")
)
# candles["BTCUSDC"] => [%{open_time: ms, open: "...", high: "...", low: "...", close: "...", volume: "..."}, ...]
```

### Run a backtest

```elixir
{:ok, result} = CriptoTrader.Simulation.Runner.run(
  symbols: ["BTCUSDC"],
  interval: "15m",
  candles_by_symbol: candles,
  strategy_fun: &MyStrategy.signal/2,
  strategy_state: MyStrategy.new_state(["BTCUSDC"]),
  initial_balance: 10_000.0,
  include_equity_curve: true,
  include_trade_log: false,
  log_strategy_decisions: false
)
# result.summary => %{pnl: _, pnl_pct: _, win_rate: _, max_drawdown_pct: _, trades: _, closed_trades: _}
# result.equity_curve => [%{time: ms, equity: _}, ...]
```

### Experiment state

```elixir
alias CriptoTrader.Experiments.State
State.list_experiments()           # {:ok, [map()]}
State.upsert_experiment(map)       # insert/update by "id"
State.list_findings()              # {:ok, [map()]}
State.add_finding(map)             # {:ok, id}
State.list_feedback()              # {:ok, [map()]}
State.acknowledge_feedback(id)     # :ok
```

---

## Training / Validation Split

| Split      | Date range              | Unix ms                  |
|------------|-------------------------|--------------------------|
| Training   | 2022-01-01 – 2024-12-31 | `< 1_735_689_600_000`    |
| Validation | 2025-01-01 – present    | `>= 1_735_689_600_000`   |

Start of data: `1_640_995_200_000` (2022-01-01 UTC)

**Pass criteria** (both splits must pass):
1. Strategy PnL% > BuyAndHold PnL%
2. Strategy Sharpe > BuyAndHold Sharpe **OR** max_drawdown < 40%

---

## Key Constants

```elixir
# Sharpe annualization
"15m" → 35_040 periods/year
"1h"  → 8_760
"1d"  → 365

# Default symbols
["BTCUSDC","ETHUSDC","SOLUSDC","BNBUSDC","ADAUSDC","XRPUSDC"]

# Default balance
10_000.0 USDC
```

---

## Strategy Skeleton

```elixir
defmodule CriptoTrader.Strategy.Experiment.YYYYMMDD<Name> do
  @moduledoc "One-line hypothesis"

  def new_state(_symbols, opts \\ []) do
    %{
      # only parameters whose values were determined in hypothesis research
    }
  end

  def signal(%{symbol: _symbol, candle: %{close: _close}}, state) do
    # pure logic — no IO, no HTTP, no process calls
    {[], state}
  end

  def signal(_event, state), do: {[], state}
end
```

File: `lib/cripto_trader/strategy/experiment/YYYYMMDD_<concept>.ex`

---

## Anti-Cheat Rules

1. **Fix parameters before running** — never adjust after seeing validation results
2. **Training data only** for hypothesis development — no grid search on full dataset
3. **Validation is held-out** — untouched until the experiment executes
4. **One hypothesis per experiment** — no cherry-picking variants
5. **Record a finding for every result** — passes AND failures
6. **Overfit flag** — training pass + validation fail = abandon that parameterization

---

## Graduated Strategies

When an experiment passes, promote it to production:

```bash
cp lib/cripto_trader/strategy/experiment/YYYYMMDD_concept.ex \
   lib/cripto_trader/strategy/concept.ex
# Update module name, add to binance.simulate --strategy map
```

---

## Dashboard

```bash
mix phx.server   # http://localhost:4000
# /           live experiment feed
# /findings   accumulated learnings
# /feedback   submit notes for next iteration
```
