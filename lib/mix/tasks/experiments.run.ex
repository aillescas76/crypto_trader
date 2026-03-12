defmodule Mix.Tasks.Experiments.Run do
  use Mix.Task

  alias CriptoTrader.Experiments.{Evaluator, Runner, State}

  @shortdoc "Run experiments synchronously"
  @moduledoc """
  Runs experiments synchronously (bypasses GenServer Engine).

  ## Usage

      mix experiments.run --id EXP_ID
      mix experiments.run --all-pending
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        switches: [id: :string, all_pending: :boolean]
      )

    Mix.Task.run("app.start", [])

    experiments =
      cond do
        id = Keyword.get(opts, :id) ->
          case find_experiment(id) do
            nil -> Mix.raise("Experiment #{id} not found")
            exp -> [exp]
          end

        Keyword.get(opts, :all_pending, false) ->
          case State.list_experiments() do
            {:ok, exps} -> Enum.filter(exps, fn e -> Map.get(e, "status") == "pending" end)
            {:error, r} -> Mix.raise("Failed to load experiments: #{inspect(r)}")
          end

        true ->
          Mix.raise("Provide --id ID or --all-pending")
      end

    if experiments == [] do
      Mix.shell().info("No experiments to run.")
    else
      Enum.each(experiments, &run_one/1)
    end
  end

  defp run_one(experiment) do
    id = Map.get(experiment, "id")
    Mix.shell().info("\nRunning experiment #{id} ...")

    updated = Map.merge(experiment, %{"status" => "running"})
    State.upsert_experiment(updated)

    case Runner.run(experiment) do
      {:ok, results} ->
        evaluation = Evaluator.evaluate(results)
        status = if evaluation.verdict == :pass, do: "passed", else: "failed"

        final =
          Map.merge(updated, %{
            "status" => status,
            "training_result" => results.training,
            "validation_result" => results.validation,
            "baseline_training" => results.baseline_training,
            "baseline_validation" => results.baseline_validation,
            "verdict" => %{
              "verdict" => to_string(evaluation.verdict),
              "reasons" => evaluation.reasons
            },
            "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        State.upsert_experiment(final)

        Mix.shell().info("  Status:  #{status}")
        print_results(results, evaluation)

      {:error, reason} ->
        errored =
          Map.merge(updated, %{
            "status" => "error",
            "verdict" => %{"verdict" => "fail", "reasons" => ["error: #{inspect(reason)}"]},
            "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        State.upsert_experiment(errored)
        Mix.shell().error("  Error: #{inspect(reason)}")
    end
  end

  defp print_results(results, evaluation) do
    t = results.training
    v = results.validation
    bt = results.baseline_training
    bv = results.baseline_validation

    Mix.shell().info("  Training:   PnL% #{pct(t.pnl_pct)}  Sharpe #{t.sharpe}  MaxDD #{pct(t.max_drawdown_pct)}")
    Mix.shell().info("  B.Training: PnL% #{pct(bt.pnl_pct)}  Sharpe #{bt.sharpe}  MaxDD #{pct(bt.max_drawdown_pct)}")
    Mix.shell().info("  Validation: PnL% #{pct(v.pnl_pct)}  Sharpe #{v.sharpe}  MaxDD #{pct(v.max_drawdown_pct)}")
    Mix.shell().info("  B.Validat:  PnL% #{pct(bv.pnl_pct)}  Sharpe #{bv.sharpe}  MaxDD #{pct(bv.max_drawdown_pct)}")
    Mix.shell().info("  Verdict: #{evaluation.verdict}")

    Enum.each(evaluation.reasons, fn reason ->
      Mix.shell().info("    #{reason}")
    end)
  end

  defp pct(n), do: "#{Float.round(n * 1.0, 2)}%"

  defp find_experiment(id) do
    case State.list_experiments() do
      {:ok, experiments} -> Enum.find(experiments, fn e -> Map.get(e, "id") == id end)
      _ -> nil
    end
  end
end
