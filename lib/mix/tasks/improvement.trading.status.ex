defmodule Mix.Tasks.Improvement.Trading.Status do
  @moduledoc """
  Show current trading algorithm improvement status.

  Displays:
  - Current iteration count
  - Active strategy
  - Last backtest metrics
  - Baseline comparison
  - Last update timestamp

  ## Examples

      mix improvement.trading.status

  """

  use Mix.Task
  alias CriptoTrader.Improvement.TradingState

  @shortdoc "Show trading algorithm improvement status"

  def run(_args) do
    Mix.Task.run("app.start")

    state = TradingState.read()

    Mix.shell().info("Trading Loop Status")
    Mix.shell().info("═══════════════════")
    Mix.shell().info("")
    Mix.shell().info("Iteration: #{state["iteration"]}")
    Mix.shell().info("Strategy:  #{state["strategy"]}")
    Mix.shell().info("Updated:   #{state["updated_at"] || "never"}")
    Mix.shell().info("")

    if summary = state["last_backtest_summary"], do: show_backtest_summary(summary, state)

    if baseline = state["baseline_metrics"], do: show_baseline(baseline)
  end

  defp show_backtest_summary(summary, state) when map_size(summary) > 0 do
    Mix.shell().info("Last Backtest Results")
    Mix.shell().info("─────────────────────")
    Mix.shell().info("PnL:            #{format_currency(summary["pnl"])}")
    Mix.shell().info("Win Rate:       #{format_pct(summary["win_rate"])}")
    Mix.shell().info("Max Drawdown:   #{format_pct(summary["max_drawdown_pct"])}")
    Mix.shell().info("Sharpe Ratio:   #{format_number(summary["sharpe_ratio"])}")
    Mix.shell().info("Trades:         #{summary["trades"] || 0}")
    Mix.shell().info("Closed Trades:  #{summary["closed_trades"] || 0}")
    Mix.shell().info("Rejected:       #{summary["rejected_orders"] || 0}")
    Mix.shell().info("")

    if state["last_codex_invoked"] do
      Mix.shell().info("Codex:          ✓ invoked")
    else
      Mix.shell().info("Codex:          ✗ not invoked")
    end

    Mix.shell().info("")
  end

  defp show_backtest_summary(_summary, _state) do
    Mix.shell().info("No backtest results yet")
    Mix.shell().info("")
  end

  defp show_baseline(baseline) when map_size(baseline) > 0 do
    Mix.shell().info("Baseline Metrics")
    Mix.shell().info("────────────────")
    Mix.shell().info("PnL:            #{format_currency(baseline["pnl"])}")
    Mix.shell().info("Win Rate:       #{format_pct(baseline["win_rate"])}")
    Mix.shell().info("Max Drawdown:   #{format_pct(baseline["max_drawdown_pct"])}")
    Mix.shell().info("Sharpe Ratio:   #{format_number(baseline["sharpe_ratio"])}")
    Mix.shell().info("")
  end

  defp show_baseline(_baseline), do: :ok

  defp format_currency(nil), do: "$0.00"
  defp format_currency(value) when is_number(value) do
    "$#{:erlang.float_to_binary(value * 1.0, decimals: 2)}"
  end
  defp format_currency(_), do: "$0.00"

  defp format_pct(nil), do: "N/A"
  defp format_pct(value) when is_number(value) do
    "#{:erlang.float_to_binary(value * 100, decimals: 2)}%"
  end
  defp format_pct(_), do: "N/A"

  defp format_number(nil), do: "N/A"
  defp format_number(value) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: 2)
  end
  defp format_number(_), do: "N/A"
end
