defmodule CriptoTrader.Improvement.Reports do
  @moduledoc false

  alias CriptoTrader.Improvement.{Config, KnowledgeBase, Requirements, Storage, Tasks}

  @spec write(keyword()) :: {:ok, map()} | {:error, term()}
  def write(opts \\ []) do
    requirements_path = Keyword.get(opts, :requirements_path, "docs/requirements.md")

    with {:ok, tasks} <- Tasks.list(),
         {:ok, findings} <- KnowledgeBase.list() do
      criteria = criteria_or_empty(requirements_path)
      requirements = requirements_summary(criteria, tasks)
      task_counts = task_status_counts(tasks)

      progress_report = %{
        "generated_at" => now_iso(),
        "objective" => "Complete specifications in docs/requirements.md",
        "run_id" => Keyword.get(opts, :run_id),
        "iteration" => Keyword.get(opts, :iteration),
        "stop_reason" => Keyword.get(opts, :stop_reason),
        "codex" => normalize_map(Keyword.get(opts, :codex_result)),
        "loop" => normalize_map(Keyword.get(opts, :loop_result)),
        "requirements" => requirements,
        "tasks" => %{
          "total" => length(tasks),
          "by_status" => task_counts,
          "pending_top" => pending_top(tasks)
        },
        "knowledge_base" => %{
          "findings_total" => length(findings),
          "recent_findings" => recent_findings(findings, 5)
        },
        "budget" => normalize_map(Keyword.get(opts, :budget_snapshot))
      }

      agent_context = %{
        "generated_at" => progress_report["generated_at"],
        "objective" => progress_report["objective"],
        "requirements" => %{
          "coverage_pct" => requirements["coverage_pct"],
          "open_criteria" => requirements["open_criteria"]
        },
        "pending_tasks" => pending_top(tasks),
        "recent_findings" => recent_findings(findings, 8),
        "budget" => progress_report["budget"],
        "recommended_next_actions" => recommended_actions(requirements, tasks),
        "resume_command" =>
          "mix improvement.loop.autorun --iterations 100 --sleep-ms 300 --seed-requirements --stop-when-clean"
      }

      with :ok <- Storage.write_json(Config.progress_report_file(), progress_report),
           :ok <- Storage.write_json(Config.agent_context_file(), agent_context) do
        {:ok, %{progress_report: progress_report, agent_context: agent_context}}
      end
    end
  end

  defp criteria_or_empty(path) do
    case Requirements.acceptance_criteria(path) do
      {:ok, criteria} -> criteria
      {:error, _reason} -> []
    end
  end

  defp requirements_summary(criteria, tasks) do
    by_criterion =
      tasks
      |> Enum.filter(&(&1["type"] == "requirement_gap"))
      |> Enum.reduce(%{}, fn task, acc ->
        criterion_id = get_in(task, ["payload", "criterion_id"])

        if is_binary(criterion_id) do
          Map.put(acc, criterion_id, task["status"])
        else
          acc
        end
      end)

    criteria_with_status =
      Enum.map(criteria, fn criterion ->
        status = Map.get(by_criterion, criterion["id"], "missing_task")

        %{
          "id" => criterion["id"],
          "description" => criterion["description"],
          "status" => status
        }
      end)

    total = length(criteria_with_status)
    met = Enum.count(criteria_with_status, &(&1["status"] == "done"))
    open = total - met

    coverage_pct =
      if total == 0 do
        0.0
      else
        Float.round(met * 100.0 / total, 2)
      end

    %{
      "total" => total,
      "met" => met,
      "open" => open,
      "coverage_pct" => coverage_pct,
      "open_criteria" => Enum.filter(criteria_with_status, &(&1["status"] != "done")),
      "all" => criteria_with_status
    }
  end

  defp task_status_counts(tasks) do
    tasks
    |> Enum.reduce(%{}, fn task, acc ->
      Map.update(acc, task["status"], 1, &(&1 + 1))
    end)
  end

  defp pending_top(tasks) do
    tasks
    |> Enum.filter(&(&1["status"] == "pending"))
    |> Enum.sort_by(fn task -> {priority_rank(task["priority"]), task["id"]} end)
    |> Enum.take(10)
    |> Enum.map(fn task ->
      %{
        "id" => task["id"],
        "title" => task["title"],
        "type" => task["type"],
        "priority" => task["priority"],
        "description" => task["description"]
      }
    end)
  end

  defp recent_findings(findings, limit) do
    findings
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.reverse()
    |> Enum.map(fn finding ->
      %{
        "id" => finding["id"],
        "timestamp" => finding["timestamp"],
        "task_id" => finding["task_id"],
        "title" => finding["title"],
        "tags" => finding["tags"]
      }
    end)
  end

  defp recommended_actions(requirements, tasks) do
    cond do
      requirements["open"] > 0 ->
        [
          "Run Codex with focus on top open acceptance criterion.",
          "Re-seed requirements and re-run improvement loop checks.",
          "Create ADRs for strategy-impacting implementation decisions."
        ]

      Enum.any?(tasks, &(&1["status"] in ["failed", "blocked"])) ->
        [
          "Inspect failed or blocked tasks and create dedicated remediation tasks.",
          "Capture findings in knowledge base before next autonomous run."
        ]

      true ->
        [
          "No open requirement gaps detected by automated checks.",
          "Run a manual review pass and extend checks for deeper validation."
        ]
    end
  end

  defp priority_rank("high"), do: 0
  defp priority_rank("normal"), do: 1
  defp priority_rank("low"), do: 2
  defp priority_rank(_other), do: 1

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_other), do: %{}

  defp now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
