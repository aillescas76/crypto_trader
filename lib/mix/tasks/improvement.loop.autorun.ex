defmodule Mix.Tasks.Improvement.Loop.Autorun do
  use Mix.Task

  alias CriptoTrader.Improvement.AutonomousLoop

  @shortdoc "Run autonomous improvement loop (can invoke Codex)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        switches: [
          iterations: :integer,
          sleep_ms: :integer,
          max_tasks: :integer,
          requirements_path: :string,
          seed_requirements: :boolean,
          stop_when_clean: :boolean,
          codex_enabled: :boolean,
          min_iteration_budget: :integer
        ]
      )

    run_opts =
      []
      |> put_opt(opts, :iterations)
      |> put_opt(opts, :sleep_ms)
      |> put_opt(opts, :max_tasks)
      |> put_opt(opts, :requirements_path)
      |> put_opt(opts, :seed_requirements)
      |> put_opt(opts, :stop_when_clean)
      |> put_opt(opts, :codex_enabled)
      |> put_opt(opts, :min_iteration_budget)

    case AutonomousLoop.run(run_opts) do
      {:ok, summary} ->
        Mix.shell().info("run_id=#{summary.run_id}")
        Mix.shell().info("completed_iterations=#{summary.completed_iterations}")
        Mix.shell().info("stop_reason=#{summary.stop_reason}")

      {:error, %{reason: reason, summary: summary}} ->
        Mix.shell().error("run_id=#{summary.run_id}")
        Mix.shell().error("completed_iterations=#{summary.completed_iterations}")
        Mix.shell().error("stop_reason=#{summary.stop_reason}")
        Mix.raise("Autonomous loop failed: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("Autonomous loop failed: #{inspect(reason)}")
    end
  end

  defp put_opt(acc, opts, key) do
    if Keyword.has_key?(opts, key) do
      Keyword.put(acc, key, Keyword.get(opts, key))
    else
      acc
    end
  end
end
