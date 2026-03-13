defmodule Mix.Tasks.Experiments.Session do
  use Mix.Task

  alias CriptoTrader.Experiments.Config
  alias CriptoTrader.Improvement.Storage

  @shortdoc "Manage the experiment loop session state"
  @moduledoc """
  Manages priv/experiments/loop_session.json on behalf of the experiment loop skill.
  The skill calls this task instead of writing JSON directly, keeping the file
  format owned by Elixir and invisible to the skill.

  ## Subcommands

      mix experiments.session announce --step STEP [--hypothesis-name NAME]
        [--hypothesis-category CAT] [--hypothesis-description DESC]

  Marks the start of a step. Merges into the existing session file:
  sets status "in_progress", current_step, step_started_at (now). Preserves
  completed_steps. When announcing step 4, clears hypothesis_candidates.

      mix experiments.session add-candidate \\
        --name NAME --description DESC [--investigation-id INV_ID]

  Appends a hypothesis candidate to the hypothesis_candidates list in the session.
  Call once per investigation being advanced in the current round (Step 4 fan-out).

      mix experiments.session checkpoint --step STEP

  Marks a step as done. Appends STEP to completed_steps. Preserves all
  other fields.

      mix experiments.session complete

  Marks the full iteration as done. Writes {"status": "completed"}.

  ## Examples

      mix experiments.session announce --step 4
      mix experiments.session add-candidate \\
        --name "PostShockReversal v2" \\
        --investigation-id inv-1773400000000-1234 \\
        --description "Larger hold window to capture full reversal move"
      mix experiments.session announce --step 5a \\
        --hypothesis-name "VWAP Reversion" \\
        --hypothesis-category mean-reversion \\
        --hypothesis-description "Price reverts to VWAP after deviation"
      mix experiments.session checkpoint --step 4
      mix experiments.session complete
  """

  @impl Mix.Task
  def run([subcommand | args]) do
    case subcommand do
      "announce" -> run_announce(args)
      "add-candidate" -> run_add_candidate(args)
      "checkpoint" -> run_checkpoint(args)
      "complete" -> run_complete()
      other -> Mix.raise("Unknown subcommand: #{other}. Use announce, add-candidate, checkpoint, or complete.")
    end
  end

  def run([]) do
    Mix.raise("Missing subcommand. Use: announce, add-candidate, checkpoint, or complete.")
  end

  # ── announce ────────────────────────────────────────────────────────────────

  defp run_announce(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        switches: [
          step: :string,
          hypothesis_name: :string,
          hypothesis_category: :string,
          hypothesis_description: :string
        ]
      )

    if invalid != [], do: Mix.raise("Invalid arguments: #{inspect(invalid)}")

    step = required!(opts, :step, "--step")
    session = read_session()

    updates = %{
      "status" => "in_progress",
      "current_step" => step,
      "step_started_at" => iso_now()
    }

    # When starting Step 4, reset the candidates list for the new round
    updates =
      if step == "4" do
        Map.put(updates, "hypothesis_candidates", [])
      else
        updates
      end

    updates =
      case build_hypothesis(opts) do
        nil -> updates
        candidate -> Map.put(updates, "hypothesis_candidate", candidate)
      end

    write_session(Map.merge(session, updates))
    Mix.shell().info("Session: announced step #{step}")
  end

  defp build_hypothesis(opts) do
    name = Keyword.get(opts, :hypothesis_name)
    category = Keyword.get(opts, :hypothesis_category)
    description = Keyword.get(opts, :hypothesis_description)

    if name || category || description do
      %{
        "name" => name || "",
        "category" => category || "",
        "description" => description || ""
      }
    end
  end

  # ── add-candidate ────────────────────────────────────────────────────────────

  defp run_add_candidate(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        switches: [
          name: :string,
          description: :string,
          investigation_id: :string
        ]
      )

    if invalid != [], do: Mix.raise("Invalid arguments: #{inspect(invalid)}")

    name = required!(opts, :name, "--name")
    description = Keyword.get(opts, :description, "")
    inv_id = Keyword.get(opts, :investigation_id)

    session = read_session()
    existing = Map.get(session, "hypothesis_candidates", [])

    candidate =
      %{"name" => name, "description" => description}
      |> then(fn c -> if inv_id, do: Map.put(c, "investigation_id", inv_id), else: c end)

    updated = Map.put(session, "hypothesis_candidates", existing ++ [candidate])
    write_session(updated)

    inv_str = if inv_id, do: " [#{inv_id}]", else: ""
    Mix.shell().info("Session: added candidate #{name}#{inv_str}")
  end

  # ── checkpoint ──────────────────────────────────────────────────────────────

  defp run_checkpoint(args) do
    {opts, _, invalid} = OptionParser.parse(args, switches: [step: :string])
    if invalid != [], do: Mix.raise("Invalid arguments: #{inspect(invalid)}")

    step = required!(opts, :step, "--step")
    session = read_session()

    completed = session |> Map.get("completed_steps", []) |> Enum.uniq()
    updated = Map.put(session, "completed_steps", Enum.uniq(completed ++ [step]))

    write_session(updated)
    Mix.shell().info("Session: checkpoint saved for step #{step}")
  end

  # ── complete ─────────────────────────────────────────────────────────────────

  defp run_complete do
    write_session(%{"status" => "completed"})
    Mix.shell().info("Session: iteration complete")
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp read_session do
    case Storage.read_json(Config.session_file(), %{}) do
      {:ok, session} when is_map(session) -> session
      _ -> %{}
    end
  end

  defp write_session(data) do
    case Storage.write_json(Config.session_file(), data) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Failed to write session file: #{inspect(reason)}")
    end
  end

  defp required!(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("Missing required option #{flag}")
    end
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
