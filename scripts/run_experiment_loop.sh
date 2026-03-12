#!/usr/bin/env bash
# run_experiment_loop.sh
#
# Runs the autonomous strategy experiment loop.
# Each iteration: Claude Code researches a hypothesis, analyses data,
# writes a strategy, queues and runs an experiment, records findings.
#
# Usage:
#   ./scripts/run_experiment_loop.sh                  # run forever
#   ./scripts/run_experiment_loop.sh --iterations 5   # run N iterations
#   ./scripts/run_experiment_loop.sh --sleep 600       # seconds between iterations (default 300)
#   ./scripts/run_experiment_loop.sh --budget 20.00    # stop if API spend exceeds $N
#
# Prerequisites:
#   1. mix phx.server running (dashboard + engine):
#        mix phx.server &
#        echo "Dashboard: http://localhost:4000"
#
#   2. Claude Code installed: claude --version
#
#   3. Archive candle cache warmed up (first run fetches; subsequent runs use cache):
#        mix binance.simulate --source archive --symbols BTCUSDC --interval 15m \
#          --start-time 2022-01-01T00:00:00Z --end-time 2024-12-31T23:59:59Z \
#          --strategy buy_and_hold 2>/dev/null || true

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
ITERATIONS=0          # 0 = run forever
SLEEP_SECONDS=300     # 5 minutes between iterations
MAX_BUDGET_USD=""     # empty = no budget cap
LOG_DIR="priv/experiments/loop_logs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --sleep)      SLEEP_SECONDS="$2"; shift 2 ;;
    --budget)     MAX_BUDGET_USD="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Setup ────────────────────────────────────────────────────────────────────
cd "$PROJECT_DIR"
mkdir -p "$LOG_DIR"

# Check prerequisites
if ! command -v claude &>/dev/null; then
  echo "ERROR: claude not found in PATH. Install Claude Code first."
  exit 1
fi

# ── Loop ─────────────────────────────────────────────────────────────────────
iteration=0
echo "$(date -Iseconds) Starting experiment loop (iterations=${ITERATIONS:-∞}, sleep=${SLEEP_SECONDS}s)"
echo "  Dashboard: http://localhost:4000"
echo "  Logs: $LOG_DIR/"
echo "  State: priv/experiments/"
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
    "/loop"
  )

  # Optional budget cap
  if [[ -n "$MAX_BUDGET_USD" ]]; then
    claude_cmd+=(--max-budget-usd "$MAX_BUDGET_USD")
  fi

  # Run one loop iteration, tee output to log
  if "${claude_cmd[@]}" 2>&1 | tee "$log_file"; then
    echo "$(date -Iseconds) Iteration $iteration completed. Log: $log_file"
  else
    exit_code=$?
    echo "$(date -Iseconds) WARNING: claude exited with code $exit_code. Log: $log_file"
    # Don't stop on non-zero exit — claude may exit non-zero for soft errors
  fi

  # Check if we've reached the iteration limit
  if [[ "$ITERATIONS" -gt 0 && "$iteration" -ge "$ITERATIONS" ]]; then
    echo "$(date -Iseconds) Reached $ITERATIONS iterations. Stopping."
    break
  fi

  echo "$(date -Iseconds) Sleeping ${SLEEP_SECONDS}s before next iteration..."
  sleep "$SLEEP_SECONDS"
done

echo "$(date -Iseconds) Experiment loop finished after $iteration iteration(s)."
