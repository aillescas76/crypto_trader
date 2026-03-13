defmodule Mix.Tasks.Experiments.Investigation do
  use Mix.Task

  alias CriptoTrader.Experiments.State

  @shortdoc "Manage investigation lines in the experiment loop"
  @moduledoc """
  Manages named lines of investigation that group related micro-experiments.

  An investigation tracks a focused research direction (e.g. "PostShockReversal sizing
  variants"). Each micro-variant experiment is linked to its parent investigation so the
  loop can track progress and detect when a line has stalled.

  ## Subcommands

      mix experiments.investigation create \\
        --name "Short concept name" \\
        --concept "One sentence describing the research direction" \\
        [--parent EXP_ID]

  Creates a new active investigation. --parent links it to the original experiment
  that spawned this line of research.

      mix experiments.investigation discard \\
        --id INV_ID \\
        --reason "Why this line is being abandoned"

  Marks an investigation as discarded. The loop will no longer advance it.
  This is a manual, irreversible action — the loop only recommends discard,
  it never auto-discards.

      mix experiments.investigation list

  Lists all investigations grouped by status (active, graduated, discarded).

  ## Examples

      mix experiments.investigation create \\
        --name "PostShockReversal sizing" \\
        --concept "PSR signal with aggressive sizing to overcome out-of-market penalty" \\
        --parent exp-1773392192617-6205

      mix experiments.investigation discard \\
        --id inv-1773400000000-1234 \\
        --reason "3 consecutive variants show no improvement — sizing alone cannot overcome structural out-of-market problem"

      mix experiments.investigation list
  """

  @impl Mix.Task
  def run([subcommand | args]) do
    Mix.Task.run("app.start", [])

    case subcommand do
      "create" -> run_create(args)
      "freeze" -> run_freeze(args)
      "unfreeze" -> run_unfreeze(args)
      "discard" -> run_discard(args)
      "list" -> run_list()
      other -> Mix.raise("Unknown subcommand: #{other}. Use create, freeze, unfreeze, discard, or list.")
    end
  end

  def run([]) do
    Mix.raise("Missing subcommand. Use: create, freeze, unfreeze, discard, or list.")
  end

  # ── create ──────────────────────────────────────────────────────────────────

  defp run_create(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        switches: [
          name: :string,
          concept: :string,
          parent: :string
        ]
      )

    if invalid != [], do: Mix.raise("Invalid arguments: #{inspect(invalid)}")

    name = required!(opts, :name, "--name")
    concept = required!(opts, :concept, "--concept")
    parent = Keyword.get(opts, :parent)

    inv = %{
      "name" => name,
      "concept" => concept,
      "parent_experiment_id" => parent
    }

    case State.add_investigation(inv) do
      {:ok, id} ->
        Mix.shell().info("Created investigation #{id}")
        Mix.shell().info("  name: #{name}")
        Mix.shell().info("  concept: #{concept}")
        if parent, do: Mix.shell().info("  parent: #{parent}")

      {:error, reason} ->
        Mix.raise("Failed to create investigation: #{inspect(reason)}")
    end
  end

  # ── freeze / unfreeze ────────────────────────────────────────────────────────

  defp run_freeze(args) do
    {opts, _, invalid} = OptionParser.parse(args, switches: [id: :string])
    if invalid != [], do: Mix.raise("Invalid arguments: #{inspect(invalid)}")
    id = required!(opts, :id, "--id")

    case State.freeze_investigation(id) do
      :ok -> Mix.shell().info("Frozen investigation #{id} — awaiting human decision at /investigations")
      {:error, reason} -> Mix.raise("Failed to freeze investigation: #{inspect(reason)}")
    end
  end

  defp run_unfreeze(args) do
    {opts, _, invalid} = OptionParser.parse(args, switches: [id: :string])
    if invalid != [], do: Mix.raise("Invalid arguments: #{inspect(invalid)}")
    id = required!(opts, :id, "--id")

    case State.unfreeze_investigation(id) do
      :ok -> Mix.shell().info("Unfrozen investigation #{id} — back to active")
      {:error, reason} -> Mix.raise("Failed to unfreeze investigation: #{inspect(reason)}")
    end
  end

  # ── discard ──────────────────────────────────────────────────────────────────

  defp run_discard(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        switches: [
          id: :string,
          reason: :string
        ]
      )

    if invalid != [], do: Mix.raise("Invalid arguments: #{inspect(invalid)}")

    id = required!(opts, :id, "--id")
    reason = required!(opts, :reason, "--reason")

    case State.discard_investigation(id, reason) do
      :ok ->
        Mix.shell().info("Discarded investigation #{id}")
        Mix.shell().info("  reason: #{reason}")

      {:error, reason_err} ->
        Mix.raise("Failed to discard investigation: #{inspect(reason_err)}")
    end
  end

  # ── list ─────────────────────────────────────────────────────────────────────

  defp run_list do
    case State.list_investigations() do
      {:ok, []} ->
        Mix.shell().info("No investigations yet.")

      {:ok, investigations} ->
        active = Enum.filter(investigations, &(Map.get(&1, "status") == "active"))
        graduated = Enum.filter(investigations, &(Map.get(&1, "status") == "graduated"))
        discarded = Enum.filter(investigations, &(Map.get(&1, "status") == "discarded"))

        if active != [] do
          Mix.shell().info("--- ACTIVE ---")
          Enum.each(active, &print_investigation/1)
        end

        if graduated != [] do
          Mix.shell().info("--- GRADUATED ---")
          Enum.each(graduated, &print_investigation/1)
        end

        if discarded != [] do
          Mix.shell().info("--- DISCARDED ---")
          Enum.each(discarded, &print_investigation/1)
        end

      {:error, reason} ->
        Mix.raise("Failed to list investigations: #{inspect(reason)}")
    end
  end

  defp print_investigation(inv) do
    id = Map.get(inv, "id", "?")
    status = inv |> Map.get("status", "?") |> String.upcase()
    name = Map.get(inv, "name", "?")
    n_exps = inv |> Map.get("experiments", []) |> length()
    reason = Map.get(inv, "discard_reason")

    reason_str = if reason, do: " | reason: #{String.slice(reason, 0, 80)}", else: ""
    Mix.shell().info("[#{id}] #{status} | #{name} | #{n_exps} experiments#{reason_str}")
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp required!(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("Missing required option #{flag}")
    end
  end
end
