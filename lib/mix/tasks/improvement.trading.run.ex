defmodule Mix.Tasks.Improvement.Trading.Run do
  @moduledoc """
  Run one trading algorithm improvement iteration.

  ## Examples

      # Run with defaults
      mix improvement.trading.run

      # Specify strategy
      mix improvement.trading.run --strategy CriptoTrader.Strategy.Alternating

      # Multiple symbols
      mix improvement.trading.run --symbols BTCUSDT,ETHUSDT

      # Run without Codex
      mix improvement.trading.run --no-codex

      # Custom interval
      mix improvement.trading.run --interval 1h

  ## Options

    * `--strategy` or `-s` - Strategy module name (default: CriptoTrader.Strategy.Alternating)
    * `--symbols` - Comma-separated list of symbols (default: BTCUSDT)
    * `--interval` or `-i` - Candle interval (default: 15m)
    * `--codex` - Enable/disable Codex invocation (default: true)

  """

  use Mix.Task
  alias CriptoTrader.Improvement.TradingLoop

  @shortdoc "Run one trading algorithm improvement iteration"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          strategy: :string,
          symbols: :string,
          interval: :string,
          codex: :boolean
        ],
        aliases: [s: :strategy, i: :interval]
      )

    symbols =
      if opts[:symbols] do
        String.split(opts[:symbols], ",")
      else
        ["BTCUSDT"]
      end

    result =
      TradingLoop.run(
        iterations: 1,
        strategy: opts[:strategy] || "CriptoTrader.Strategy.Alternating",
        symbols: symbols,
        interval: opts[:interval] || "15m",
        codex_enabled: Keyword.get(opts, :codex, true),
        sleep_ms: 0
      )

    case result do
      %{iteration: iteration, backtest: backtest, codex: codex} ->
        Mix.shell().info("\n✓ Trading iteration #{iteration} complete")
        Mix.shell().info("  Backtest: #{inspect(backtest.summary)}")

        if codex[:invoked] do
          Mix.shell().info("  Codex: invoked (exit_status=#{codex[:exit_status]})")
        else
          Mix.shell().info("  Codex: skipped")
        end

      :budget_exhausted ->
        Mix.shell().error("\n✗ Budget exhausted")

      {:error, reason} ->
        Mix.shell().error("\n✗ Iteration failed: #{inspect(reason)}")

      _ ->
        Mix.shell().info("\n✓ Trading iteration complete")
    end
  end
end
