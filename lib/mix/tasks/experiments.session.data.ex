defmodule Mix.Tasks.Experiments.Session.Data do
  use Mix.Task

  alias CriptoTrader.Experiments.State

  @shortdoc "Save or read per-step research data for the experiment loop session"
  @moduledoc """
  Saves or reads research data for a specific step in the current session.
  Data is stored in priv/experiments/session_data/<step>.md and visible in
  the web dashboard at /session.

  ## Read stored data for a step

      mix experiments.session.data --step 4

  ## Save data from a file

      mix experiments.session.data --step 4 --file /tmp/step4_briefs.md

  ## Examples

      # Save research briefs after Step 4 agents return
      mix experiments.session.data --step 4 --file /tmp/briefs.md

      # Read back on resume
      mix experiments.session.data --step 4
  """

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args, switches: [step: :string, file: :string])

    if invalid != [], do: Mix.raise("Invalid arguments: #{inspect(invalid)}")

    step = required!(opts, :step, "--step")
    Mix.Task.run("app.start", [])

    case Keyword.get(opts, :file) do
      nil -> read_data(step)
      path -> save_data(step, path)
    end
  end

  defp read_data(step) do
    case State.read_session_data(step) do
      {:ok, content} ->
        Mix.shell().info(content)

      {:error, :not_found} ->
        Mix.shell().info("No data saved for step #{step}.")
    end
  end

  defp save_data(step, path) do
    content =
      case File.read(path) do
        {:ok, c} -> c
        {:error, reason} -> Mix.raise("Cannot read file #{path}: #{inspect(reason)}")
      end

    case State.save_session_data(step, content) do
      :ok ->
        words = content |> String.split() |> length()
        Mix.shell().info("Saved step #{step} data (#{words} words) to session.")

      {:error, reason} ->
        Mix.raise("Failed to save session data: #{inspect(reason)}")
    end
  end

  defp required!(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("Missing required option #{flag}")
    end
  end
end
