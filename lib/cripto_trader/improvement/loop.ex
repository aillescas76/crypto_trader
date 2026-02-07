defmodule CriptoTrader.Improvement.Loop do
  @moduledoc false

  alias CriptoTrader.Improvement.{KnowledgeBase, TaskExecutor, Tasks}

  @spec run_once(keyword()) :: {:ok, map()} | {:error, term()}
  def run_once(opts \\ []) do
    max_tasks = Keyword.get(opts, :max_tasks, 5)

    with {:ok, pending_tasks} <- Tasks.pending(max_tasks) do
      report =
        Enum.reduce(pending_tasks, %{processed: [], errors: []}, fn task, acc ->
          case process_task(task) do
            {:ok, item} ->
              %{acc | processed: [item | acc.processed]}

            {:error, reason} ->
              %{acc | errors: [%{task_id: task["id"], reason: reason} | acc.errors]}
          end
        end)

      {:ok,
       %{
         processed_count: length(report.processed),
         error_count: length(report.errors),
         processed: Enum.reverse(report.processed),
         errors: Enum.reverse(report.errors)
       }}
    end
  end

  defp process_task(task) do
    with {:ok, _} <- Tasks.set_status(task["id"], "in_progress"),
         {:ok, result} <- TaskExecutor.execute(task),
         {:ok, _updated} <- Tasks.set_status(task["id"], result.status, result),
         {:ok, finding} <- persist_finding(task, result) do
      {:ok,
       %{
         task_id: task["id"],
         task_type: task["type"],
         status: result.status,
         finding_id: finding["id"]
       }}
    end
  end

  defp persist_finding(task, result) do
    KnowledgeBase.add(%{
      task_id: task["id"],
      title: result.summary,
      details: result.details,
      tags: result.tags,
      data: result.data
    })
  end
end
