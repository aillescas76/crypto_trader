# Improvement Loop: Step by Step

Date: 2026-02-08

This document explains what happens in each step of `mix improvement.loop.autorun`.

## Entry Point
- Command: `mix improvement.loop.autorun`
- Starts app and delegates to `CriptoTrader.Improvement.AutonomousLoop.run/1`.

## Per-Iteration Lifecycle
1. Initialize run state:
   - Create `run_id`.
   - Mark loop as `running` in `priv/improvement/loop_state.json`.
2. Check budget gate:
   - Validate there is enough weekly execution budget before doing work.
   - If exhausted, stop with `paused_budget_exhausted`.
3. Seed requirements (default: enabled):
   - Parse `docs/requirements.md` acceptance criteria.
   - Create missing `requirement_gap` tasks.
   - Reactivate failed/blocked requirement tasks back to `pending`.
4. Run Codex implementation pass (default: enabled):
   - Build prompt with objective, constraints, and budget snapshot.
   - Execute `codex` command (`CODEX_CMD` / `CODEX_ARGS` overrideable).
   - Capture exit status, duration, and output tail.
5. Execute loop tasks:
   - Load pending tasks ordered by priority and id.
   - Process up to `max_tasks` tasks.
6. Process each task:
   - Set task status to `in_progress`.
   - Execute by type:
     - `note`
     - `requirement_gap`
     - `decision` (creates ADR under `docs/adr/`)
   - Update final task status (`done` / `failed` / `blocked`).
   - Persist finding into knowledge base.
7. Consume budget:
   - Compute elapsed iteration seconds.
   - Subtract from weekly budget.
8. Write iteration reports:
   - Update `priv/improvement/loop_state.json`.
   - Write `priv/improvement/progress_report.json`.
   - Write `priv/improvement/agent_context.json`.
9. Evaluate stop condition:
   - `stopped_clean` when requirements/tasks are clean and `--stop-when-clean` is enabled.
   - `stopped_iteration_cap` when max iterations reached.
   - `stopped_error` if any iteration stage fails.
10. Finalize:
   - Mark loop status as `stopped`.
   - Persist final report snapshot with stop reason.

## Task Status Model
- Valid states: `pending`, `in_progress`, `done`, `failed`, `blocked`.
- `requirement_gap` tasks map check results:
  - `:met` -> `done`
  - `:gap` -> `failed`
  - `:unknown` -> `blocked`

## Runtime Artifacts
- `priv/improvement/tasks.json`: task backlog and results
- `priv/improvement/knowledge_base.json`: findings log
- `priv/improvement/loop_state.json`: current/last run state
- `priv/improvement/progress_report.json`: coverage + progress summary
- `priv/improvement/agent_context.json`: compact handoff context for next iteration
- `priv/improvement/execution_budget.json`: weekly budget snapshot

## Observability Tips
- Quick state check:
  - `mix improvement.budget.status`
  - `mix improvement.task.list`
  - `mix improvement.findings.list --limit 20`
- If loop paused for budget, resume after reset window shown in `execution_budget.json`.
