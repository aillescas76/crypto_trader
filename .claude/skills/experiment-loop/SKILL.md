---
name: experiment-loop
description: Autonomous strategy experiment loop — deep hypothesis research using parallel subagents, write, queue, run, extract learnings from every result
---

# Experiment Loop Protocol

Each iteration follows these steps in order. **Never skip steps. Never rush to testing.**

The most common mistake is moving to Step 6 (write strategy) before the hypothesis is truly sound. A weak hypothesis wastes a backtest. Spend the time here — subagents make it cheap to do thorough research in parallel.

---

## Step 1 — Situational Awareness

```bash
mix experiments.status
```

Read `priv/experiments/findings.json` and `priv/experiments/feedback.json`.

Note:
- Which experiments are pending / running / passed / failed
- PnL%, Sharpe, max drawdown vs baseline
- Failure patterns and success patterns
- Any unacknowledged user feedback

---

## Step 2 — Extract Learnings from ALL Completed Experiments

For every completed experiment (passed OR failed) without a finding, record one:

```bash
mix experiments.findings.add \
  --title "STRATEGY_NAME: concise insight" \
  --experiment EXP_ID \
  --tags tag1,tag2
```

**Failure tags:** `overfit`, `invalid-hypothesis`, `drawdown-issue`, `partial-signal`
**Pass tags:** `improvement-idea` (for follow-on hypotheses)

---

## Step 3 — Incorporate User Feedback

Read `priv/experiments/feedback.json`. For each `acknowledged: false` entry, adjust hypothesis direction, then acknowledge:

```elixir
CriptoTrader.Experiments.State.acknowledge_feedback("fbk-ID")
```

---

## Step 4 — Research New Strategy Ideas (Parallel Subagents)

Launch **3 parallel research agents** — one per mechanism category. Each agent independently searches the web and returns a structured brief. This runs in parallel; do NOT wait for one before launching the others.

**Agent prompt template** (customise the category per agent):

```
You are researching trading strategy ideas for a crypto spot trading bot.

Project context:
- 6 USDC pairs (BTC, ETH, SOL, BNB, ADA, XRP), 15-minute candles
- Pass criteria: beat buy-and-hold PnL% AND (Sharpe > baseline OR max_drawdown < 40%)
  on BOTH training (pre-2025-01-01) and validation (2025-01-01+) splits
- Existing strategies tried: [list from findings.json to avoid duplicates]

Your task: research **[CATEGORY]** trading strategies for crypto.

Categories to assign across the 3 agents:
  Agent 1: momentum / trend-following / breakout
  Agent 2: mean reversion / statistical arbitrage / pairs
  Agent 3: volatility / regime detection / macro/cycle

For your category:
1. WebSearch for recent papers (arXiv, SSRN) and practitioner writeups
2. Identify 2-3 specific, implementable ideas with named mechanisms
3. For each idea, answer:
   - What market inefficiency does it exploit?
   - Why hasn't it been arbitraged away in crypto?
   - What are the key parameters (keep it to ≤3)?
   - What conditions cause it to fail?
   - Any evidence it works on crypto specifically?

Return: a structured brief with 2-3 ranked ideas. Be specific — "buy when RSI < 30" is not enough; explain *why* that signal has edge.
```

After all 3 agents return, synthesise their findings. Shortlist the 1-2 most promising ideas that:
- Have a named mechanism with explained edge
- Build on prior findings (not repeating known failures)
- Cover an unexplored mechanism category

---

## Step 5 — Build a Sound Hypothesis (THE CRITICAL STEP)

**Do not proceed to Step 6 until this step is complete.**

Work through all sub-steps. Use subagents for the analytical heavy lifting.

### 5a — Mechanism Research Agent

For the shortlisted idea, launch a **dedicated mechanism research agent**:

```
You are analysing a trading strategy mechanism for a crypto spot bot.

Mechanism to analyse: [MECHANISM NAME AND BRIEF DESCRIPTION]

Available data: Binance archive candles for BTCUSDC, ETHUSDC, SOLUSDC,
BNBUSDC, ADAUSDC, XRPUSDC at 15m intervals from 2022-01-01 to 2024-12-31
(training period only). Candles are cached at:
  ~/.cripto_trader/archive_cache/

You can load candles in Elixir:
  mix run -e '
  {:ok, candles} = CriptoTrader.MarketData.ArchiveCandles.fetch(
    symbols: ["BTCUSDC"],
    interval: "15m",
    start_time: 1_640_995_200_000,
    end_time: 1_735_689_600_000,
    cache_dir: Path.join(System.user_home!(), ".cripto_trader/archive_cache")
  )
  candles["BTCUSDC"] |> length() |> IO.inspect(label: "candles")
  ' 2>/dev/null

Or write Python scripts to analyse the loaded data.

Your task:
1. Load a sample of training candles (BTCUSDC is enough to start)
2. Compute the raw signal for this mechanism (before any strategy logic)
3. Answer all of the following:
   a. How often does the entry signal fire per symbol per week on average?
   b. What is the raw edge (e.g. average next-candle return after signal)?
   c. Does the signal vary significantly across the 6 symbols?
   d. What parameter value looks most robust? Test ±20% around it.
   e. How does signal frequency/quality change across market regimes?
      - 2022 bear (Jan-Dec 2022): signal still firing? edge positive or negative?
      - 2023 recovery (Jan-Jun 2023): behaviour?
      - 2024 bull run (Jan-Dec 2024): behaviour?
   f. Estimate worst-case 3-month drawdown if we traded this signal naively

Write and run scripts. Show actual numbers, not estimates.

Return: a structured analysis report with all 6 questions answered, plus your
recommendation on whether to proceed and what parameter value to use.
```

**Gate:** If the agent's analysis shows no measurable edge, the signal fires < 2x/week per symbol, or the 2022 bear causes catastrophic drawdown with no fix — **abandon this idea and return to Step 4**. Do not proceed.

### 5b — Parallel Stress-Test Agents

If 5a shows a viable signal, launch **2 parallel stress-test agents**:

**Agent A — Regime and drawdown stress test:**
```
You are stress-testing a trading strategy signal for a crypto spot bot.

Signal description: [EXACT SIGNAL LOGIC from 5a]
Recommended parameter: [VALUE from 5a]
Training data: 2022-01-01 to 2024-12-31 (15m candles, cached at ~/.cripto_trader/archive_cache/)

Task: test the failure modes of this signal.

1. Simulate trading ONLY during the 2022 bear market (2022-01-01 to 2022-12-31)
   on BTCUSDC. What is the max drawdown? Does it exceed 40%?

2. If drawdown > 40% in the bear: design and test a trend filter that would
   reduce bear-market exposure. Propose the simplest filter that keeps drawdown < 40%.
   Test it. Show numbers.

3. Identify the single worst 3-month window in the training data for this signal.
   What happened? Is it an edge case or a systematic failure?

Return: drawdown in bear market, whether a filter is needed and what it is,
worst 3-month window and cause.
```

**Agent B — Parameter sensitivity and baseline comparison:**
```
You are stress-testing a trading strategy signal for a crypto spot bot.

Signal description: [EXACT SIGNAL LOGIC from 5a]
Recommended parameter: [VALUE from 5a]
Training data: 2022-01-01 to 2024-12-31 (15m candles, cached at ~/.cripto_trader/archive_cache/)

Task: test robustness and compare to baseline.

1. Test the signal with parameter values: [VALUE * 0.7], [VALUE * 0.85],
   [VALUE], [VALUE * 1.15], [VALUE * 1.3]
   For each: count trades, estimate win rate, estimate PnL direction.
   Does performance cliff-edge at any value, or is it gradual?

2. Simulate naive buy-and-hold on all 6 symbols over the training period.
   What is the approximate PnL%? This is the bar we must beat.

3. Given signal frequency from the prior analysis, estimate how many trades
   this strategy would generate over the full training period across 6 symbols.
   Is that enough for statistical significance?

Return: sensitivity table, buy-and-hold baseline PnL%, trade count estimate,
and your verdict on whether the signal is robust enough to proceed.
```

**Gate:** If Agent A shows uncontrollable drawdown and no viable filter, or Agent B shows the signal is not robust to parameter variation — **abandon and return to Step 4**.

### 5c — Write the Hypothesis Statement

Only after 5a and 5b complete successfully, write:

> *"[Market mechanism] creates a [direction] edge because [reason from 5a]. The signal fires approximately [N] times per symbol per week. Using parameter [VALUE], performance is stable across ±[X]% variation. It requires a [filter description] to limit bear-market exposure to < 40% drawdown. Expected to beat buy-and-hold (approx [BnH PnL]% in training) AND achieve Sharpe > baseline OR max_drawdown < 40% on both training (pre-2025) and validation (2025+) splits."*

Every blank must be filled from agent output. If any blank is empty, return to 5a.

Check `lib/cripto_trader/strategy/experiment/` for duplicates before proceeding.

---

## Step 6 — Write the Strategy

Direct translation of the hypothesis. No new ideas introduced here.

Create `lib/cripto_trader/strategy/experiment/YYYYMMDD_<concept>.ex`:

- Module: `CriptoTrader.Strategy.Experiment.YYYYMMDD<Concept>`
- Implements `new_state(symbols, opts)` and `signal(event, state)`
- Pure logic — no IO, no HTTP, no GenServer calls
- Parameters must exactly match those validated in Step 5a/5b

```elixir
defmodule CriptoTrader.Strategy.Experiment.YYYYMMDDMyIdea do
  @moduledoc "One-line description of hypothesis"

  def new_state(_symbols, opts \\ []) do
    %{
      # only parameters whose values were determined in Step 5a/5b
    }
  end

  def signal(%{symbol: symbol, candle: %{close: close}}, state) do
    {[], state}
  end

  def signal(_event, state), do: {[], state}
end
```

---

## Step 7 — Queue the Experiment

```bash
mix experiments.add \
  --strategy CriptoTrader.Strategy.Experiment.YYYYMMDDMyIdea \
  --hypothesis "Exact hypothesis text from Step 5c" \
  --symbols BTCUSDC,ETHUSDC,SOLUSDC,BNBUSDC,ADAUSDC,XRPUSDC \
  --interval 15m \
  --balance 10000
```

---

## Step 8 — Run if Queue is Small

If fewer than 3 pending experiments:

```bash
mix experiments.run --all-pending
```

Observe output carefully — results directly inform the next iteration.

---

## Step 9 — Update Memory

Save strategic insights (mechanism verdicts, parameter findings, regime behaviours) to `.claude/memory/` in the project. Build a cumulative model of what the market rewards.

---

## Subagent Dispatch Summary

| Step | Agents | Run |
|---|---|---|
| 4 | 3× research agents (momentum, mean-reversion, volatility/regime) | Parallel |
| 5a | 1× mechanism deep-dive agent | Sequential (gates 5b) |
| 5b | 2× stress-test agents (drawdown/regime + sensitivity/baseline) | Parallel |

Total per iteration: up to 6 agent dispatches, most of them parallel. The main conversation synthesises results and makes go/no-go decisions at each gate.

---

## Anti-Cheat Rules (MANDATORY)

1. **Fix parameters before running.** Values must come from Step 5a/5b analysis. Never adjust after seeing validation results.
2. **No grid search on full dataset.** All exploratory analysis uses training data (before 2025-01-01) only.
3. **Validation split is held-out.** Never touched during hypothesis development.
4. **One hypothesis, one experiment.** No running variants and cherry-picking.
5. **Hypothesis text must be complete.** All blanks in Step 5c filled before queuing.
6. **Always record a finding** for every completed experiment.
7. **Overfitting flag.** Training pass + validation fail = overfit. Do not reuse.

---

## Pass Criteria (Reference)

An experiment PASSES if on BOTH training AND validation splits:
- Strategy PnL% > BuyAndHold PnL%
- AND (Strategy Sharpe > BuyAndHold Sharpe OR Strategy max_drawdown < 40%)
