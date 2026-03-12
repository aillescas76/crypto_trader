---
name: experiment-loop
description: Autonomous strategy experiment loop — research, write, queue, run, extract learnings from every result
---

# Experiment Loop Protocol

Each iteration follows these steps in order. Never skip steps.

## Step 1 — Situational Awareness

```bash
mix experiments.status
```

Read `priv/experiments/findings.json` and `priv/experiments/feedback.json`.

Note:
- Which experiments are pending / running / passed / failed
- PnL%, Sharpe, max drawdown of recent completions vs baseline
- Failure patterns: what mechanisms keep failing and why
- Success patterns: which signals, filters, or regimes contributed to passes
- Any unacknowledged user feedback

## Step 2 — Extract Learnings from ALL Completed Experiments

For EVERY completed experiment (passed OR failed) that has no corresponding finding, record a finding. **Every result teaches something.**

```bash
mix experiments.findings.add \
  --title "STRATEGY_NAME: concise insight" \
  --experiment EXP_ID \
  --tags tag1,tag2
```

### Analyzing failures
- Training pass + validation fail → `overfit` — what parameter was overfit?
- Both splits fail → `invalid-hypothesis` — what assumption was wrong?
- Drawdown exceeded 40% → `drawdown-issue` — which market period caused it?
- PnL failed but Sharpe improved → `partial-signal` — worth iterating with better sizing

### Analyzing passes
Ask: **what can be improved?**
- Could position sizing increase returns further?
- Could a complementary strategy stack on top (e.g. add a trend filter)?
- Could the same mechanism work at a different timeframe or on different symbols?
- Which market regime drove the alpha — trending, ranging, volatile? Can that be detected explicitly?

Record these as separate findings tagged `improvement-idea` for use in next hypotheses.

## Step 3 — Incorporate User Feedback

Read `priv/experiments/feedback.json`. For each entry where `acknowledged: false`:

- Adjust hypothesis direction accordingly
- After queuing an experiment that addresses the feedback, acknowledge it in IEx:
  ```elixir
  CriptoTrader.Experiments.State.acknowledge_feedback("fbk-ID")
  ```

## Step 4 — Research New Strategy Ideas

Use `WebSearch` to find:
- Academic papers (arXiv, SSRN): mean reversion, momentum, volatility targeting, regime detection, carry
- Practitioner blogs: crypto-specific alpha, funding rates, liquidation cascades, on-chain signals
- Ideas that build on observed successes or address observed failure modes

Prefer ideas with:
- Clear entry/exit logic implementable as `signal(event, state) -> {[orders], new_state}`
- Parameters fixable before backtesting (no post-hoc tuning)
- Evidence of working in crypto markets specifically

## Step 5 — Form a Falsifiable Hypothesis

Write as: *"If [mechanism], then [strategy] will beat buy-and-hold PnL% AND achieve Sharpe > baseline OR max_drawdown < 40% on both training (pre-2025) and validation (2025+) splits."*

Explicitly connect the hypothesis to what was learned in Steps 2–4. Good hypotheses are informed hypotheses.

Check `lib/cripto_trader/strategy/experiment/` for duplicates before proceeding.

## Step 6 — Write the Strategy

Create `lib/cripto_trader/strategy/experiment/YYYYMMDD_<concept>.ex` (use today's date).

Requirements:
- Module: `CriptoTrader.Strategy.Experiment.YYYYMMDD<Concept>`
- Must implement:
  - `new_state(symbols, opts) :: state()`
  - `signal(event, state) :: {[orders], state()}`
- Pure logic — no IO, no HTTP, no GenServer calls
- 50–150 lines is typical

Skeleton:
```elixir
defmodule CriptoTrader.Strategy.Experiment.YYYYMMDDMyIdea do
  @moduledoc "One-line description of hypothesis"

  def new_state(_symbols, opts \\ []) do
    %{prices: %{}}
  end

  def signal(%{symbol: symbol, candle: %{close: close}}, state) do
    {[], state}
  end

  def signal(_event, state), do: {[], state}
end
```

## Step 7 — Queue the Experiment

```bash
mix experiments.add \
  --strategy CriptoTrader.Strategy.Experiment.YYYYMMDDMyIdea \
  --hypothesis "Exact hypothesis text from Step 5" \
  --symbols BTCUSDC,ETHUSDC,SOLUSDC,BNBUSDC,ADAUSDC,XRPUSDC \
  --interval 15m \
  --balance 10000
```

## Step 8 — Run if Queue is Small

If there are fewer than 3 pending experiments:

```bash
mix experiments.run --all-pending
```

This runs synchronously. Observe output carefully — results directly inform the next iteration.

## Step 9 — Update Memory

After the loop, save strategic insights to `.claude/memory/` in the project. Continuously build a model of what works and what doesn't in these markets.

---

## Anti-Cheat Rules (MANDATORY)

**Never violate these.**

1. **Fix parameters before running.** Choose values from theory and training data only. Never adjust after seeing validation results.
2. **No grid search on full dataset.** Tune on training split (before 2025-01-01) only.
3. **Validation split is held-out.** Treat it as unseen until the experiment executes.
4. **One hypothesis, one experiment.** Do not run multiple variants and cherry-pick.
5. **Record reasons before running.** Hypothesis text must explain why the strategy should work.
6. **Always record a finding** for every completed experiment — failures teach as much as passes.
7. **Overfitting flag.** Training pass + validation fail = overfit. Do not reuse that parameterization.

---

## Pass Criteria (Reference)

An experiment PASSES if on BOTH training AND validation splits:
- Strategy PnL% > BuyAndHold PnL%
- AND (Strategy Sharpe > BuyAndHold Sharpe OR Strategy max_drawdown < 40%)
