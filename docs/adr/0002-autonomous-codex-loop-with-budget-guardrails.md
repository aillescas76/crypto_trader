# ADR Autonomous Codex Loop With Budget Guardrails

Date: 2026-02-07
Status: accepted
ID: 0002

## Context
The improvement loop must continue without manual assistance and hand off context across runs. It must also respect execution limits (5h weekly budget).

## Decision
Use `mix improvement.loop.autorun` as the unattended orchestrator:
- It can invoke `codex exec` for one implementation pass per iteration.
- It updates tasks/findings/progress context on every iteration.
- It enforces a persistent weekly execution budget and pauses when exhausted.

## Consequences
The loop can run continuously, stop safely on budget exhaustion, and provide deterministic state files for the next Codex instance to resume work.
