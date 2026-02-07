# ADR Improvement Loop Uses File-Backed Persistence

Date: 2026-02-07
Status: accepted
ID: 0001

## Context
The project needs a safe, testable mechanism to continuously close gaps against `docs/requirements.md`.

## Decision
Use a file-backed improvement loop:
- `priv/improvement/tasks.json` for future work tracking.
- `priv/improvement/knowledge_base.json` for findings/evidence.
- `mix improvement.loop.run` to process pending tasks and write findings.
- `docs/adr/` for architecture decisions.

## Consequences
The workflow is deterministic, reviewable in git, and works in paper-first local development without external services.
