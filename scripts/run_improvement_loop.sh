#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ITERATIONS="${ITERATIONS:-100}"
SLEEP_MS="${SLEEP_MS:-300}"
MAX_TASKS="${MAX_TASKS:-10}"
SEED_REQUIREMENTS="${SEED_REQUIREMENTS:-true}"
STOP_WHEN_CLEAN="${STOP_WHEN_CLEAN:-false}"
CODEX_ENABLED="${CODEX_ENABLED:-true}"
MIN_ITERATION_BUDGET="${MIN_ITERATION_BUDGET:-1}"

LOG_FILE="${LOG_FILE:-priv/improvement/autorun.log}"
mkdir -p "$(dirname "$LOG_FILE")"

{
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting autonomous improvement loop"
  echo "iterations=$ITERATIONS sleep_ms=$SLEEP_MS max_tasks=$MAX_TASKS codex_enabled=$CODEX_ENABLED"

  BOOL_ARGS=()
  if [[ "$SEED_REQUIREMENTS" == "true" ]]; then
    BOOL_ARGS+=(--seed-requirements)
  else
    BOOL_ARGS+=(--no-seed-requirements)
  fi

  if [[ "$STOP_WHEN_CLEAN" == "true" ]]; then
    BOOL_ARGS+=(--stop-when-clean)
  else
    BOOL_ARGS+=(--no-stop-when-clean)
  fi

  if [[ "$CODEX_ENABLED" == "true" ]]; then
    BOOL_ARGS+=(--codex-enabled)
  else
    BOOL_ARGS+=(--no-codex-enabled)
  fi

  mix improvement.loop.autorun \
    --iterations "$ITERATIONS" \
    --sleep-ms "$SLEEP_MS" \
    --max-tasks "$MAX_TASKS" \
    "${BOOL_ARGS[@]}" \
    --min-iteration-budget "$MIN_ITERATION_BUDGET"

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] autonomous improvement loop finished"
} | tee -a "$LOG_FILE"
