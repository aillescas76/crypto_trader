defmodule CriptoTrader.Improvement.AutonomousLoopTest do
  use ExUnit.Case, async: false

  alias CriptoTrader.Improvement.{AutonomousLoop, Budget, Config, KnowledgeBase, Tasks}

  setup do
    original = Application.get_env(:cripto_trader, :improvement)

    base =
      Path.join(
        System.tmp_dir!(),
        "cripto_trader_improvement_autorun_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:cripto_trader, :improvement,
      storage_dir: Path.join(base, "storage"),
      adr_dir: Path.join(base, "adr"),
      weekly_budget_seconds: 10,
      codex_timeout_ms: 1000
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:cripto_trader, :improvement)
      else
        Application.put_env(:cripto_trader, :improvement, original)
      end

      File.rm_rf(base)
    end)

    :ok
  end

  test "runs one autonomous iteration without codex" do
    assert {:ok, _} = Budget.reset()

    assert {:ok, _task} =
             Tasks.create(%{
               "title" => "Document a safe default",
               "description" => "Paper mode must remain default",
               "type" => "note",
               "payload" => %{"summary" => "Safety check logged"}
             })

    assert {:ok, summary} =
             AutonomousLoop.run(
               iterations: 1,
               sleep_ms: 0,
               max_tasks: 2,
               codex_enabled: false,
               seed_requirements: false
             )

    assert summary.completed_iterations == 1
    assert summary.stop_reason == "stopped_iteration_cap"

    assert {:ok, findings} = KnowledgeBase.list()
    assert length(findings) == 1
    assert Enum.at(findings, 0)["title"] == "Safety check logged"

    loop_state = Config.loop_state_file() |> File.read!() |> Jason.decode!()
    assert loop_state["run_id"] == summary.run_id
    assert loop_state["status"] == "stopped"
    assert loop_state["last_stop_reason"] == "stopped_iteration_cap"

    progress_report = Config.progress_report_file() |> File.read!() |> Jason.decode!()
    assert progress_report["run_id"] == summary.run_id
    assert progress_report["stop_reason"] == "stopped_iteration_cap"
    assert progress_report["codex"]["invoked"] == false
    assert progress_report["loop"]["processed_count"] == 1
  end

  test "re-seeds requirements by default so failed checks are retried" do
    assert {:ok, _} = Budget.reset()

    requirements_path =
      Path.join(
        System.tmp_dir!(),
        "cripto_trader_requirements_#{System.unique_integer([:positive])}.md"
      )

    File.write!(
      requirements_path,
      """
      ## Acceptance Criteria
      - A CLI command fetches candles for at least one symbol and interval.
      """
    )

    on_exit(fn -> File.rm(requirements_path) end)

    assert {:ok, task} =
             Tasks.create(%{
               "title" => "Requirement check ac-1",
               "description" =>
                 "A CLI command fetches candles for at least one symbol and interval.",
               "type" => "requirement_gap",
               "status" => "failed",
               "payload" => %{
                 "criterion_id" => "ac-1",
                 "criterion_description" =>
                   "A CLI command fetches candles for at least one symbol and interval."
               }
             })

    assert {:ok, summary} =
             AutonomousLoop.run(
               iterations: 1,
               sleep_ms: 0,
               max_tasks: 1,
               codex_enabled: false,
               requirements_path: requirements_path
             )

    assert summary.completed_iterations == 1
    assert [%{processed_count: 1}] = summary.iterations

    assert {:ok, [updated_task]} = Tasks.list()
    assert updated_task["id"] == task["id"]
    assert is_map(updated_task["last_result"])
    assert get_in(updated_task, ["last_result", "data", "criterion_id"]) == "ac-1"
  end

  test "pauses when budget is exhausted" do
    assert {:ok, _} = Budget.reset()
    assert {:ok, _} = Budget.consume(10)

    assert {:ok, summary} =
             AutonomousLoop.run(
               iterations: 2,
               sleep_ms: 0,
               max_tasks: 1,
               codex_enabled: false,
               seed_requirements: false,
               min_iteration_budget: 1
             )

    assert summary.completed_iterations == 0
    assert summary.stop_reason == "paused_budget_exhausted"
  end
end
