# Automated Strategy Builder — Requirements & Design

**Date:** 2026-03-05
**Status:** Approved

## 1. Purpose

Build an LLM-driven automated strategy creation platform for Binance Spot trading. Users submit trading goals, Claude generates strategy specs, the system backtests them with volume-aware simulation, and users review/approve/deploy via a real-time Phoenix LiveView dashboard.

## 2. Architecture

Monolith Phoenix application integrated into the existing `cripto_trader` Elixir project.

```
┌─────────────────────────────────────────────────────────────┐
│                    Phoenix LiveView UI                       │
│  ┌──────────┐ ┌──────────────┐ ┌──────────┐ ┌────────────┐ │
│  │ Strategy │ │   Backtest   │ │ Trading  │ │  Settings  │ │
│  │Dashboard │ │   Results    │ │ Monitor  │ │  & Config  │ │
│  └────┬─────┘ └──────┬───────┘ └────┬─────┘ └─────┬──────┘ │
│       └──────────────┴──────┬───────┴──────────────┘        │
│                             │ PubSub                        │
├─────────────────────────────┼───────────────────────────────┤
│                     Application Layer                       │
│  ┌──────────────┐ ┌────────┴────────┐ ┌──────────────────┐ │
│  │ Strategy     │ │   Backtest      │ │  Trading         │ │
│  │ Generator    │ │   Orchestrator  │ │  Supervisor      │ │
│  │ (AI + Spec)  │ │   (Runner)      │ │  (Robot)         │ │
│  └──────┬───────┘ └────────┬────────┘ └────────┬─────────┘ │
│         │                  │                    │           │
│  ┌──────┴───────┐ ┌───────┴────────┐ ┌────────┴─────────┐ │
│  │ Claude API   │ │  Indicator     │ │  Order Manager   │ │
│  │ Client       │ │  Library       │ │  + Risk          │ │
│  └──────────────┘ └────────────────┘ └──────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Real-Time Data Layer                                 │  │
│  │  ┌─────────────────┐  ┌────────────────────────────┐ │  │
│  │  │ Binance WebSocket│  │ LiveEvaluator (per strategy)│ │  │
│  │  │ (kline streams)  │──│ indicator compute + signals │ │  │
│  │  └─────────────────┘  └────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                     Data Layer                              │
│  ┌──────────────┐ ┌────────────────┐ ┌──────────────────┐ │
│  │ PostgreSQL   │ │  Binance API   │ │  JSON Files      │ │
│  │ (Ecto)       │ │  (REST + WS)   │ │  (legacy compat) │ │
│  └──────────────┘ └────────────────┘ └──────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

- Phoenix PubSub connects LiveView pages to backend events in real-time
- Existing modules (`Simulation.Runner`, `Trading.Robot`, `OrderManager`, `Risk`) stay unchanged
- New modules slot in alongside: `AI.Client`, `Indicators.*`, `StrategySpec.*`, `MarketData.WebSocket`, `Strategy.LiveEvaluator`
- PostgreSQL via Ecto for persistent storage; existing JSON files kept for backward compatibility with the improvement loop

### PubSub Topics

```
"market:{symbol}:{interval}"    → raw candle data from WebSocket
"signal:strategy_{id}"          → BUY/SELL signals (before order)
"trade:strategy_{id}"           → order fills/rejections
"backtest:strategy_{id}"        → backtest progress/completion
"ai:generation_{request_id}"    → AI generation status
```

## 3. Strategy Spec Format

Every strategy is a JSON document — the contract between the LLM, the UI, and the execution engine.

```json
{
  "version": "1.0",
  "name": "btc_momentum_v1",
  "description": "Momentum strategy using SMA crossover with RSI filter",
  "symbols": ["BTCUSDT"],
  "interval": "15m",
  "indicators": [
    {"type": "sma", "period": 9, "source": "close", "as": "sma_fast"},
    {"type": "sma", "period": 21, "source": "close", "as": "sma_slow"},
    {"type": "rsi", "period": 14, "source": "close", "as": "rsi"},
    {"type": "atr", "period": 14, "source": "close", "as": "atr"}
  ],
  "entry_rules": [
    {"condition": "sma_fast > sma_slow AND rsi < 30", "action": "BUY"}
  ],
  "exit_rules": [
    {"condition": "sma_fast < sma_slow OR rsi > 70", "action": "SELL"}
  ],
  "risk": {
    "position_size_pct": 0.02,
    "stop_loss_pct": 0.03,
    "take_profit_pct": 0.06,
    "max_open_positions": 3,
    "min_candle_volume": 100.0,
    "max_fill_ratio": 0.05,
    "slippage_model": "linear"
  }
}
```

### Condition Expression Language

Rules use a simple expression language evaluated by the spec interpreter. No arbitrary code execution.

```
Comparison:    >  <  >=  <=  ==  !=
Logical:       AND  OR  NOT
Crossover:     cross_above(a, b)    — a was <= b, now a > b
               cross_below(a, b)    — a was >= b, now a < b
Operands:      indicator names      — sma_fast, rsi, atr
               candle fields        — close, open, high, low, volume
               constants            — 30, 0.5, 100.0
               arithmetic           — close - atr * 2
```

### Spec Interpreter Flow

```
Candle arrives
  → Compute all indicators (using candle history window)
  → Evaluate entry_rules conditions against indicator values
  → Evaluate exit_rules conditions against indicator values
  → Volume filter (min volume, max fill ratio, slippage)
  → Emit orders (BUY/SELL) with risk-adjusted position sizing
  → Pass to OrderManager (existing pipeline)
```

The interpreter produces a standard `strategy_fun` compatible with `Simulation.Runner` and `Trading.Robot`.

## 4. Indicator Library

Each indicator is a pure function: `(candles, params) -> [values]`

| Module | Full Name | Output |
|--------|-----------|--------|
| `CriptoTrader.Indicators.SMA` | Simple Moving Average | Single series |
| `CriptoTrader.Indicators.EMA` | Exponential Moving Average | Single series |
| `CriptoTrader.Indicators.RSI` | Relative Strength Index | Single series (0-100) |
| `CriptoTrader.Indicators.MACD` | Moving Average Convergence Divergence | `{macd_line, signal_line, histogram}` |
| `CriptoTrader.Indicators.BB` | Bollinger Bands | `{upper, middle, lower}` |
| `CriptoTrader.Indicators.ATR` | Average True Range | Single series |
| `CriptoTrader.Indicators.VOL` | Volume Analysis | `{raw_volume, volume_ma}` |

## 5. Claude API Integration

### Client API

```elixir
CriptoTrader.AI.Client
  |-- configure(api_key, model, opts)
  |-- generate_strategy(goal, constraints, history) -> {:ok, spec}
  |-- improve_strategy(current_spec, backtest_results) -> {:ok, new_spec}
  |-- explain_strategy(spec) -> {:ok, explanation}
```

### Generation Flow

1. User submits goal via dashboard
2. System builds prompt with: available indicators, spec schema, expression language reference, historical market summary, previous results
3. Claude API call using tool_use for structured JSON output
4. Server-side validation: schema, indicator types, expression parsing, risk bounds, valid symbols
5. If valid: save as `pending_review`, auto-backtest
6. If invalid: retry with error feedback (max 3 attempts)
7. PubSub broadcast → LiveView updates

### Improvement Flow

1. User clicks "Improve" on existing strategy
2. System sends Claude: current spec + backtest results + losing trade patterns + equity curve shape
3. Constraint: "change at most 2 parameters or 1 rule"
4. Returns modified spec (versioned, parent_id linked)
5. Auto-backtest, show side-by-side comparison

### Configuration

- `ANTHROPIC_API_KEY` environment variable
- `CLAUDE_MODEL` env var (default: `claude-sonnet-4-6`)
- Rate limiting: max 10 generation requests per hour (configurable)
- Token budget tracking per session
- Binance API keys never sent to Claude — only market summaries and strategy specs

## 6. Volume-Aware Order Simulation

### Volume Validation on Signals

Before emitting a BUY/SELL signal, check order feasibility against candle volume:

- **Max fill ratio**: order quantity must be < X% of candle volume (default: 5%) — prevents unrealistic fills in thin markets
- **Slippage estimation**: if order is > 1% of volume, estimate price impact using a linear model
- **Minimum volume threshold**: skip signal if candle volume is below a configurable floor

### Flow

```
Candle arrives with volume data
  → Indicators computed, rules evaluated → raw signal
  → Volume filter:
      candle_volume < min_volume_threshold?  → skip, log "low liquidity"
      order_qty > max_fill_ratio * volume?   → reduce qty or skip
      order_qty > slippage_threshold * vol?  → adjust expected price
  → Adjusted signal emitted (with volume context metadata)
  → Order placed with realistic price/quantity
```

Applies in both backtesting and live trading — backtest results reflect realistic fills.

## 7. Real-Time Market Data

### Binance WebSocket Integration

```
CriptoTrader.MarketData.WebSocket (GenServer)
  |-- maintains connections per symbol+interval
  |-- reconnects on disconnect with backoff
  |-- broadcasts candle close events via PubSub
```

### Live Strategy Evaluator

```
CriptoTrader.Strategy.LiveEvaluator (GenServer per active strategy)
  |-- subscribes to relevant symbol+interval PubSub topics
  |-- maintains candle history window for indicator computation
  |-- computes indicators on each candle close
  |-- evaluates spec rules
  |-- applies volume filter
  |-- emits signal event via PubSub (before order)
  |-- routes orders to OrderManager
```

### Signal Event Format

```elixir
%{
  strategy_id: 123,
  timestamp: ~U[2026-03-05 14:30:00Z],
  symbol: "BTCUSDT",
  side: "BUY",
  price: 67234.50,
  quantity: 0.001,
  indicators: %{sma_fast: 67100.0, sma_slow: 66800.0, rsi: 28.5},
  triggering_rule: "sma_fast > sma_slow AND rsi < 30",
  volume_context: %{
    candle_volume: 150.3,
    fill_ratio: 0.0007,
    slippage_estimate: 0.0,
    skipped: false
  }
}
```

## 8. Database Schema

### Tables

```sql
-- Users (single-user for v1, extensible)
users (
  id, email, password_hash, preferences jsonb,
  inserted_at, updated_at
)

-- Strategy definitions
strategies (
  id, user_id FK, name, spec jsonb,
  status enum(pending_review, approved, paper_trading, live_trading, paused, rejected, archived),
  version integer, parent_id FK(self),
  generation_method enum(ai_generated, ai_improved, manual),
  inserted_at, updated_at
)

-- One-off backtest snapshots
backtest_results (
  id, strategy_id FK,
  pnl, win_rate, max_drawdown_pct, sharpe_ratio,
  total_trades, closed_trades, rejected_orders, events_processed,
  trade_log jsonb, equity_curve jsonb, config jsonb,
  duration_ms,
  inserted_at
)

-- Ongoing performance tracking (daily rollups)
strategy_performance (
  id, strategy_id FK,
  mode enum(paper, live),
  period_start, period_end,
  pnl, pnl_pct, win_rate, max_drawdown_pct,
  sharpe_ratio, sortino_ratio,
  total_trades, winning_trades, losing_trades,
  avg_win, avg_loss, profit_factor,
  avg_holding_period_ms,
  total_volume_traded, total_fees_estimated,
  equity_high, equity_low,
  signals_emitted, signals_skipped_volume,
  inserted_at
)

-- Individual trade records
trade_history (
  id, user_id FK, strategy_id FK,
  symbol, side enum(BUY, SELL), quantity, price,
  mode enum(paper, live),
  status enum(filled, rejected), rejection_reason,
  volume_context jsonb,
  executed_at, inserted_at
)

-- AI usage tracking
ai_requests (
  id, user_id FK, strategy_id FK nullable,
  request_type enum(generate, improve, explain),
  prompt_summary, model,
  input_tokens, output_tokens, duration_ms,
  status enum(success, failed), error_message,
  inserted_at
)
```

### Design Notes

- `strategies.spec` stores the full JSON spec as `jsonb` — queryable, indexable
- `strategies.parent_id` tracks lineage for AI-improved versions
- `strategy_performance` has one row per strategy per day for charting over time
- `trade_history.volume_context` stores fill ratio, slippage estimate per trade
- `ai_requests` enables cost monitoring and debugging

## 9. Strategy Lifecycle State Machine

```
                    ┌──────────┐
          User      │          │  AI generates spec
         rejects    │  (start) │  + auto-backtests
            ┌───────│          │───────┐
            │       └──────────┘       │
            ▼                          ▼
     ┌────────────┐          ┌─────────────────┐
     │  rejected  │          │ pending_review   │
     └────────────┘          └────────┬────────┘
                                      │
                          User clicks "Approve"
                                      │
                                      ▼
                             ┌────────────────┐
                      ┌──────│   approved      │
                      │      └────────┬───────┘
                      │               │
                      │   User clicks "Deploy to Paper"
                      │               │
                      │               ▼
                      │      ┌────────────────┐
           User clicks│      │ paper_trading   │──── User clicks "Pause"
           "Archive"  │      └────────┬───────┘            │
                      │               │                     ▼
                      │   User clicks "Go Live"     ┌────────────┐
                      │               │             │  paused     │
                      │               ▼             └──────┬─────┘
                      │      ┌────────────────┐            │
                      ├──────│ live_trading    │◄───────────┘
                      │      └────────────────┘     User clicks
                      │                              "Resume"
                      ▼
               ┌────────────┐
               │  archived   │
               └────────────┘
```

### Transition Rules

| From | To | Trigger | Guard |
|------|----|---------|-------|
| — | `pending_review` | AI generates + backtests | Spec passes validation |
| `pending_review` | `approved` | User approves | At least one backtest exists |
| `pending_review` | `rejected` | User rejects | — |
| `pending_review` | `pending_review` | User clicks "Improve" | Creates new version, re-backtests |
| `approved` | `paper_trading` | User deploys to paper | Binance API keys configured |
| `paper_trading` | `live_trading` | User promotes to live | Min 24h paper period, user confirms |
| `paper_trading` | `paused` | User pauses | Closes open positions gracefully |
| `live_trading` | `paused` | User pauses | Closes open positions gracefully |
| `paused` | `paper_trading` | User resumes to paper | — |
| `paused` | `live_trading` | User resumes to live | User confirms warning |
| any active | `archived` | User archives | Stops trading, keeps history |

### Safety Guards

- Live promotion requires 24h minimum paper period
- Live transitions always show a confirmation dialog with current paper performance
- Pause closes positions gracefully (sells open positions at market)
- Global kill switch on Trading Monitor pauses all active strategies
- Max concurrent live strategies: configurable limit (default: 3)

## 10. LiveView UI Pages

| Route | Page | Purpose |
|-------|------|---------|
| `/` | Dashboard | Redirect to `/strategies` |
| `/login` | Auth | Login form |
| `/strategies` | Strategy List | Card grid with status filters, quick actions |
| `/strategies/new` | Generator | Goal form → triggers AI generation |
| `/strategies/:id` | Detail | Spec viewer, backtest results, performance charts, actions |
| `/strategies/:id/backtest` | Backtest Config | Run new backtest with custom parameters |
| `/strategies/:id/compare` | Comparison | Side-by-side original vs improved, backtest vs live |
| `/trading` | Monitor | Real-time signal feed, active strategies, positions, kill switch |
| `/history` | Trade History | Paginated log with filters, CSV export |
| `/settings` | Settings | API keys, risk defaults, AI budget, trading mode |

### Strategy Detail Tabs

- **Overview**: spec viewer, rules as readable sentences, risk params
- **Backtest**: metrics cards (PnL, win rate, drawdown, Sharpe), equity curve chart, trade log table
- **Performance**: cumulative PnL chart, rolling Sharpe, drawdown plot, win rate over time, volume-skipped signal count
- **Comparison**: metric table (backtest | paper 7d | paper 30d | live 7d | live 30d)

### Trading Monitor

- Per-strategy row: current PnL, open positions, last trade, uptime
- Real-time signal feed: timestamp, strategy, symbol, side, price, triggering indicators, volume context
- Color coding: green BUY, red SELL, grey skipped (low volume)
- Global "Pause All Trading" button

### Charting

Lightweight Charts (TradingView open-source library) via Phoenix LiveView JS hooks — purpose-built for financial data, candlestick support, small bundle size.

## 11. Non-Functional Requirements

### Performance

- Indicator computation for 1000 candles across 7 indicators: < 100ms
- Backtest of 90 days / 15m candles: < 5 minutes (existing benchmark, preserved)
- Strategy spec validation: < 50ms
- LiveView page load: < 500ms
- PubSub event delivery to UI: < 100ms
- Signal latency from candle close: < 1s

### Security

- API keys stored encrypted at rest in the database
- Binance API keys never sent to Claude
- All LiveView routes require authentication
- CSRF protection on all forms (Phoenix default)
- Rate limiting on AI generation requests (10/hour default)
- No arbitrary code execution — strategy specs are data, not code

### Reliability

- Graceful degradation if Claude API is unreachable
- Backtest failures don't affect live trading processes
- Trading Robot supervised with automatic restart (existing OTP pattern)
- WebSocket reconnection with exponential backoff
- Database connection pool (default: 10)

### Observability

- Structured logging for all AI requests (tokens, duration, success/failure)
- Structured logging for all strategy state transitions
- Existing order/trading event logs preserved
- AI cost tracking visible in Settings page
- Signal events logged with volume context

## 12. Acceptance Criteria

Existing criteria (preserved):

| ID | Criterion |
|----|-----------|
| AC-1 | A CLI command fetches candles for at least one symbol and interval |
| AC-2 | A simulation run can process 3 months of 15m candles in under 5 minutes |
| AC-3 | A single strategy can run against multiple symbols in simulation |
| AC-4 | All risk checks are enforced in both paper and live modes |

New criteria:

| ID | Criterion | Verification |
|----|-----------|--------------|
| AC-5 | User can submit a goal and receive a valid strategy spec from Claude API | Integration test with mock API |
| AC-6 | Generated spec can be parsed by the spec interpreter and produce a `strategy_fun` | Unit test: parse spec, evaluate against candle sequence |
| AC-7 | All 7 indicators compute correctly against known reference values | Unit tests with hand-calculated expected outputs |
| AC-8 | Condition expressions parse and evaluate correctly (comparisons, AND/OR, cross_above/below) | Unit tests covering all operators |
| AC-9 | A generated strategy can be backtested through the existing `Simulation.Runner` | Integration test: spec → interpreter → runner → results |
| AC-10 | Backtest results are persisted to PostgreSQL and displayed in LiveView | End-to-end test |
| AC-11 | Strategy status transitions follow the state machine rules | Unit test covering all valid/invalid transitions |
| AC-12 | An approved strategy can be deployed to paper trading via the dashboard | Integration test: approve → robot starts → trades appear |
| AC-13 | Live trading requires 24h paper minimum and user confirmation | Guard test + UI test |
| AC-14 | Trade history is recorded for both paper and live modes | Integration test |
| AC-15 | User authentication protects all dashboard routes | Auth test |
| AC-16 | WebSocket connects to Binance and receives kline close events | Integration test with mock WebSocket |
| AC-17 | Active strategies evaluate and emit signals in real-time on candle close | Integration test: candle event → signal broadcast |
| AC-18 | Trading Monitor shows live signals with < 1s latency from candle close | Manual verification + PubSub timing test |
| AC-19 | Signal feed displays: timestamp, strategy, symbol, side, price, triggering indicators | UI test |
| AC-20 | Orders are filtered/adjusted based on candle volume before execution | Unit test: large order + low volume → reduced qty or skip |
| AC-21 | Backtest results reflect volume-aware fills (not 100% fill assumption) | Integration test: compare with/without volume filter |
| AC-22 | Daily performance metrics are computed and stored for active strategies | Integration test: run N candles → performance row created |
| AC-23 | Performance tab shows cumulative PnL, drawdown, and rolling metrics | UI test |
| AC-24 | Volume-skipped signals are counted and visible in the dashboard | UI test: signal with low volume → counter increments |

## 13. Scope Boundaries

### In scope (v1)

- Single-user system
- Binance Spot only
- 7 core indicators (SMA, EMA, RSI, MACD, BB, ATR, VOL)
- LLM-driven strategy generation + improvement
- JSON strategy spec format with condition expression language
- Volume-aware order simulation and filtering
- Binance WebSocket for real-time kline data
- Real-time signal feed with volume context
- Paper and live trading via existing Robot + new LiveEvaluator
- PostgreSQL persistence via Ecto
- Phoenix LiveView dashboard (10 pages)
- Strategy state machine with safety guards
- Daily performance tracking with rolling metrics
- Strategy version lineage (parent/child tracking)
- AI cost tracking

### Out of scope (v1)

- Multi-user / team features
- Futures or margin trading
- Mobile app
- Strategy marketplace / sharing
- Automated stop-loss/take-profit execution (tracked in spec, not auto-executed; v2)
- Advanced ML-based strategies (LSTM, XGBoost)
- Genetic algorithm parameter optimization

## 14. Modules to Build (New)

| Module | Purpose |
|--------|---------|
| `CriptoTrader.Indicators.*` (7 modules) | Pure indicator computation functions |
| `CriptoTrader.StrategySpec.Parser` | Validate and parse JSON spec |
| `CriptoTrader.StrategySpec.Expression` | Parse and evaluate condition expressions |
| `CriptoTrader.StrategySpec.Interpreter` | Convert spec → `strategy_fun` for Runner/Robot |
| `CriptoTrader.StrategySpec.VolumeFilter` | Volume-aware order filtering and slippage |
| `CriptoTrader.AI.Client` | Claude API client (generate, improve, explain) |
| `CriptoTrader.AI.PromptBuilder` | Build prompts with context for Claude |
| `CriptoTrader.MarketData.WebSocket` | Binance WebSocket GenServer |
| `CriptoTrader.Strategy.LiveEvaluator` | Per-strategy GenServer for real-time evaluation |
| `CriptoTrader.Strategy.Supervisor` | DynamicSupervisor for LiveEvaluator processes |
| `CriptoTrader.Strategy.StateMachine` | Strategy lifecycle transitions and guards |
| `CriptoTrader.Performance.Tracker` | Daily performance rollup computation |
| `CriptoTrader.Repo` | Ecto repository |
| `CriptoTrader.Accounts.*` | User auth (Ecto schemas + context) |
| `CriptoTrader.Strategies.*` | Strategy Ecto schemas + context |
| `CriptoTraderWeb.*` | Phoenix endpoint, router, LiveView pages |

## 15. Modules Unchanged (Existing)

| Module | Purpose |
|--------|---------|
| `CriptoTrader.Simulation.Runner` | Deterministic backtest engine |
| `CriptoTrader.Trading.Robot` | Polling-based live/paper trading |
| `CriptoTrader.OrderManager` | Order submission with risk checks |
| `CriptoTrader.Risk` | Risk validation |
| `CriptoTrader.Paper.Orders` | Paper order execution |
| `CriptoTrader.Binance.*` | Binance REST API client |
| `CriptoTrader.MarketData.Candles` | REST candle fetching |
| `CriptoTrader.Strategy.Alternating` | Baseline strategy (kept as reference) |
| `CriptoTrader.Improvement.*` | Existing improvement loop (file-backed) |
| All existing Mix tasks | CLI commands |
