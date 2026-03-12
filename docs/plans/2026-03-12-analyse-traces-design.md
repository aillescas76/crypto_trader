# Design: `/analyse-traces` Skill

**Date:** 2026-03-12
**Status:** Approved

## Objective

Provide on-demand retrospective analysis of experiment loop sessions to identify concrete improvements in the strategy discovery pipeline. The goal is finding strategies that beat buy-and-hold on PnL% AND (Sharpe > baseline OR max_drawdown < 40%) on both training and validation splits.

## Scope

Only sessions containing `mix experiments.*` commands or `/loop` skill invocations. General coding sessions are ignored.

## Invocation

```
/analyse-traces                     # last 10 experiment sessions
/analyse-traces --since 2026-03-01  # all experiment sessions since date
/analyse-traces --session <ID>      # one specific session
/analyse-traces --last 3            # last N experiment sessions
```

## Approach

**A — Signal extraction script + Claude interpretation.**

A Python script parses JSONL trace files and emits a structured JSON report of objective signals. Claude then reads the report and writes qualitative analysis and improvement suggestions.

## Signals Extracted

| Dimension | Signals |
|---|---|
| Hypothesis quality | Hypothesis texts from `experiments.add` calls; whether they reference prior findings |
| Pipeline velocity | Time from `experiments.add` → `experiments.run` → `experiments.status` showing result |
| Pass rate trend | `mix experiments.status` outputs over time; pass/fail counts and which split failed |
| Learning extraction | `experiments.findings.add` calls vs completed experiments; failure tags present? |
| Strategy diversity | Strategy module names written; mechanism keywords in hypothesis texts |
| Feedback incorporation | `feedback.json` acknowledgement timing; feedback keywords appearing in later hypotheses |
| Anti-cheat signals | Same strategy re-queued with different params within same session; individual `--id` runs vs `--all-pending` |

## Output

Written to `priv/experiments/trace_analysis/YYYY-MM-DD[-N].md`. Sections:

1. Sessions Analysed
2. Pass Rate Trend
3. Hypothesis Quality
4. Pipeline Velocity
5. Learning Extraction
6. Strategy Diversity
7. Feedback Loop
8. Anti-Cheat Signals
9. **Concrete Improvement Suggestions** (the actionable output)

Committed with message `docs: add experiment loop trace analysis YYYY-MM-DD`.

## Implementation

Skill file: `.claude/skills/analyse-traces/SKILL.md`
Trace source: `~/.claude/projects/-home-aic-code-cripto-trader/*.jsonl`
Output dir: `priv/experiments/trace_analysis/`
