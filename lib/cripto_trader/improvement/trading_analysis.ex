defmodule CriptoTrader.Improvement.TradingAnalysis do
  @moduledoc """
  Builds trading-specific prompts for Codex analysis.

  This module loads simulation results, computes metrics, and formats
  data for Codex consumption to guide trading algorithm improvements.
  """

  alias CriptoTrader.Improvement.Storage

  @doc """
  Loads latest backtest results and builds a Codex prompt for analysis.

  ## Options

    * `:budget` - Budget information to include in prompt
    * `:include_trade_details` - Whether to include individual trade analysis (default: false)

  ## Examples

      iex> TradingAnalysis.build_analysis_prompt("CriptoTrader.Strategy.Alternating", 1)
      "You are analyzing trading strategy performance for iteration 1.\\n..."

  """
  def build_analysis_prompt(strategy_name, iteration, opts \\ []) do
    # Load latest simulation results
    {:ok, latest_result} = Storage.read_json("priv/improvement/trading/latest_backtest.json", %{})
    {:ok, baseline} = Storage.read_json("priv/improvement/trading/baseline_metrics.json", %{})

    summary = latest_result["summary"] || %{}

    """
    You are analyzing trading strategy performance for iteration #{iteration}.

    STRATEGY: #{strategy_name}

    CURRENT PERFORMANCE:
    - PnL: $#{format_number(summary["pnl"], 2)}
    - Win Rate: #{format_pct(summary["win_rate"])}
    - Max Drawdown: #{format_pct(summary["max_drawdown_pct"])}
    - Total Trades: #{summary["trades"] || 0}
    - Closed Trades: #{summary["closed_trades"] || 0}
    - Rejected Orders: #{summary["rejected_orders"] || 0}
    - Sharpe Ratio: #{format_number(summary["sharpe_ratio"], 2)}

    #{baseline_comparison(summary, baseline)}

    DATA SOURCES:
    - Strategy code: lib/cripto_trader/strategy/#{strategy_file(strategy_name)}
    - Latest backtest: priv/improvement/trading/latest_backtest.json
    - Trade log: priv/improvement/trading/latest_trades.json
    - Equity curve: priv/improvement/trading/equity_curve.json
    - Baseline metrics: priv/improvement/trading/baseline_metrics.json

    ANALYSIS OBJECTIVES:
    1. Identify losing trade patterns (examine trade_log)
    2. Detect drawdown periods (examine equity_curve)
    3. Find risk control issues (rejected orders, position sizing)
    4. Suggest ONE specific code improvement to strategy logic
    5. Explain expected impact on metrics

    CONSTRAINTS:
    - Keep strategy deterministic (no random elements)
    - Maintain existing risk controls
    - Test changes with simulation before deployment
    - Focus on highest impact improvement

    OUTPUT REQUIRED:
    - Specific file path and function to modify
    - Code changes (diff format preferred)
    - Rationale for improvement
    - Expected metric improvements (PnL, win rate, or drawdown)

    #{budget_context(opts)}
    """
    |> String.trim_leading()
  end

  @doc """
  Formats a number with specified decimal places.

  Returns "N/A" if value is nil.
  """
  def format_number(nil, _decimals), do: "N/A"
  def format_number(value, decimals) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: decimals)
  end
  def format_number(_, _), do: "N/A"

  @doc """
  Formats a decimal value as a percentage.

  Returns "N/A" if value is nil.
  """
  def format_pct(nil), do: "N/A"
  def format_pct(value) when is_number(value) do
    "#{:erlang.float_to_binary(value * 100, decimals: 2)}%"
  end
  def format_pct(_), do: "N/A"

  defp baseline_comparison(_current, baseline) when map_size(baseline) == 0 do
    "BASELINE: Not yet established"
  end

  defp baseline_comparison(current, baseline) do
    """
    BASELINE COMPARISON:
    - PnL: #{delta(current["pnl"], baseline["pnl"])}
    - Win Rate: #{delta_pct(current["win_rate"], baseline["win_rate"])}
    - Max Drawdown: #{delta_pct(current["max_drawdown_pct"], baseline["max_drawdown_pct"])}
    - Sharpe Ratio: #{delta(current["sharpe_ratio"], baseline["sharpe_ratio"])}
    """
  end

  defp delta(nil, _), do: "N/A"
  defp delta(_, nil), do: "N/A"
  defp delta(current, baseline) when is_number(current) and is_number(baseline) do
    change = current - baseline
    sign = if change >= 0, do: "+", else: ""
    "#{sign}#{:erlang.float_to_binary(change * 1.0, decimals: 2)}"
  end
  defp delta(_, _), do: "N/A"

  defp delta_pct(nil, _), do: "N/A"
  defp delta_pct(_, nil), do: "N/A"
  defp delta_pct(current, baseline) when is_number(current) and is_number(baseline) do
    change = (current - baseline) * 100
    sign = if change >= 0, do: "+", else: ""
    "#{sign}#{:erlang.float_to_binary(change, decimals: 2)}%"
  end
  defp delta_pct(_, _), do: "N/A"

  defp strategy_file(name) do
    name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
    |> Kernel.<>(".ex")
  end

  defp budget_context(opts) do
    budget = opts[:budget]

    if budget do
      """
      BUDGET:
      - Remaining: #{budget["remaining_seconds"]} seconds
      - Resets: #{budget["window_end"]}
      """
    else
      ""
    end
  end
end
