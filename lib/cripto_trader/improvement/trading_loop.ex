defmodule CriptoTrader.Improvement.TradingLoop do
  @moduledoc """
  Autonomous trading algorithm improvement loop.

  Orchestrates:
  1. Running backtests
  2. Analyzing results
  3. Invoking Codex for improvements
  4. Tracking performance over iterations

  ## Usage

      # Run a single iteration
      TradingLoop.run(iterations: 1, strategy: "CriptoTrader.Strategy.Alternating")

      # Run autonomous loop
      TradingLoop.run(iterations: 10, codex_enabled: true)

      # Run without Codex (for testing)
      TradingLoop.run(iterations: 5, codex_enabled: false)

  """

  require Logger
  alias CriptoTrader.Improvement.{Budget, Codex, Storage, TradingAnalysis, TradingState}
  alias CriptoTrader.MarketData.Candles
  alias CriptoTrader.Simulation.Runner

  @default_iterations 10
  @default_strategy "CriptoTrader.Strategy.Alternating"
  @default_symbols ["BTCUSDT"]
  @default_interval "15m"
  @default_sleep_ms 1000
  @default_quantity 0.1

  @doc """
  Runs the trading improvement loop.

  ## Options

    * `:iterations` - Number of iterations to run (default: #{@default_iterations})
    * `:strategy` - Strategy module name (default: "#{@default_strategy}")
    * `:symbols` - List of trading symbols (default: #{inspect(@default_symbols)})
    * `:interval` - Candle interval (default: "#{@default_interval}")
    * `:codex_enabled` - Whether to invoke Codex (default: true)
    * `:sleep_ms` - Milliseconds to sleep between iterations (default: #{@default_sleep_ms})

  """
  def run(opts \\ []) do
    iterations = opts[:iterations] || @default_iterations
    strategy = opts[:strategy] || @default_strategy
    symbols = opts[:symbols] || @default_symbols
    interval = opts[:interval] || @default_interval
    codex_enabled = Keyword.get(opts, :codex_enabled, true)
    sleep_ms = opts[:sleep_ms] || @default_sleep_ms

    Logger.info("Starting trading loop: #{iterations} iterations, strategy=#{strategy}")

    Enum.reduce_while(1..iterations, %{}, fn iteration, _acc ->
      Logger.info("Trading loop iteration #{iteration}")

      case run_iteration(iteration, strategy, symbols, interval, codex_enabled) do
        {:ok, result} ->
          if sleep_ms > 0, do: Process.sleep(sleep_ms)
          {:cont, result}

        {:error, :budget_exhausted} ->
          Logger.warning("Budget exhausted, stopping loop")
          {:halt, :budget_exhausted}

        {:error, reason} ->
          Logger.error("Iteration failed: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)

    Logger.info("Trading loop complete")
  end

  defp run_iteration(iteration, strategy, symbols, interval, codex_enabled) do
    with :ok <- check_budget(),
         {:ok, backtest_result} <- run_backtest(strategy, symbols, interval),
         :ok <- store_backtest_results(backtest_result),
         :ok <- maybe_set_baseline(iteration, backtest_result),
         {:ok, codex_result} <- maybe_run_codex(codex_enabled, strategy, iteration),
         :ok <- update_state(iteration, backtest_result, codex_result) do
      {:ok, %{iteration: iteration, backtest: backtest_result, codex: codex_result}}
    end
  end

  defp check_budget do
    case Budget.ensure_available(1) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :budget_exhausted}
    end
  end

  defp run_backtest(strategy_module_name, symbols, interval) do
    Logger.info("Running backtest: strategy=#{strategy_module_name}, symbols=#{inspect(symbols)}, interval=#{interval}")

    with {:ok, module} <- resolve_strategy_module(strategy_module_name),
         {:ok, candles_by_symbol} <- fetch_candles(symbols, interval) do
      strategy_state = make_strategy_state(module, symbols, @default_quantity)

      Runner.run(
        symbols: symbols,
        interval: interval,
        candles_by_symbol: candles_by_symbol,
        strategy_fun: &module.signal/2,
        strategy_state: strategy_state,
        trading_mode: :paper,
        include_trade_log: true,
        include_equity_curve: false,
        log_strategy_decisions: false
      )
    end
  end

  defp resolve_strategy_module(name) do
    module = String.to_existing_atom("Elixir.#{name}")

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, {:unknown_strategy, name}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_strategy, name}}
  end

  defp make_strategy_state(module, symbols, quantity) do
    if function_exported?(module, :new_state, 2) do
      module.new_state(symbols, quantity)
    else
      %{}
    end
  end

  defp fetch_candles(symbols, interval) do
    Candles.fetch(symbols: symbols, interval: interval, limit: 1000)
  end

  defp store_backtest_results(result) do
    base_path = "priv/improvement/trading"
    File.mkdir_p!(base_path)

    Storage.write_json("#{base_path}/latest_backtest.json", result)
    Storage.write_json("#{base_path}/latest_trades.json", result.trade_log)
    Storage.write_json("#{base_path}/equity_curve.json", result.equity_curve)

    Logger.debug("Stored backtest results in #{base_path}")
    :ok
  end

  defp maybe_set_baseline(1, backtest_result) do
    # On first iteration, set baseline metrics
    Logger.info("Setting baseline metrics from iteration 1")

    baseline = backtest_result.summary
    Storage.write_json("priv/improvement/trading/baseline_metrics.json", baseline)

    :ok
  end

  defp maybe_set_baseline(_iteration, _result), do: :ok

  defp maybe_run_codex(false, _strategy, _iteration) do
    Logger.debug("Codex disabled, skipping analysis")
    {:ok, %{invoked: false}}
  end

  defp maybe_run_codex(true, strategy, iteration) do
    Logger.info("Invoking Codex for trading analysis")

    {:ok, budget} = Budget.snapshot()
    prompt = TradingAnalysis.build_analysis_prompt(strategy, iteration, budget: budget)

    case Codex.run(prompt) do
      {:ok, result} ->
        Logger.info("Codex completed: exit_status=#{result.exit_status}")
        {:ok, Map.put(result, :invoked, true)}

      {:error, reason, result} ->
        Logger.error("Codex failed: #{inspect(reason)}")
        # Don't fail iteration on Codex error
        {:ok, Map.put(result, :invoked, true)}
    end
  end

  defp update_state(iteration, backtest_result, codex_result) do
    state = TradingState.read()

    new_state = %{
      state
      | "iteration" => iteration,
        "last_backtest_summary" => backtest_result.summary,
        "last_codex_invoked" => codex_result[:invoked] || false,
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    TradingState.write(new_state)
    Logger.debug("Updated trading state: iteration #{iteration}")
    :ok
  end
end
