---
name: analyse-traces
description: Analyse Claude Code experiment loop session traces to find concrete improvements in the strategy discovery pipeline
---

# Analyse Traces

Retrospective analysis of experiment loop sessions. Identifies what's working, what's blocking progress, and produces a dated improvement report in `priv/experiments/trace_analysis/`.

**Objective lens:** every suggestion must move us toward finding strategies that pass both training (pre-2025) and validation (2025+) splits on PnL% AND (Sharpe > baseline OR max_drawdown < 40%).

---

## Step 1 — Parse Arguments

Check if the user provided flags after `/analyse-traces`:

| Flag | Meaning |
|---|---|
| *(none)* | Last 10 experiment sessions |
| `--last N` | Last N experiment sessions |
| `--since YYYY-MM-DD` | All experiment sessions since that date |
| `--session <ID>` | One specific session by ID |

The project trace directory is:
```
~/.claude/projects/-home-aic-code-cripto-trader/
```

---

## Step 2 — Extract Signals (Python script)

Write and run the following extraction script via Bash. It filters to experiment-related sessions and emits a JSON report.

```bash
python3 << 'PYEOF'
import json, os, sys, re
from pathlib import Path
from datetime import datetime, timezone
from collections import defaultdict

TRACE_DIR = Path.home() / ".claude/projects/-home-aic-code-cripto-trader"
EXPERIMENTS_FILE = Path("priv/experiments/experiments.json")
FINDINGS_FILE = Path("priv/experiments/findings.json")
FEEDBACK_FILE = Path("priv/experiments/feedback.json")

# --- Parse scope from env (set by Claude before running) ---
LAST_N    = int(os.environ.get("TRACES_LAST_N", "10"))
SINCE     = os.environ.get("TRACES_SINCE", "")       # YYYY-MM-DD
SESSION   = os.environ.get("TRACES_SESSION", "")     # specific session ID

def load_jsonl(path):
    records = []
    try:
        with open(path) as f:
            for line in f:
                try: records.append(json.loads(line))
                except: pass
    except FileNotFoundError:
        pass
    return records

def is_experiment_session(records):
    """True if session contains mix experiments.* commands or /loop skill."""
    for r in records:
        if r.get("type") == "assistant":
            for block in r.get("message", {}).get("content", []):
                if not isinstance(block, dict): continue
                if block.get("type") == "tool_use":
                    name = block.get("name", "")
                    inp  = block.get("input", {})
                    if name == "Bash":
                        cmd = str(inp.get("command", ""))
                        if re.search(r"mix experiments\.", cmd): return True
                    if name == "Skill" and "loop" in str(inp.get("skill", "")).lower():
                        return True
    return False

def extract_tool_calls(records):
    calls = []
    for r in records:
        if r.get("type") == "assistant":
            ts = r.get("timestamp", "")
            for block in r.get("message", {}).get("content", []):
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    calls.append({
                        "ts": ts,
                        "tool": block.get("name"),
                        "input": block.get("input", {})
                    })
    return calls

def extract_user_messages(records):
    msgs = []
    for r in records:
        if r.get("type") == "user":
            content = r.get("message", {}).get("content", "")
            if isinstance(content, list):
                text = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
            else:
                text = str(content)
            text = text.strip()
            if len(text) > 3 and not text.startswith("<"):
                msgs.append({"ts": r.get("timestamp", ""), "text": text})
    return msgs

def analyse_session(session_id, records):
    timestamps = [r["timestamp"] for r in records if r.get("timestamp")]
    duration_min = 0
    if len(timestamps) >= 2:
        fmt = "%Y-%m-%dT%H:%M:%S"
        try:
            t0 = datetime.fromisoformat(timestamps[0].replace("Z",""))
            t1 = datetime.fromisoformat(timestamps[-1].replace("Z",""))
            duration_min = round((t1 - t0).total_seconds() / 60, 1)
        except: pass

    tool_calls  = extract_tool_calls(records)
    user_msgs   = extract_user_messages(records)
    bash_cmds   = [t for t in tool_calls if t["tool"] == "Bash"]
    skills_used = [t["input"].get("skill","") for t in tool_calls if t["tool"] == "Skill"]

    # Experiment commands
    exp_cmds = [c for c in bash_cmds if re.search(r"mix experiments\.", str(c["input"].get("command","")))]

    # Hypotheses queued (experiments.add calls)
    hypotheses = []
    for c in bash_cmds:
        cmd = str(c["input"].get("command",""))
        if "experiments.add" in cmd:
            hyp = re.search(r'--hypothesis\s+"([^"]+)"', cmd)
            strat = re.search(r'--strategy\s+(\S+)', cmd)
            hypotheses.append({
                "ts": c["ts"],
                "text": hyp.group(1) if hyp else "",
                "strategy": strat.group(1) if strat else ""
            })

    # Findings added
    findings_added = []
    for c in bash_cmds:
        cmd = str(c["input"].get("command",""))
        if "experiments.findings.add" in cmd:
            title = re.search(r'--title\s+"([^"]+)"', cmd)
            exp   = re.search(r'--experiment\s+(\S+)', cmd)
            tags  = re.search(r'--tags\s+(\S+)', cmd)
            findings_added.append({
                "ts": c["ts"],
                "title": title.group(1) if title else "",
                "experiment_id": exp.group(1) if exp else "",
                "tags": tags.group(1) if tags else ""
            })

    # Strategy files written
    strategy_files = [
        t["input"].get("file_path","")
        for t in tool_calls
        if t["tool"] in ("Write","Edit")
        and "strategy/experiment" in str(t["input"].get("file_path",""))
    ]

    # User corrections: short messages or correction keywords
    corrections = [
        m for m in user_msgs
        if len(m["text"]) < 30
        or re.search(r"\b(fix|wrong|no,|remove|change|not that|instead|undo|revert)\b", m["text"].lower())
    ]

    # Anti-cheat: same strategy queued multiple times in one session
    strategy_counts = defaultdict(int)
    for h in hypotheses:
        if h["strategy"]:
            strategy_counts[h["strategy"]] += 1
    repeated_strategies = {k: v for k, v in strategy_counts.items() if v > 1}

    # Rework: consecutive compile/test bash calls without a user turn
    rework_loops = 0
    last_was_compile = False
    for r in records:
        if r.get("type") == "user":
            last_was_compile = False
        elif r.get("type") == "assistant":
            for block in r.get("message",{}).get("content",[]):
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    if block.get("name") == "Bash":
                        cmd = str(block.get("input",{}).get("command",""))
                        if re.search(r"mix (compile|test)", cmd):
                            if last_was_compile:
                                rework_loops += 1
                            last_was_compile = True
                        else:
                            last_was_compile = False

    branch = next((r.get("gitBranch","") for r in records if r.get("gitBranch")), "")
    date   = timestamps[0][:10] if timestamps else "?"

    return {
        "session_id":           session_id,
        "date":                 date,
        "branch":               branch,
        "duration_min":         duration_min,
        "total_tool_calls":     len(tool_calls),
        "bash_calls":           len(bash_cmds),
        "experiment_commands":  len(exp_cmds),
        "skills_used":          skills_used,
        "hypotheses":           hypotheses,
        "findings_added":       findings_added,
        "strategy_files":       list(set(strategy_files)),
        "corrections":          [c["text"] for c in corrections],
        "repeated_strategies":  repeated_strategies,
        "rework_loops":         rework_loops,
        "user_message_count":   len(user_msgs),
    }

# --- Find and filter session files ---
all_files = sorted(TRACE_DIR.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)

candidate_files = []
for p in all_files:
    if SESSION and SESSION not in p.name:
        continue
    records = load_jsonl(p)
    if not is_experiment_session(records):
        continue
    date_str = ""
    for r in records:
        if r.get("timestamp"):
            date_str = r["timestamp"][:10]
            break
    if SINCE and date_str and date_str < SINCE:
        continue
    candidate_files.append((p, records))
    if not SESSION and not SINCE and len(candidate_files) >= LAST_N:
        break

# --- Load state files ---
experiments = []
try:
    with open(EXPERIMENTS_FILE) as f: experiments = json.load(f)
except: pass

findings = []
try:
    with open(FINDINGS_FILE) as f: findings = json.load(f)
except: pass

feedback = []
try:
    with open(FEEDBACK_FILE) as f: feedback = json.load(f)
except: pass

# --- Compute global stats ---
passed     = [e for e in experiments if e.get("status") == "passed"]
failed     = [e for e in experiments if e.get("status") == "failed"]
errored    = [e for e in experiments if e.get("status") == "error"]
pending    = [e for e in experiments if e.get("status") == "pending"]
total_done = len(passed) + len(failed) + len(errored)

# Which criterion fails most?
train_pnl_fails  = sum(1 for e in failed if e.get("training_result",{}) and
                       e.get("baseline_training",{}) and
                       (e["training_result"].get("pnl_pct",0) or 0) <= (e["baseline_training"].get("pnl_pct",0) or 0))
val_pnl_fails    = sum(1 for e in failed if e.get("validation_result",{}) and
                       e.get("baseline_validation",{}) and
                       (e["validation_result"].get("pnl_pct",0) or 0) <= (e["baseline_validation"].get("pnl_pct",0) or 0))
overfit_signals  = sum(1 for e in failed
                       if (e.get("training_result",{}) or {}).get("pnl_pct",0) >
                          (e.get("baseline_training",{}) or {}).get("pnl_pct",0))

# Finding coverage
exp_ids_with_finding = {f.get("experiment_id","") for f in findings}
completed_without_finding = [
    e["id"] for e in experiments
    if e.get("status") in ("passed","failed","error")
    and e.get("id","") not in exp_ids_with_finding
]

# Feedback acknowledgement
unacked = [f for f in feedback if not f.get("acknowledged")]

# Strategy mechanism diversity
mechanisms_seen = set()
mechanism_keywords = {
    "momentum": ["momentum","trend","breakout","continuation"],
    "mean_reversion": ["reversion","mean","bb","bollinger","oversold","overbought","bounce"],
    "regime": ["regime","adx","trending","ranging","detect"],
    "volatility": ["volatility","vol","atr","squeeze","expansion"],
    "carry": ["carry","funding","basis","spread"],
    "dca": ["dca","accumul","average down","cost"],
    "cycle": ["cycle","ath","halving","bull","bear"],
}
for e in experiments:
    hyp = str(e.get("hypothesis_id","")).lower()
    for mech, kws in mechanism_keywords.items():
        if any(kw in hyp for kw in kws):
            mechanisms_seen.add(mech)
# Also scan hypotheses.json
try:
    with open("priv/experiments/hypotheses.json") as f:
        hyps_data = json.load(f)
    for h in hyps_data:
        text = str(h.get("text","")).lower()
        for mech, kws in mechanism_keywords.items():
            if any(kw in text for kw in kws):
                mechanisms_seen.add(mech)
except: pass

# --- Analyse each session ---
sessions_data = [analyse_session(p.name.replace(".jsonl",""), recs) for p, recs in candidate_files]

report = {
    "analysed_sessions": sessions_data,
    "global": {
        "total_experiments": len(experiments),
        "passed": len(passed),
        "failed": len(failed),
        "errored": len(errored),
        "pending": len(pending),
        "pass_rate_pct": round(len(passed)/total_done*100, 1) if total_done else 0,
        "train_pnl_failures": train_pnl_fails,
        "val_pnl_failures":   val_pnl_fails,
        "overfit_signals":    overfit_signals,
        "findings_total":     len(findings),
        "completed_without_finding": completed_without_finding,
        "unacked_feedback_count": len(unacked),
        "unacked_feedback": [f.get("note","")[:80] for f in unacked],
        "mechanisms_seen": sorted(mechanisms_seen),
        "all_mechanisms": sorted(mechanism_keywords.keys()),
    }
}

print(json.dumps(report, indent=2, default=str))
PYEOF
```

Set environment variables before running to control scope:
- `TRACES_LAST_N=10` (default)
- `TRACES_SINCE=YYYY-MM-DD` (if `--since` flag given)
- `TRACES_SESSION=<id>` (if `--session` flag given)

---

## Step 3 — Interpret the Report

Read the JSON output carefully. For each dimension, identify the most significant issue. Do not just restate numbers — interpret what they mean for the objective.

**Questions to answer from the data:**

**Pass Rate Trend**
- What is the overall pass rate? Is it 0%? If so, is the mechanism wrong or are we not running enough experiments?
- Are failures concentrated in training (wrong mechanism) or validation (overfit)?
- Do any failed experiments show partial signals worth iterating on?

**Hypothesis Quality**
- Are hypotheses specific about mechanism, or generic ("try momentum")?
- Are they informed by prior findings, or starting from scratch each time?
- Is strategy diversity adequate, or is one mechanism being repeated?

**Pipeline Velocity**
- How many hypotheses per session? How many experiments run?
- Are experiments queued but not run (pile-up in pending)?
- How quickly are findings recorded after results arrive?

**Learning Extraction**
- Are all completed experiments covered by findings?
- Are failure tags being applied (overfit, invalid-hypothesis, drawdown-issue, partial-signal)?
- Are passes generating `improvement-idea` findings for follow-up?

**Feedback Loop**
- Is there unacknowledged feedback sitting in `feedback.json`?
- If so, how many loop iterations have passed without acting on it?

**Anti-Cheat Signals**
- Were any strategies re-queued with different params in the same session?
- Were experiments run one-by-one rather than `--all-pending`?

**Process Friction**
- How many user corrections per session? High rate = Claude misunderstood the objective mid-session
- Were rework loops (repeated compile/test) significant?

---

## Step 4 — Write the Report

Determine the output filename:

```bash
ls priv/experiments/trace_analysis/ | grep $(date +%Y-%m-%d) | wc -l
```

If 0 existing files today → `YYYY-MM-DD.md`. If N exist → `YYYY-MM-DD-N.md`.

Write to `priv/experiments/trace_analysis/YYYY-MM-DD.md`:

```markdown
# Experiment Loop Trace Analysis — YYYY-MM-DD

## Sessions Analysed
| Session ID | Date | Duration | Experiments Queued | Findings Added |
|---|---|---|---|---|
...

## Pass Rate
- Total: X passed / Y completed (Z%)
- Training failures: N  |  Validation failures: N  |  Overfit signals: N

## Hypothesis Quality
[Analysis — are hypotheses mechanism-specific? Informed by prior findings? Diverse?]

## Pipeline Velocity
[Analysis — hypotheses per session, pending pile-ups, finding lag]

## Learning Extraction
[Which completed experiments lack findings? Are tags being used?]

## Feedback Loop
[Unacknowledged feedback? How old?]

## Anti-Cheat Signals
[Any red flags? Or clean?]

## Process Friction
[Corrections, rework loops, anything that slowed progress]

## Concrete Improvement Suggestions

### Priority 1 — [Most impactful issue]
> What to change and why it matters for passing experiments

### Priority 2 — ...

### Priority 3 — ...
```

The **Improvement Suggestions** section is the most important. Be specific: "record a finding for exp-XXX" is better than "record more findings". "The last 3 hypotheses all tested momentum variants — explore mean-reversion next" is better than "improve diversity".

---

## Step 5 — Commit

```bash
git add priv/experiments/trace_analysis/
git commit -m "docs: add experiment loop trace analysis $(date +%Y-%m-%d)"
```

---

## Done

Tell the user:
- How many sessions were analysed
- The top 2-3 improvement suggestions
- Where the full report is saved
