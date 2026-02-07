defmodule CriptoTrader.Improvement.TaskExecutor do
  @moduledoc false

  alias CriptoTrader.Improvement.{Decisions, RequirementChecks}

  @spec execute(map()) :: {:ok, map()} | {:error, term()}
  def execute(task) do
    case task["type"] do
      "note" ->
        {:ok, execute_note(task)}

      "requirement_gap" ->
        {:ok, execute_requirement_gap(task)}

      "decision" ->
        execute_decision(task)

      type ->
        {:ok,
         %{
           status: "blocked",
           summary: "Unknown task type",
           details: "Task type #{inspect(type)} is not supported.",
           tags: ["improvement", "blocked"],
           data: %{}
         }}
    end
  end

  defp execute_note(task) do
    payload = task["payload"] || %{}

    %{
      status: "done",
      summary: payload["summary"] || task["title"],
      details: payload["details"] || task["description"],
      tags: ["improvement", "note"],
      data: payload
    }
  end

  defp execute_requirement_gap(task) do
    payload = task["payload"] || %{}
    criterion_id = payload["criterion_id"] || "unknown"
    description = payload["criterion_description"] || task["description"] || task["title"]

    result = RequirementChecks.check(criterion_id, description)

    status =
      case result.status do
        :met -> "done"
        :gap -> "failed"
        :unknown -> "blocked"
      end

    %{
      status: status,
      summary: "#{criterion_id}: #{result.summary}",
      details: result.details,
      tags: result.tags,
      data: %{
        criterion_id: criterion_id,
        evidence: result.evidence,
        check_status: to_string(result.status)
      }
    }
  end

  defp execute_decision(task) do
    payload = task["payload"] || %{}

    attrs = %{
      title: payload["title"] || task["title"],
      context: payload["context"] || task["description"],
      decision: payload["decision"],
      consequences: payload["consequences"],
      status: payload["status"] || "accepted"
    }

    case Decisions.record(attrs) do
      {:ok, decision} ->
        {:ok,
         %{
           status: "done",
           summary: "ADR recorded",
           details: "Created #{decision.path}",
           tags: ["improvement", "adr"],
           data: %{adr_id: decision.id, adr_path: decision.path}
         }}

      {:error, reason} ->
        {:ok,
         %{
           status: "failed",
           summary: "ADR creation failed",
           details: inspect(reason),
           tags: ["improvement", "adr", "error"],
           data: %{error: inspect(reason)}
         }}
    end
  end
end
