defmodule Mix.Tasks.Experiments.Feedback.Acknowledge do
  use Mix.Task

  alias CriptoTrader.Experiments.State

  @shortdoc "Acknowledge a feedback entry"
  @moduledoc """
  Marks a feedback entry as acknowledged so it won't be shown as pending
  to the experiment loop agent on the next iteration.

  ## Usage

      mix experiments.feedback.acknowledge --id fbk-<ID>

  ## Example

      mix experiments.feedback.acknowledge --id fbk-1234567890-0042
  """

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, switches: [id: :string])
    if invalid != [], do: Mix.raise("Invalid arguments: #{inspect(invalid)}")

    id = required!(opts, :id, "--id")
    Mix.Task.run("app.start", [])

    case State.acknowledge_feedback(id) do
      :ok -> Mix.shell().info("Acknowledged feedback #{id}")
      {:error, reason} -> Mix.raise("Failed to acknowledge feedback: #{inspect(reason)}")
    end
  end

  defp required!(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("Missing required option #{flag}")
    end
  end
end
