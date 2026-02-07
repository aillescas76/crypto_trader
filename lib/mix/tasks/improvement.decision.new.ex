defmodule Mix.Tasks.Improvement.Decision.New do
  use Mix.Task

  alias CriptoTrader.Improvement.Decisions

  @shortdoc "Create a new architecture decision record (ADR)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        switches: [
          title: :string,
          context: :string,
          decision: :string,
          consequences: :string,
          status: :string
        ],
        aliases: [t: :title]
      )

    attrs = %{
      title: Keyword.get(opts, :title, "Untitled Decision"),
      context: Keyword.get(opts, :context),
      decision: Keyword.get(opts, :decision),
      consequences: Keyword.get(opts, :consequences),
      status: Keyword.get(opts, :status, "accepted")
    }

    case Decisions.record(attrs) do
      {:ok, decision} ->
        Mix.shell().info("Created ADR #{decision.id}: #{decision.path}")

      {:error, reason} ->
        Mix.raise("Failed to create ADR: #{inspect(reason)}")
    end
  end
end
