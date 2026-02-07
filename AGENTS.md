## Project Intent
We are building a Binance trading bot in Elixir. Prioritize safety, testability, and clear separation between exchange integration, strategy logic, and risk controls.

## Language & Tooling
- Use Elixir and Mix for all project code and tasks.
- Prefer OTP patterns (GenServer, Supervisor, Task) where appropriate.
- Keep configs in `config/` and secrets in environment variables.

## Scope Boundaries
- Initial focus: Binance spot trading only.
- Do not add futures/margin features unless explicitly requested.
- Avoid multi-exchange abstractions until the core Binance flow is stable.

## Safety & Risk Controls
- Default to `paper` trading mode unless the user explicitly requests live trading.
- Ensure risk controls exist for position sizing, max drawdown, and circuit breakers.
- Never hardcode API keys or secrets.

## Architecture Guidance
- Separate modules for:
  - Binance API client (REST/WebSocket)
  - Market data ingestion
  - Strategy engine (signals/indicators)
  - Order management
  - Risk management
  - Persistence (optional)
- Keep strategy logic pure and testable (no direct IO in signal generation).

## Testing
- Add unit tests for indicators, signals, and risk rules.
- Use integration tests for Binance client behavior (mock network).
- Prefer deterministic tests; avoid time-based flakiness.

## Documentation
- Keep `README.md` updated with setup, configuration, and safety guidance.
- Use `docs/binance_api_investigation_2026-02-05.md` as the primary reference for Binance API/SDK notes and Elixir version checks; update it when API docs or versions change.
- Add comments only when logic is non-obvious.

## Assumptions
- Environment variables provide API credentials and runtime options.
- Elixir/Erlang versions should be recent and compatible.
