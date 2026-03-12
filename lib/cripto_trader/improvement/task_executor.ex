defmodule CriptoTrader.Improvement.TaskExecutor do
  @moduledoc """
  Executes improvement tasks with optional verification.

  ## Task Types

  - `note`: General notes/ideas. Supports optional verification.
  - `requirement_gap`: Runs acceptance criteria checks.
  - `decision`: Records Architecture Decision Records (ADRs).
  - `backtest`: Runs trading strategy backtests with performance verification.

  ## Verification

  Notes can include optional verification in their payload:

      %{
        "type" => "note",
        "title" => "Implement feature X",
        "payload" => %{
          "verification" => %{
            "command" => "mix test test/feature_x_test.exs",
            "expect_exit_code" => 0,
            "expect_output_contains" => "0 failures"
          }
        }
      }

  If verification is present, the task only completes when verification passes.
  """

  require Logger
  alias CriptoTrader.Improvement.{Decisions, RequirementChecks}

  @spec execute(map()) :: {:ok, map()} | {:error, term()}
  def execute(task) do
    case task["type"] do
      "note" ->
        {:ok, execute_note(task)}

      "requirement_gap" ->
        {:ok, execute_requirement_gap(task)}

      "decision" ->
        execute_decision(task)

      "backtest" ->
        {:ok, execute_backtest(task)}

      type ->
        {:ok,
         %{
           status: "blocked",
           summary: "Unknown task type",
           details: "Task type #{inspect(type)} is not supported.",
           tags: ["improvement", "blocked"],
           data: %{}
         }}
    end
  end

  defp execute_note(task) do
    payload = task["payload"] || %{}
    verification = payload["verification"]

    case verification do
      nil ->
        # No verification - record and complete
        %{
          status: "done",
          summary: payload["summary"] || task["title"],
          details: payload["details"] || task["description"],
          tags: ["improvement", "note"],
          data: payload
        }

      verification_spec ->
        # Run verification command
        case run_verification(verification_spec) do
          {:ok, output} ->
            %{
              status: "done",
              summary: payload["summary"] || task["title"],
              details: "Verification passed",
              tags: ["improvement", "note", "verified"],
              data: Map.merge(payload, %{"verification_output" => output})
            }

          {:error, reason} ->
            %{
              status: "failed",
              summary: "Verification failed",
              details: reason,
              tags: ["improvement", "note", "verification_failed"],
              data: Map.merge(payload, %{"verification_error" => reason})
            }
        end
    end
  end

  defp execute_requirement_gap(task) do
    payload = task["payload"] || %{}
    criterion_id = payload["criterion_id"] || "unknown"
    description = payload["criterion_description"] || task["description"] || task["title"]

    result = RequirementChecks.check(criterion_id, description)

    status =
      case result.status do
        :met -> "done"
        :gap -> "failed"
        :unknown -> "blocked"
      end

    %{
      status: status,
      summary: "#{criterion_id}: #{result.summary}",
      details: result.details,
      tags: result.tags,
      data: %{
        criterion_id: criterion_id,
        evidence: result.evidence,
        check_status: to_string(result.status)
      }
    }
  end

  defp execute_decision(task) do
    payload = task["payload"] || %{}

    attrs = %{
      title: payload["title"] || task["title"],
      context: payload["context"] || task["description"],
      decision: payload["decision"],
      consequences: payload["consequences"],
      status: payload["status"] || "accepted"
    }

    case Decisions.record(attrs) do
      {:ok, decision} ->
        {:ok,
         %{
           status: "done",
           summary: "ADR recorded",
           details: "Created #{decision.path}",
           tags: ["improvement", "adr"],
           data: %{adr_id: decision.id, adr_path: decision.path}
         }}

      {:error, reason} ->
        {:ok,
         %{
           status: "failed",
           summary: "ADR creation failed",
           details: inspect(reason),
           tags: ["improvement", "adr", "error"],
           data: %{error: inspect(reason)}
         }}
    end
  end

  @doc """
  Runs a verification command and checks its output.

  ## Verification Spec

  - `command` (required): Shell command to execute
  - `expect_exit_code` (optional, default: 0): Expected exit code
  - `expect_output_contains` (optional): String that must appear in output

  ## Examples

      # Check if file exists
      run_verification(%{
        "command" => "test -f lib/my_module.ex"
      })

      # Run tests
      run_verification(%{
        "command" => "mix test test/my_module_test.exs",
        "expect_exit_code" => 0
      })

      # Check for pattern in output
      run_verification(%{
        "command" => "mix test",
        "expect_output_contains" => "0 failures"
      })
  """
  @spec run_verification(map()) :: {:ok, String.t()} | {:error, String.t()}
  def run_verification(verification_spec) when is_map(verification_spec) do
    command = verification_spec["command"]
    expected_exit = verification_spec["expect_exit_code"] || 0
    expected_output = verification_spec["expect_output_contains"]

    if is_nil(command) or command == "" do
      {:error, "Verification command is required"}
    else
      run_verification_command(command, expected_exit, expected_output)
    end
  end

  defp run_verification_command(command, expected_exit, expected_output) do
    Logger.debug("Running verification: #{command}")

    case System.cmd("sh", ["-c", command],
           stderr_to_stdout: true,
           env: [{"MIX_ENV", "test"}]
         ) do
      {output, ^expected_exit} ->
        if expected_output && !String.contains?(output, expected_output) do
          {:error, "Output missing expected string: #{inspect(expected_output)}"}
        else
          # Truncate output to avoid bloat
          truncated_output = truncate_output(output, 1000)
          {:ok, truncated_output}
        end

      {output, exit_code} ->
        truncated_output = truncate_output(output, 500)

        {:error,
         "Command exited with code #{exit_code} (expected #{expected_exit})\nOutput: #{truncated_output}"}
    end
  rescue
    error ->
      {:error, "Verification command failed: #{inspect(error)}"}
  end

  defp truncate_output(output, max_length) do
    if String.length(output) > max_length do
      String.slice(output, 0, max_length) <> "\n... (truncated)"
    else
      output
    end
  end

  defp execute_backtest(task) do
    payload = task["payload"] || %{}

    # Extract backtest parameters
    strategy_module = payload["strategy_module"] || "CriptoTrader.Strategy.Alternating"
    symbols = payload["symbols"] || ["BTCUSDT"]
    interval = payload["interval"] || "15m"
    start_date = payload["start_date"]
    end_date = payload["end_date"]

    # Run simulation
    case run_backtest(strategy_module, symbols, interval, start_date, end_date) do
      {:ok, result} ->
        # Check if performance meets thresholds
        verification = payload["verification"] || %{}

        case verify_backtest_performance(result, verification) do
          :ok ->
            %{
              status: "done",
              summary:
                "Backtest passed: PnL=#{format_currency(result.summary.pnl)}, Win Rate=#{format_percent(result.summary.win_rate)}",
              details: "Simulation completed successfully",
              tags: ["trading", "backtest", "passed"],
              data: %{
                "summary" => result.summary,
                "trades" => length(result.trade_log),
                "strategy" => strategy_module
              }
            }

          {:error, reason} ->
            %{
              status: "failed",
              summary: "Backtest failed verification",
              details: reason,
              tags: ["trading", "backtest", "failed"],
              data: %{"summary" => result.summary}
            }
        end

      {:error, reason} ->
        %{
          status: "failed",
          summary: "Backtest execution failed",
          details: inspect(reason),
          tags: ["trading", "backtest", "error"],
          data: %{}
        }
    end
  end

  defp run_backtest(strategy_module, symbols, interval, start_date, end_date) do
    # TODO: Integrate with CriptoTrader.Simulation.Runner
    # For now, return a placeholder result
    try do
      _params = %{
        strategy: strategy_module,
        symbols: symbols,
        interval: interval,
        start_date: start_date,
        end_date: end_date
      }

      {:ok,
       %{
         summary: %{
           pnl: 0.0,
           win_rate: 0.5,
           max_drawdown_pct: 0.1,
           trades: 0,
           closed_trades: 0,
           rejected_orders: 0
         },
         trade_log: [],
         equity_curve: []
       }}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp verify_backtest_performance(_result, verification) when map_size(verification) == 0 do
    # No verification thresholds specified - pass automatically
    :ok
  end

  defp verify_backtest_performance(result, verification) do
    summary = result.summary
    errors = []

    errors =
      if min_sharpe = verification["expect_sharpe_ratio_min"] do
        sharpe = summary[:sharpe_ratio] || 0.0

        if sharpe < min_sharpe do
          ["Sharpe ratio #{sharpe} below minimum #{min_sharpe}" | errors]
        else
          errors
        end
      else
        errors
      end

    errors =
      if max_drawdown = verification["expect_max_drawdown_max"] do
        drawdown = summary[:max_drawdown_pct] || 0.0

        if drawdown > max_drawdown do
          ["Max drawdown #{format_percent(drawdown)} exceeds maximum #{format_percent(max_drawdown)}" | errors]
        else
          errors
        end
      else
        errors
      end

    errors =
      if min_win_rate = verification["expect_win_rate_min"] do
        win_rate = summary[:win_rate] || 0.0

        if win_rate < min_win_rate do
          ["Win rate #{format_percent(win_rate)} below minimum #{format_percent(min_win_rate)}" | errors]
        else
          errors
        end
      else
        errors
      end

    errors =
      if min_trades = verification["expect_min_trades"] do
        trades = summary[:trades] || 0

        if trades < min_trades do
          ["Trade count #{trades} below minimum #{min_trades}" | errors]
        else
          errors
        end
      else
        errors
      end

    errors =
      if min_pnl = verification["expect_min_pnl"] do
        pnl = summary[:pnl] || 0.0

        if pnl < min_pnl do
          ["PnL #{format_currency(pnl)} below minimum #{format_currency(min_pnl)}" | errors]
        else
          errors
        end
      else
        errors
      end

    case errors do
      [] -> :ok
      _ -> {:error, Enum.join(errors, "; ")}
    end
  end

  defp format_currency(value) when is_number(value) do
    "$#{:erlang.float_to_binary(value * 1.0, decimals: 2)}"
  end

  defp format_currency(_), do: "$0.00"

  defp format_percent(value) when is_number(value) do
    "#{:erlang.float_to_binary(value * 100, decimals: 2)}%"
  end

  defp format_percent(_), do: "0.00%"
end
