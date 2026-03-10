defmodule Mix.Tasks.Improvement.Trading.Autorun do
  @moduledoc """
  Run autonomous trading algorithm improvement loop.

  ## Examples

      # Run with defaults (10 iterations)
      mix improvement.trading.autorun

      # Custom iteration count
      mix improvement.trading.autorun --iterations 50

      # Specific strategy
      mix improvement.trading.autorun --strategy MyStrategy

      # Run without Codex (for testing)
      mix improvement.trading.autorun --iterations 5 --no-codex

      # Multiple symbols
      mix improvement.trading.autorun --symbols BTCUSDT,ETHUSDT,BNBUSDT

      # Custom sleep between iterations
      mix improvement.trading.autorun --sleep-ms 5000

  ## Options

    * `--iterations` - Number of iterations (default: 10)
    * `--strategy` - Strategy module name (default: CriptoTrader.Strategy.Alternating)
    * `--symbols` - Comma-separated list of symbols (default: BTCUSDT)
    * `--interval` - Candle interval (default: 15m)
    * `--codex` - Enable/disable Codex invocation (default: true)
    * `--sleep-ms` - Milliseconds to sleep between iterations (default: 1000)

  """

  use Mix.Task
  alias CriptoTrader.Improvement.TradingLoop

  @shortdoc "Run autonomous trading algorithm improvement loop"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          iterations: :integer,
          strategy: :string,
          symbols: :string,
          interval: :string,
          codex: :boolean,
          sleep_ms: :integer
        ]
      )

    symbols =
      if opts[:symbols] do
        String.split(opts[:symbols], ",")
      else
        ["BTCUSDT"]
      end

    iterations = opts[:iterations] || 10

    Mix.shell().info("Starting autonomous trading loop: #{iterations} iterations")
    Mix.shell().info("Strategy: #{opts[:strategy] || "CriptoTrader.Strategy.Alternating"}")
    Mix.shell().info("Symbols: #{inspect(symbols)}")
    Mix.shell().info("Codex: #{if Keyword.get(opts, :codex, true), do: "enabled", else: "disabled"}")
    Mix.shell().info("")

    result =
      TradingLoop.run(
        iterations: iterations,
        strategy: opts[:strategy] || "CriptoTrader.Strategy.Alternating",
        symbols: symbols,
        interval: opts[:interval] || "15m",
        codex_enabled: Keyword.get(opts, :codex, true),
        sleep_ms: opts[:sleep_ms] || 1000
      )

    case result do
      %{iteration: last_iteration} ->
        Mix.shell().info("\n✓ Autonomous loop complete: #{last_iteration} iterations")

      :budget_exhausted ->
        Mix.shell().error("\n✗ Loop stopped: budget exhausted")

      {:error, reason} ->
        Mix.shell().error("\n✗ Loop failed: #{inspect(reason)}")

      _ ->
        Mix.shell().info("\n✓ Loop complete")
    end

    Mix.shell().info("\nRun 'mix improvement.trading.status' to see current state")
  end
end
