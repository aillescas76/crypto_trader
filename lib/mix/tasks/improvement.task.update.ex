defmodule Mix.Tasks.Improvement.Task.Update do
  use Mix.Task

  alias CriptoTrader.Improvement.Tasks

  @shortdoc "Update an improvement task"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        switches: [
          id: :integer,
          title: :string,
          description: :string,
          status: :string,
          priority: :string,
          payload: :string
        ],
        aliases: [i: :id]
      )

    id = Keyword.get(opts, :id) || Mix.raise("--id is required")

    attrs =
      %{}
      |> put_if_present("title", Keyword.get(opts, :title))
      |> put_if_present("description", Keyword.get(opts, :description))
      |> put_if_present("status", Keyword.get(opts, :status))
      |> put_if_present("priority", Keyword.get(opts, :priority))
      |> put_if_present("payload", parse_payload(Keyword.get(opts, :payload)))

    case Tasks.update(id, attrs) do
      {:ok, task} ->
        Mix.shell().info("Updated task ##{task["id"]}: status=#{task["status"]}")

      {:error, reason} ->
        Mix.raise("Failed to update task: #{inspect(reason)}")
    end
  end

  defp parse_payload(nil), do: nil

  defp parse_payload(json) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{"raw" => json}
    end
  end

  defp put_if_present(attrs, _key, nil), do: attrs
  defp put_if_present(attrs, key, value), do: Map.put(attrs, key, value)
end
