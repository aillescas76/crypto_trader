defmodule Mix.Tasks.Experiments.Context do
  use Mix.Task

  alias CriptoTrader.Experiments.State

  @shortdoc "Print full experiment loop context for the AI agent"
  @moduledoc """
  Prints a human-readable summary of the full experiment loop state:
  current session, experiments, findings, and feedback.

  The skill calls this at Steps 0 and 1 instead of reading raw JSON files.

      mix experiments.context
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start", [])
    print_session()
    print_experiments()
    print_principles()
    print_findings()
    print_investigations()
    print_feedback()
  end

  defp print_session do
    session = State.read_session()

    Mix.shell().info("=== SESSION ===")

    if map_size(session) == 0 do
      Mix.shell().info("No active session.")
    else
      status = Map.get(session, "status", "unknown")
      current = Map.get(session, "current_step", "-")
      completed = Map.get(session, "completed_steps", [])
      started_at = Map.get(session, "step_started_at")
      elapsed =
        case started_at && DateTime.from_iso8601(started_at) do
          {:ok, dt, _} -> "#{DateTime.diff(DateTime.utc_now(), dt, :second) |> div(60)} min"
          _ -> nil
        end

      elapsed_str = if elapsed, do: " | Running: #{elapsed}", else: ""
      Mix.shell().info("Status: #{status} | Step: #{current}#{elapsed_str}")
      Mix.shell().info("Completed steps: #{Enum.join(completed, ", ")}")

      # Support both singular hypothesis_candidate and plural hypothesis_candidates
      candidates =
        case Map.get(session, "hypothesis_candidates") do
          list when is_list(list) and list != [] -> list
          _ ->
            case Map.get(session, "hypothesis_candidate") do
              nil -> []
              c -> [c]
            end
        end

      Enum.each(candidates, fn candidate ->
        name = Map.get(candidate, "name", "")
        inv_id = Map.get(candidate, "investigation_id")
        desc = Map.get(candidate, "description", "")
        inv_str = if inv_id, do: " [#{inv_id}]", else: ""
        Mix.shell().info("Candidate: #{name}#{inv_str}")
        if desc != "", do: Mix.shell().info("  #{desc}")
      end)
    end

    Mix.shell().info("")
  end

  defp print_experiments do
    Mix.shell().info("=== EXPERIMENTS ===")

    case State.list_experiments() do
      {:ok, []} ->
        Mix.shell().info("No experiments yet.")

      {:ok, experiments} ->
        Enum.each(experiments, fn exp ->
          id = Map.get(exp, "id", "?")
          strategy = exp |> Map.get("strategy_module", "") |> short_module()
          status = Map.get(exp, "status", "?")
          verdict = format_verdict(Map.get(exp, "verdict"))
          train = format_pnl(Map.get(exp, "training_result"))
          val = format_pnl(Map.get(exp, "validation_result"))
          Mix.shell().info("[#{id}] #{status} | #{strategy} | Train: #{train} | Val: #{val} | #{verdict}")
        end)

      _ ->
        Mix.shell().info("Error reading experiments.")
    end

    Mix.shell().info("")
  end

  defp print_principles do
    Mix.shell().info("=== PRINCIPLES ===")

    case State.list_principles() do
      {:ok, []} ->
        Mix.shell().info("No principles yet.")

      {:ok, principles} ->
        Enum.each(principles, fn p ->
          id = Map.get(p, "id", "?")
          text = Map.get(p, "principle", "?")
          tags = p |> Map.get("tags", []) |> Enum.join(", ")
          evidence = p |> Map.get("evidence", []) |> Enum.join(", ")
          evidence_str = if evidence != "", do: " | evidence: #{evidence}", else: ""
          tags_str = if tags != "", do: " | tags: #{tags}", else: ""
          Mix.shell().info("[#{id}] #{text}#{tags_str}#{evidence_str}")
        end)

      _ ->
        Mix.shell().info("Error reading principles.")
    end

    Mix.shell().info("")
  end

  defp print_findings do
    Mix.shell().info("=== FINDINGS ===")

    case State.list_findings() do
      {:ok, []} ->
        Mix.shell().info("No findings yet.")

      {:ok, findings} ->
        Enum.each(findings, fn f ->
          id = Map.get(f, "id", "?")
          title = Map.get(f, "title", "Untitled")
          tags = f |> Map.get("tags", []) |> Enum.join(", ")
          Mix.shell().info("[#{id}] #{title} | tags: #{tags}")

          if body = Map.get(f, "body") do
            body
            |> String.split("\n")
            |> Enum.each(fn line -> Mix.shell().info("  #{line}") end)
          end
        end)

      _ ->
        Mix.shell().info("Error reading findings.")
    end

    Mix.shell().info("")
  end

  defp print_investigations do
    Mix.shell().info("=== INVESTIGATIONS ===")

    case {State.list_investigations(), State.list_experiments()} do
      {{:ok, []}, _} ->
        Mix.shell().info("No investigations yet.")
        Mix.shell().info("")

      {{:ok, investigations}, {:ok, experiments}} ->
        Enum.each(investigations, fn inv ->
          id = Map.get(inv, "id", "?")
          status = inv |> Map.get("status", "?") |> String.upcase()
          name = Map.get(inv, "name", "?")
          concept = Map.get(inv, "concept", "")
          inv_exp_ids = Map.get(inv, "experiments", [])
          n_exps = length(inv_exp_ids)
          reason = Map.get(inv, "discard_reason")

          # Compute no_improvement_streak and in_flight from linked experiments
          inv_exps =
            experiments
            |> Enum.filter(fn e -> Map.get(e, "id") in inv_exp_ids end)
            |> Enum.sort_by(fn e -> Map.get(e, "queued_at", "") end)

          in_flight =
            Enum.any?(inv_exps, fn e ->
              Map.get(e, "status") in ["pending", "running"]
            end)

          streak = compute_no_improvement_streak(inv_exps)

          streak_str = if streak > 0, do: " | streak: #{streak}", else: ""
          in_flight_str = " | in_flight: #{in_flight}"
          reason_str = if reason, do: " | reason: #{String.slice(reason, 0, 80)}", else: ""

          Mix.shell().info(
            "[#{id}] #{status} | #{name} | #{n_exps} exps#{streak_str}#{in_flight_str}#{reason_str}"
          )

          if concept != "" do
            Mix.shell().info("  concept: #{concept}")
          end

          if streak >= 3 and status == "ACTIVE" do
            Mix.shell().info(
              "  ⚠ STALL: #{streak} consecutive experiments with no improvement — freeze this investigation:"
            )

            Mix.shell().info(
              "    mix experiments.investigation freeze --id #{id}"
            )
          end

          if status == "FROZEN" do
            Mix.shell().info(
              "  ⏸ Awaiting human decision at /investigations (Resume or Discard)"
            )
          end
        end)

        Mix.shell().info("")

      _ ->
        Mix.shell().info("Error reading investigations.")
        Mix.shell().info("")
    end
  end

  # Returns the count of trailing experiments where training_pnl_pct improved
  # by less than 0.5% over the prior experiment in this investigation.
  defp compute_no_improvement_streak(exps) do
    finished =
      Enum.filter(exps, fn e ->
        Map.get(e, "status") in ["passed", "failed"] and
          get_in(e, ["training_result", "pnl_pct"]) != nil
      end)

    case finished do
      [] ->
        0

      [_] ->
        0

      _ ->
        pnl_series = Enum.map(finished, fn e -> get_in(e, ["training_result", "pnl_pct"]) || 0.0 end)

        pnl_series
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, curr] -> curr - prev end)
        |> Enum.reverse()
        |> Enum.take_while(fn delta -> delta < 0.5 end)
        |> length()
    end
  end

  defp print_feedback do
    Mix.shell().info("=== FEEDBACK ===")

    case State.list_feedback() do
      {:ok, []} ->
        Mix.shell().info("No feedback yet.")

      {:ok, feedback} ->
        unacked = Enum.reject(feedback, &Map.get(&1, "acknowledged"))
        acked = Enum.filter(feedback, &Map.get(&1, "acknowledged"))

        if unacked != [] do
          Mix.shell().info("--- UNACKNOWLEDGED (act on these) ---")

          Enum.each(unacked, fn f ->
            id = Map.get(f, "id", "?")
            note = Map.get(f, "note", "")
            tags = f |> Map.get("tags", []) |> Enum.join(", ")
            Mix.shell().info("[#{id}] #{note} | tags: #{tags}")
          end)
        end

        if acked != [] do
          Mix.shell().info("--- acknowledged ---")

          Enum.each(acked, fn f ->
            id = Map.get(f, "id", "?")
            note = Map.get(f, "note", "")
            Mix.shell().info("[#{id}] #{note}")
          end)
        end

      _ ->
        Mix.shell().info("Error reading feedback.")
    end
  end

  defp short_module(mod) when is_binary(mod),
    do: mod |> String.split(".") |> List.last() || "?"

  defp short_module(_), do: "?"

  defp format_verdict(%{"verdict" => v}), do: String.upcase(v)
  defp format_verdict(_), do: "-"

  defp format_pnl(%{"pnl_pct" => pct}) when is_number(pct),
    do: "#{Float.round(pct * 1.0, 2)}%"

  defp format_pnl(_), do: "-"
end
