---
name: experiment-loop
description: Autonomous strategy experiment loop — deep hypothesis research, write, queue, run, extract learnings from every result
---

# Experiment Loop Protocol

Each iteration follows these steps in order. **Never skip steps. Never rush to testing.**

The most common mistake is moving to Step 6 (write strategy) before the hypothesis is truly sound. A weak hypothesis wastes a backtest. Spend the time here.

---

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

---

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

---

## Step 3 — Incorporate User Feedback

Read `priv/experiments/feedback.json`. For each entry where `acknowledged: false`:

- Adjust hypothesis direction accordingly
- After queuing an experiment that addresses the feedback, acknowledge it:
  ```elixir
  CriptoTrader.Experiments.State.acknowledge_feedback("fbk-ID")
  ```

---

## Step 4 — Research New Strategy Ideas

Use `WebSearch` to find:
- Academic papers (arXiv, SSRN): mean reversion, momentum, volatility targeting, regime detection, carry
- Practitioner blogs: crypto-specific alpha, funding rates, liquidation cascades, on-chain signals
- Ideas that build on observed successes or address observed failure modes

Prefer ideas with:
- A named, studied market mechanism (not just "buy when RSI is low")
- Evidence of working in crypto markets specifically
- Clear entry/exit logic with a small number of parameters fixable before backtesting

---

## Step 5 — Build a Sound Hypothesis (THE CRITICAL STEP)

**Do not proceed to Step 6 until this step is complete.**

A sound hypothesis requires evidence, not just intuition. Work through all of the following before writing a single line of strategy code.

### 5a — Understand the Market Mechanism

Ask and answer these questions in your thinking:
- What market inefficiency or structural edge does this idea exploit?
- Why does this inefficiency exist? (Who is on the other side of the trade?)
- Why has it not been fully arbitraged away in crypto?
- In what market regimes (trending, ranging, high-vol, low-vol) does it work best?
- In what conditions would it fail catastrophically?

### 5b — Analyse Historical Data

**Write and run exploratory scripts** before committing to a strategy. You have full access to cached candle data. Use it.

Examples of useful analysis:
```bash
# Load candles and compute the raw signal before any strategy code
mix run -e '
{:ok, candles} = CriptoTrader.MarketData.ArchiveCandles.fetch(
  symbols: ["BTCUSDC", "ETHUSDC"],
  interval: "15m",
  start_time: 1_640_995_200_000,
  end_time: 1_735_689_600_000,
  cache_dir: Path.join(System.user_home!(), ".cripto_trader/archive_cache")
)
IO.inspect(length(candles["BTCUSDC"]), label: "BTCUSDC candles")
' 2>/dev/null
```

Or write a Python analysis script for more complex exploration:
```bash
python3 << PYEOF
import json, subprocess, statistics
# ... analyse candle distributions, signal frequency, edge cases
PYEOF
```

**Questions your analysis should answer:**
- How often does the entry signal fire? (too rare = no trades; too frequent = noise)
- What is the raw signal-to-noise ratio before any strategy logic?
- Does the edge hold across all 6 symbols, or only some?
- Does the edge hold in the training period (pre-2025) specifically?
- What happens during the 2022 bear market? The 2024 bull run? Sideways periods?
- Is there a parameter that makes the signal robust, or is it only visible in hindsight?

### 5c — Stress-Test the Hypothesis

Before writing strategy code, explicitly try to falsify your own hypothesis:

1. **Regime test**: does the signal reverse or disappear in bear markets? If so, a trend filter is mandatory — design it now, not after the backtest fails.
2. **Parameter sensitivity**: pick your intended parameter value. If moving it ±20% completely changes the result, the signal is not robust.
3. **Drawdown scenario**: identify the worst 3-month period in the training data. How would this strategy behave? Is drawdown likely to exceed 40%?
4. **Baseline comparison**: even if the signal is real, does it beat a passive buy-and-hold of the same symbols? Crypto has strong beta — the bar is higher than just "positive returns."

### 5d — Write the Hypothesis Statement

Only after 5a–5c, write the hypothesis as:

> *"[Market mechanism] creates a [direction] edge because [reason]. The signal fires approximately [frequency] per symbol per week. It is robust to parameter variation of ±[X]%. It performs well in [regimes] and should be filtered out in [conditions]. Expected to beat buy-and-hold PnL% AND achieve Sharpe > baseline OR max_drawdown < 40% on both training (pre-2025) and validation (2025+) splits."*

If you cannot fill in all the blanks, you do not yet have a sound hypothesis. Go back to 5b.

Check `lib/cripto_trader/strategy/experiment/` for duplicates before proceeding.

---

## Step 6 — Write the Strategy

Only now write the strategy code. The implementation should be a direct translation of the hypothesis — no surprises, no new ideas introduced here.

Create `lib/cripto_trader/strategy/experiment/YYYYMMDD_<concept>.ex`:

Requirements:
- Module: `CriptoTrader.Strategy.Experiment.YYYYMMDD<Concept>`
- Must implement `new_state(symbols, opts) :: state()` and `signal(event, state) :: {[orders], state()}`
- Pure logic — no IO, no HTTP, no GenServer calls
- Parameters must match those analysed in Step 5b — no new values introduced here

```elixir
defmodule CriptoTrader.Strategy.Experiment.YYYYMMDDMyIdea do
  @moduledoc "One-line description of hypothesis"

  def new_state(_symbols, opts \\ []) do
    %{
      # only parameters whose values were determined in Step 5b/5c
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
  --hypothesis "Exact hypothesis text from Step 5d" \
  --symbols BTCUSDC,ETHUSDC,SOLUSDC,BNBUSDC,ADAUSDC,XRPUSDC \
  --interval 15m \
  --balance 10000
```

---

## Step 8 — Run if Queue is Small

If there are fewer than 3 pending experiments:

```bash
mix experiments.run --all-pending
```

Observe output carefully — results directly inform the next iteration.

---

## Step 9 — Update Memory

After the loop, save strategic insights to `.claude/memory/` in the project. Continuously build a model of what works and what doesn't in these markets.

---

## Anti-Cheat Rules (MANDATORY)

**Never violate these.**

1. **Fix parameters before running.** Values must come from Step 5b analysis, not guesswork. Never adjust after seeing validation results.
2. **No grid search on full dataset.** Exploratory analysis in Step 5b uses training data only (before 2025-01-01). Never look at validation candles during hypothesis development.
3. **Validation split is held-out.** Treat it as unseen until the experiment executes.
4. **One hypothesis, one experiment.** Do not run multiple variants and cherry-pick.
5. **Record reasons before running.** Hypothesis text must explain why the strategy should work, with signal frequency and regime analysis filled in.
6. **Always record a finding** for every completed experiment — failures teach as much as passes.
7. **Overfitting flag.** Training pass + validation fail = overfit. Do not reuse that parameterization.

---

## Pass Criteria (Reference)

An experiment PASSES if on BOTH training AND validation splits:
- Strategy PnL% > BuyAndHold PnL%
- AND (Strategy Sharpe > BuyAndHold Sharpe OR Strategy max_drawdown < 40%)
