defmodule Mix.Tasks.Improvement.Task.New do
  use Mix.Task

  alias CriptoTrader.Improvement.Tasks

  @shortdoc "Create an improvement task"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        switches: [
          title: :string,
          description: :string,
          type: :string,
          priority: :string,
          payload: :string
        ],
        aliases: [t: :title, d: :description]
      )

    attrs = %{
      title: Keyword.get(opts, :title, "Untitled task"),
      description: Keyword.get(opts, :description),
      type: Keyword.get(opts, :type, "note"),
      priority: Keyword.get(opts, :priority, "normal"),
      payload: parse_payload(Keyword.get(opts, :payload))
    }

    case Tasks.create(attrs) do
      {:ok, task} ->
        Mix.shell().info("Created task ##{task["id"]}: #{task["title"]} (#{task["type"]})")

      {:error, reason} ->
        Mix.raise("Failed to create task: #{inspect(reason)}")
    end
  end

  defp parse_payload(nil), do: %{}

  defp parse_payload(json) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{"raw" => json}
    end
  end
end
