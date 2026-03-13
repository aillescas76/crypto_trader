defmodule Mix.Tasks.Experiments.Principles.Add do
  use Mix.Task

  alias CriptoTrader.Experiments.State

  @shortdoc "Add a generalizable principle to principles.json"
  @moduledoc """
  Adds a principle entry to priv/experiments/principles.json.

  Principles are generalizable truths about market mechanics or strategy design
  that persist across iterations and inform future research.

  ## Usage

      mix experiments.principles.add \\
        --principle "Out-of-market strategies can't beat BnH PnL% unless sizing >= 30-50%" \\
        [--evidence exp-id1,exp-id2] \\
        [--tags tag1,tag2]
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        switches: [principle: :string, evidence: :string, tags: :string]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    text = required!(opts, :principle, "--principle")

    evidence =
      opts
      |> Keyword.get(:evidence, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    tags =
      opts
      |> Keyword.get(:tags, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Mix.Task.run("app.start", [])

    principle = %{
      "principle" => text,
      "evidence" => evidence,
      "tags" => tags
    }

    case State.add_principle(principle) do
      {:ok, id} ->
        Mix.shell().info("Added principle #{id}")

      {:error, reason} ->
        Mix.raise("Failed to add principle: #{inspect(reason)}")
    end
  end

  defp required!(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("Missing required option #{flag}")
    end
  end
end
