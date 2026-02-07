defmodule Mix.Tasks.Improvement.Tasks.SeedRequirements do
  use Mix.Task

  alias CriptoTrader.Improvement.Tasks

  @shortdoc "Create requirement-check tasks from docs/requirements.md"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, switches: [path: :string])

    case Tasks.seed_from_requirements(Keyword.get(opts, :path, "docs/requirements.md")) do
      {:ok, %{created: created, reactivated: reactivated, total_criteria: total}} ->
        Mix.shell().info(
          "Seeded #{length(created)} new tasks, reactivated #{length(reactivated)} tasks from #{total} acceptance criteria"
        )

      {:error, reason} ->
        Mix.raise("Failed to seed requirement tasks: #{inspect(reason)}")
    end
  end
end
