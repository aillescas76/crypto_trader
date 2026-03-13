---
name: experiment-loop
description: Autonomous strategy experiment loop — deep hypothesis research using parallel subagents, write, queue, run, extract learnings from every result
---

# Experiment Loop Protocol

Each iteration follows these steps in order. **Never skip steps. Never rush to testing.**

The most common mistake is moving to Step 6 (write strategy) before the hypothesis is truly sound. A weak hypothesis wastes a backtest. Spend the time here — subagents make it cheap to do thorough research in parallel.

---

## Step 0 — Resume Check (ALWAYS FIRST)

```bash
mix experiments.context
```

**If the output shows `Status: in_progress`:**
- Note `current_step` and `completed_steps` from the SESSION section
- Print: `"Resuming from Step [current_step] — restoring saved research"`
- Restore prior agent outputs by reading each completed step's data (do NOT re-run completed agents):
  ```bash
  mix experiments.session.data --step 4   # if "4" in completed_steps
  mix experiments.session.data --step 5a  # if "5a" in completed_steps
  mix experiments.session.data --step 5b  # if "5b" in completed_steps
  ```
- Skip directly to `current_step` — do not repeat any step already in `completed_steps`

**If the output shows `No active session` or `Status: completed`:**
- Print: `"No in-progress session. Starting fresh."`
- Continue to Step 1 as normal

---

## Step 1 — Situational Awareness

```bash
mix experiments.session announce --step 1
```

Read `.claude/context/experiment-loop.md` for API reference, constants, and the strategy skeleton before doing anything else.

The `mix experiments.context` output from Step 0 already contains everything you need:
- SESSION: current step, hypothesis candidate, completed steps
- EXPERIMENTS: all experiments with status, PnL%, verdict
- FINDINGS: accumulated learnings and tags
- FEEDBACK: unacknowledged feedback (act on these in Step 3)

Note from the output:
- Which experiments are pending / running / passed / failed
- Failure patterns and success patterns
- Any unacknowledged feedback (listed first under FEEDBACK)

---

## Step 2 — Extract Learnings from ALL Completed Experiments

For every completed experiment (passed OR failed) without a finding, record one with a structured body:

```bash
mix experiments.findings.add \
  --title "STRATEGY_NAME: concise insight" \
  --experiment EXP_ID \
  --tags tag1,tag2 \
  --body "**Mechanism verdict:** viable-signal / no-edge / overfit
**Per-trade edge:** WR X% | PF X.XX | avg hold Xh
**Why it failed pass criteria:** [specific numeric gap, e.g. 'train PnL 8% vs BnH 42% — only in-market 10% of time']
**Regime behaviour:** bear-2022: ... | recovery-2023: ... | bull-2024: ...
**Generalizable lesson:** [one principle applicable beyond this strategy]
**Next directions:** 1. ... 2. ..."
```

**Failure tags:** `overfit`, `invalid-hypothesis`, `drawdown-issue`, `partial-signal`
**Pass tags:** `improvement-idea` (for follow-on hypotheses)

Every blank in the body template must be filled from actual experiment results. Do not leave placeholders.

Then, if the finding contains a generalizable lesson (applicable to future strategies, not just this one), also record it as a principle:

```bash
mix experiments.principles.add \
  --principle "Concise generalizable truth about market mechanics or strategy design" \
  --evidence EXP_ID \
  --tags tag1,tag2
```

Principles accumulate into a persistent knowledge base surfaced at the start of every future loop. Only record principles that would constrain or guide future hypothesis generation — not experiment-specific observations.

**After recording principles — check for stalled investigations:**

Review the INVESTIGATIONS section from `mix experiments.context`. For each ACTIVE investigation where the output shows a stall warning (`⚠ STALL`), **automatically freeze it**:

```bash
mix experiments.investigation freeze --id INV_ID
```

This moves it to `frozen` status. The loop will skip it. A human reviews it at `/investigations` and decides to Resume or Discard. Do NOT discard automatically — the human must decide.

---

## Step 3 — Incorporate User Feedback

From the FEEDBACK section of `mix experiments.context` output (Step 0), act on each UNACKNOWLEDGED entry, then acknowledge:

```bash
mix experiments.feedback.acknowledge --id fbk-ID
```

---

## Step 4 — Build the Round's Candidate List (Parallel Subagents)

```bash
mix experiments.session announce --step 4
```

**This step fans out up to 3 subagents in parallel** — one per candidate slot. Read the INVESTIGATIONS section from the context output to determine the mix of slots.

### Slot allocation (max 3 total)

1. **Micro-variant slots**: For each ACTIVE (not frozen) investigation where `in_flight: false` and `streak < 3` — fill one slot. Cap at 2 micro-variant slots. Skip any `frozen` investigations entirely.
2. **New-concept slot**: If total active investigations < 3, fill one slot with a fresh concept. If all 3 slots are taken by micro-variants, skip the new-concept slot this round.

### Step 4-A — New-Concept Subagent

**Model: `sonnet`** — web research + idea quality evaluation requires reasoning.

Use when a new-concept slot is available. The agent prompt (assign one category per agent):

```
You are researching trading strategy ideas for a crypto spot trading bot.

Project context:
- 6 USDC pairs (BTC, ETH, SOL, BNB, ADA, XRP), 15-minute candles
- Pass criteria: beat buy-and-hold PnL% AND (Sharpe > baseline OR max_drawdown < 40%)
  on BOTH training (pre-2025-01-01) and validation (2025-01-01+) splits
- Existing strategies tried: [list from findings.json to avoid duplicates]
- Established principles (do NOT contradict these — they are empirically validated constraints):
  [paste PRINCIPLES section from `mix experiments.context` output]

Your task: research **[CATEGORY]** trading strategies for crypto.
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

Return: a structured brief with 2-3 ranked ideas. Be specific — explain *why* the signal has edge.
```

### Step 4-B — Micro-Variant Subagent

**Model: `haiku`** — simple task: read prior results, identify one unused lever, propose one change.

Use for each ACTIVE investigation being advanced. The agent prompt:

```
You are advancing an ongoing line of strategy research for a crypto spot trading bot.

Investigation: "[investigation name]"
Concept: "[investigation concept]"

Prior experiments in this investigation (oldest to newest):
[paste the experiment list from the INVESTIGATIONS section, including PnL%, verdict, and findings]

Your task:
1. Identify the single most promising improvement lever that has NOT been tried yet.
   Focus on ONE of: position sizing, signal threshold, hold duration, entry/exit filter,
   trend regime filter, or indicator parameter.
2. Propose a specific, concrete micro-variant: state exactly what changes vs the prior
   strategy and what improvement you expect (and why).
3. Keep the change minimal — one lever at a time.

Do NOT re-derive the signal from scratch. The mechanism is validated. Find the gap.

Return: one micro-variant description with the exact parameter change and rationale.
```

### After all agents return

For each result, register the candidate in the session:

```bash
# For a micro-variant:
mix experiments.session add-candidate \
  --name "<StrategyName v2>" \
  --investigation-id INV_ID \
  --description "<one-sentence change: e.g. 'hold_candles increased from 8 to 16 to capture full reversal'>"

# For a new concept:
mix experiments.session add-candidate \
  --name "<ConceptName>" \
  --description "<one paragraph summary>"
```

**Checkpoint — save progress now.**

```bash
mix experiments.session.data --step 4 --file /tmp/step4_briefs.md
mix experiments.session checkpoint --step 4
```

For new-concept candidates, continue to Step 5. For micro-variant candidates, **skip directly to Step 6** — the mechanism is already validated.

---

## Step 5 — Build Sound Hypotheses (NEW CONCEPTS ONLY)

**Only run Steps 5a/5b/5c for new-concept candidates. Micro-variants skip to Step 6.**

Work through all sub-steps for each new concept. Use subagents for the analytical heavy lifting.

### 5a — Mechanism Research Agent

For the shortlisted idea, launch a **dedicated mechanism research agent** using **`opus`** — this is the critical gate; code execution + statistical analysis on real data; wrong call here wastes a backtest:

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

**Gate:** If the agent's analysis shows no measurable edge, the signal fires < 2x/week per symbol, or the 2022 bear causes catastrophic drawdown with no fix — **abandon this idea and return to Step 4**:

```bash
mix experiments.session announce --step 4
```

Do not proceed.

**Checkpoint — save progress now.**

Write the full analysis report to `/tmp/step5a_analysis.md`, then save via Elixir:

```bash
mix experiments.session.data --step 5a --file /tmp/step5a_analysis.md
mix experiments.session checkpoint --step 5a
mix experiments.session announce --step 5b
```

### 5b — Parallel Stress-Test Agents

If 5a shows a viable signal, launch **2 parallel stress-test agents** using **`sonnet`** — backtesting + filter design + parameter sweeps:

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

**Gate:** If Agent A shows uncontrollable drawdown and no viable filter, or Agent B shows the signal is not robust to parameter variation — **abandon and return to Step 4**:

```bash
mix experiments.session announce --step 4
```

**Checkpoint — save progress now.**

Write the full stress-test results (both agents) to `/tmp/step5b_results.md`, then save via Elixir:

```bash
mix experiments.session.data --step 5b --file /tmp/step5b_results.md
mix experiments.session checkpoint --step 5b
mix experiments.session announce --step 5c
```

### 5c — Write the Hypothesis Statement

Only after 5a and 5b complete successfully, write:

> *"[Market mechanism] creates a [direction] edge because [reason from 5a]. The signal fires approximately [N] times per symbol per week. Using parameter [VALUE], performance is stable across ±[X]% variation. It requires a [filter description] to limit bear-market exposure to < 40% drawdown. Expected to beat buy-and-hold (approx [BnH PnL]% in training) AND achieve Sharpe > baseline OR max_drawdown < 40% on both training (pre-2025) and validation (2025+) splits."*

Every blank must be filled from agent output. If any blank is empty, return to 5a.

Check `lib/cripto_trader/strategy/experiment/` for duplicates before proceeding.

**Checkpoint — save progress now.**

```bash
mix experiments.session checkpoint --step 5c
mix experiments.session announce --step 6
```

---

## Step 6 — Write the Strategies

Write one strategy file per candidate from Step 4 (both micro-variants and new concepts). Work sequentially.

For each candidate, create `lib/cripto_trader/strategy/experiment/YYYYMMDD_<concept>.ex`:

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

## Step 7 — Queue the Experiments

Queue one experiment per candidate. For **micro-variants**, link to their investigation. For **new concepts**, create an investigation first then link.

```bash
# New concept — create investigation first:
mix experiments.investigation create \
  --name "<ConceptName>" \
  --concept "<one sentence rationale>" \
  [--parent ORIGINAL_EXP_ID]

# Queue for new concept (use the INV_ID printed above):
mix experiments.add \
  --strategy CriptoTrader.Strategy.Experiment.YYYYMMDDMyIdea \
  --hypothesis "Exact hypothesis text from Step 5c" \
  --symbols BTCUSDC,ETHUSDC,SOLUSDC,BNBUSDC,ADAUSDC,XRPUSDC \
  --interval 15m \
  --balance 10000 \
  --investigation INV_ID

# Queue for micro-variant (investigation already exists):
mix experiments.add \
  --strategy CriptoTrader.Strategy.Experiment.YYYYMMDDMyVariant \
  --hypothesis "Exact micro-variant hypothesis" \
  --symbols BTCUSDC,ETHUSDC,SOLUSDC,BNBUSDC,ADAUSDC,XRPUSDC \
  --interval 15m \
  --balance 10000 \
  --investigation INV_ID
```

Repeat for all candidates this round.

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

**Clear the session checkpoint** — iteration is complete:

```bash
mix experiments.session complete
```

---

## Subagent Dispatch Summary

| Step | Agents | Model | Run |
|---|---|---|---|
| 4-A | New-concept research (up to 1) | `sonnet` | Parallel with 4-B |
| 4-B | Micro-variant analysis (up to 2) | `haiku` | Parallel with 4-A |
| 5a | Mechanism deep-dive (new concepts only) | `opus` | Sequential (gates 5b) |
| 5b | 2× stress-test agents (new concepts only) | `sonnet` | Parallel |

Per round: up to 3 Step-4 dispatches + up to 3 Step-5 dispatches (only for new concepts). Micro-variants skip Step 5 entirely. The main conversation synthesises results and makes go/no-go decisions at each gate.

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
