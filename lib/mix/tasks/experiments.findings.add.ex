defmodule Mix.Tasks.Experiments.Findings.Add do
  use Mix.Task

  alias CriptoTrader.Experiments.State

  @shortdoc "Add a finding to findings.json"
  @moduledoc """
  Adds a finding entry to priv/experiments/findings.json.

  ## Usage

      mix experiments.findings.add \\
        --title "Finding title" \\
        --experiment EXP_ID \\
        [--tags tag1,tag2]
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        switches: [title: :string, experiment: :string, tags: :string]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    title = required!(opts, :title, "--title")
    experiment_id = required!(opts, :experiment, "--experiment")

    tags =
      opts
      |> Keyword.get(:tags, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Mix.Task.run("app.start", [])

    finding = %{
      "title" => title,
      "experiment_id" => experiment_id,
      "tags" => tags
    }

    case State.add_finding(finding) do
      {:ok, id} ->
        Mix.shell().info("Added finding #{id}")

      {:error, reason} ->
        Mix.raise("Failed to add finding: #{inspect(reason)}")
    end
  end

  defp required!(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("Missing required option #{flag}")
    end
  end
end
