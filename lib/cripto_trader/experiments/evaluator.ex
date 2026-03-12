defmodule CriptoTrader.Experiments.Evaluator do
  @moduledoc false

  @max_drawdown_threshold 40.0

  @spec evaluate(map()) :: %{verdict: :pass | :fail, reasons: [String.t()]}
  def evaluate(%{
        training: training,
        validation: validation,
        baseline_training: baseline_training,
        baseline_validation: baseline_validation
      }) do
    training_checks = check_split(training, baseline_training, "training")
    validation_checks = check_split(validation, baseline_validation, "validation")

    all_checks = training_checks ++ validation_checks
    failures = Enum.filter(all_checks, fn {passed, _msg} -> not passed end)
    passes = Enum.filter(all_checks, fn {passed, _msg} -> passed end)

    reasons =
      (Enum.map(failures, fn {_, msg} -> "FAIL: #{msg}" end) ++
         Enum.map(passes, fn {_, msg} -> "PASS: #{msg}" end))

    verdict = if failures == [], do: :pass, else: :fail

    %{verdict: verdict, reasons: reasons}
  end

  def evaluate(_), do: %{verdict: :fail, reasons: ["FAIL: incomplete results"]}

  defp check_split(result, baseline, label) do
    pnl_check = {
      result.pnl_pct > baseline.pnl_pct,
      "#{label} PnL% #{fmt(result.pnl_pct)}% vs baseline #{fmt(baseline.pnl_pct)}%"
    }

    quality_check = {
      result.sharpe > baseline.sharpe or result.max_drawdown_pct < @max_drawdown_threshold,
      "#{label} Sharpe #{fmt(result.sharpe)} vs baseline #{fmt(baseline.sharpe)}, " <>
        "max_dd #{fmt(result.max_drawdown_pct)}% (threshold #{@max_drawdown_threshold}%)"
    }

    [pnl_check, quality_check]
  end

  defp fmt(n) when is_float(n), do: Float.round(n, 2) |> to_string()
  defp fmt(n), do: to_string(n)
end
