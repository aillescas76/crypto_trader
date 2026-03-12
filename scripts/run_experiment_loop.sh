#!/usr/bin/env bash
# run_experiment_loop.sh
#
# Runs the autonomous strategy experiment loop.
# Each iteration: Claude Code researches a hypothesis, analyses data,
# writes a strategy, queues and runs an experiment, records findings.
# Every --improve-every iterations an /analyse-traces run reviews the
# sessions and writes a dated improvement report to
# priv/experiments/trace_analysis/.
#
# Usage:
#   ./scripts/run_experiment_loop.sh                    # run forever
#   ./scripts/run_experiment_loop.sh --iterations 5     # run N iterations
#   ./scripts/run_experiment_loop.sh --sleep 600        # seconds between iterations (default 300)
#   ./scripts/run_experiment_loop.sh --budget 20.00     # stop if API spend exceeds $N
#   ./scripts/run_experiment_loop.sh --improve-every 3  # analyse traces every N iters (default 5)
#
# Prerequisites:
#   1. mix phx.server running (dashboard + experiment engine):
#        mix phx.server &
#        # Dashboard: http://localhost:4000
#
#   2. Claude Code installed:
#        claude --version
#
#   3. Archive candle cache warmed (first run downloads; subsequent runs use cache).

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
ITERATIONS=0          # 0 = run forever
SLEEP_SECONDS=300     # seconds between successful iterations
MAX_BUDGET_USD=""     # empty = no budget cap
IMPROVE_EVERY=5       # run /analyse-traces every N iterations (0 = disabled)
LOG_DIR="priv/experiments/loop_logs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)   ITERATIONS="$2";   shift 2 ;;
    --sleep)        SLEEP_SECONDS="$2"; shift 2 ;;
    --budget)       MAX_BUDGET_USD="$2"; shift 2 ;;
    --improve-every) IMPROVE_EVERY="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

# Detect usage/rate limit in claude output.
# Claude shows messages like:
#   "Claude AI usage limit reached"
#   "You've hit your limit · resets 10pm (America/New_York)"
#   "rate limit"  /  "Rate limit"
is_usage_limit() {
  local output="$1"
  echo "$output" | grep -qiE \
    "usage limit|rate limit|hit your limit|quota exceeded|too many requests|resets [0-9]"
}

# Try to extract seconds until reset from the claude output.
# Handles:
#   "resets 10pm (America/New_York)"
#   "resets in 2 hours"
#   "retry after 3600 seconds"
#   "retry-after: 18000"
seconds_until_reset() {
  local output="$1"
  local now
  now=$(date +%s)

  # "retry-after: N" or "retry after N seconds"
  if echo "$output" | grep -iqE "retry.after:?\s*[0-9]+"; then
    local secs
    secs=$(echo "$output" | grep -ioE "retry.after:?\s*[0-9]+" | grep -oE "[0-9]+" | head -1)
    if [[ -n "$secs" && "$secs" -gt 0 ]]; then
      echo "$secs"
      return
    fi
  fi

  # "resets in X hours" / "resets in X minutes"
  if echo "$output" | grep -iqE "resets in [0-9]+ (hour|minute)"; then
    local num unit
    num=$(echo "$output" | grep -ioE "resets in ([0-9]+) (hour|minute)" | grep -oE "^[0-9]+" | head -1)
    unit=$(echo "$output" | grep -ioE "resets in [0-9]+ (hour|minute)" | grep -oE "(hour|minute)$" | head -1)
    if [[ -n "$num" ]]; then
      if [[ "$unit" == "hour" ]]; then echo $((num * 3600)); return; fi
      if [[ "$unit" == "minute" ]]; then echo $((num * 60)); return; fi
    fi
  fi

  # "resets HH:MMam/pm" or "resets 10pm"
  if echo "$output" | grep -iqE "resets [0-9]+(:[0-9]+)?(am|pm)"; then
    local time_str tz reset_epoch
    time_str=$(echo "$output" | grep -ioE "resets [0-9]+(:[0-9]+)?(am|pm)" | sed 's/resets //' | head -1)
    # Try to parse timezone from the same line
    tz=$(echo "$output" | grep -ioE "\(([A-Za-z/_]+)\)" | tr -d '()' | head -1)
    if [[ -n "$tz" ]]; then
      reset_epoch=$(TZ="$tz" date -d "$time_str" +%s 2>/dev/null || true)
    else
      reset_epoch=$(date -d "$time_str" +%s 2>/dev/null || true)
    fi
    if [[ -n "$reset_epoch" && "$reset_epoch" -gt "$now" ]]; then
      echo $(( reset_epoch - now + 60 ))   # +60s buffer
      return
    fi
    # If parsed time is in the past, it might be tomorrow
    if [[ -n "$reset_epoch" && "$reset_epoch" -le "$now" ]]; then
      echo $(( reset_epoch - now + 86400 + 60 ))
      return
    fi
  fi

  # Fallback: return empty (caller will use default backoff)
  echo ""
}

# Run /analyse-traces to review recent experiment sessions and write a report.
run_improvement() {
  local n="${1:-$IMPROVE_EVERY}"
  local improve_log="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S)_analyse_traces.log"
  echo "$(date -Iseconds) ── Improvement run (--last $n) ──────────────────"

  set +e
  improve_output=$(claude \
    --dangerously-skip-permissions \
    --print \
    "/analyse-traces --last $n" 2>&1)
  improve_exit=$?
  set -e

  echo "$improve_output" > "$improve_log"

  if is_usage_limit "$improve_output"; then
    echo "$(date -Iseconds) Usage limit hit during improvement run. Skipping (will retry next cycle)."
  elif [[ $improve_exit -ne 0 ]]; then
    echo "$(date -Iseconds) WARNING: analyse-traces exited $improve_exit. Log: $improve_log"
  else
    echo "$(date -Iseconds) Improvement run done. Log: $improve_log"
  fi
}

format_duration() {
  local secs="$1"
  if   [[ $secs -ge 3600 ]]; then printf "%dh %dm" $((secs/3600)) $(( (secs%3600)/60 ))
  elif [[ $secs -ge 60   ]]; then printf "%dm %ds" $((secs/60)) $((secs%60))
  else                             printf "%ds" "$secs"
  fi
}

# ── Setup ─────────────────────────────────────────────────────────────────────
cd "$PROJECT_DIR"
mkdir -p "$LOG_DIR"

if ! command -v claude &>/dev/null; then
  echo "ERROR: claude not found in PATH. Install Claude Code first."
  exit 1
fi

# ── Loop ──────────────────────────────────────────────────────────────────────
iteration=0
echo "$(date -Iseconds) Starting experiment loop"
echo "  Iterations    : ${ITERATIONS:-∞}"
echo "  Sleep         : ${SLEEP_SECONDS}s between iterations"
echo "  Budget cap    : ${MAX_BUDGET_USD:-none}"
echo "  Improve every : ${IMPROVE_EVERY} iterations (0=disabled)"
echo "  Dashboard     : http://localhost:4000"
echo "  Logs          : $LOG_DIR/"
echo ""

while true; do
  iteration=$((iteration + 1))
  log_file="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S)_iter${iteration}.log"

  echo "$(date -Iseconds) ── Iteration $iteration ──────────────────────────"

  # Build claude command
  claude_cmd=(
    claude
    --dangerously-skip-permissions
    --print
  )
  [[ -n "$MAX_BUDGET_USD" ]] && claude_cmd+=(--max-budget-usd "$MAX_BUDGET_USD")
  claude_cmd+=("/loop")

  # Run, capture output and exit code
  set +e
  output=$("${claude_cmd[@]}" 2>&1)
  exit_code=$?
  set -e

  # Write log
  echo "$output" > "$log_file"

  # ── Detect usage/rate limit ─────────────────────────────────────────────
  if is_usage_limit "$output"; then
    echo "$output" | grep -iE "limit|resets|retry" | head -3 || true

    wait_secs=$(seconds_until_reset "$output")

    if [[ -n "$wait_secs" && "$wait_secs" -gt 0 ]]; then
      wake_time=$(date -d "+${wait_secs} seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                  || date -v +${wait_secs}S "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                  || echo "unknown")
      echo "$(date -Iseconds) Usage limit hit. Sleeping $(format_duration $wait_secs) (until ~$wake_time)"
    else
      # No reset time parsed — default to 5h10m (covers the rolling 5h window)
      wait_secs=18600
      wake_time=$(date -d "+${wait_secs} seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                  || date -v +${wait_secs}S "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                  || echo "unknown")
      echo "$(date -Iseconds) Usage limit hit (no reset time found). Sleeping $(format_duration $wait_secs) until ~$wake_time"
    fi

    sleep "$wait_secs"
    echo "$(date -Iseconds) Resuming after usage limit sleep."
    continue   # retry same iteration (don't increment, don't sleep extra)
  fi

  # ── Normal exit handling ────────────────────────────────────────────────
  if [[ $exit_code -ne 0 ]]; then
    echo "$(date -Iseconds) WARNING: claude exited $exit_code. Log: $log_file"
    # Don't stop — transient errors are expected; the state files are safe
  else
    echo "$(date -Iseconds) Iteration $iteration done. Log: $log_file"
  fi

  # ── Periodic improvement run ────────────────────────────────────────────
  if [[ "$IMPROVE_EVERY" -gt 0 && $(( iteration % IMPROVE_EVERY )) -eq 0 ]]; then
    run_improvement "$IMPROVE_EVERY"
  fi

  # ── Check iteration cap ─────────────────────────────────────────────────
  if [[ "$ITERATIONS" -gt 0 && "$iteration" -ge "$ITERATIONS" ]]; then
    echo "$(date -Iseconds) Reached $ITERATIONS iteration(s). Stopping."
    # Final improvement run if we haven't just done one
    if [[ "$IMPROVE_EVERY" -gt 0 && $(( iteration % IMPROVE_EVERY )) -ne 0 ]]; then
      run_improvement "$iteration"
    fi
    break
  fi

  echo "$(date -Iseconds) Sleeping ${SLEEP_SECONDS}s before next iteration..."
  sleep "$SLEEP_SECONDS"
done

echo "$(date -Iseconds) Experiment loop finished after $iteration iteration(s)."
