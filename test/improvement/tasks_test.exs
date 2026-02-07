defmodule CriptoTrader.Improvement.TasksTest do
  use ExUnit.Case, async: false

  alias CriptoTrader.Improvement.Tasks

  setup do
    original = Application.get_env(:cripto_trader, :improvement)

    base =
      Path.join(
        System.tmp_dir!(),
        "cripto_trader_improvement_tasks_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:cripto_trader, :improvement,
      storage_dir: Path.join(base, "storage"),
      adr_dir: Path.join(base, "adr")
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

  test "creates and updates tasks" do
    assert {:ok, task} = Tasks.create(%{"title" => "Review gap", "type" => "note"})
    assert task["id"] == 1
    assert task["status"] == "pending"

    assert {:ok, updated} = Tasks.update(1, %{"status" => "done", "priority" => "high"})
    assert updated["status"] == "done"
    assert updated["priority"] == "high"

    assert {:ok, tasks} = Tasks.list()
    assert length(tasks) == 1
  end

  test "seeds requirement tasks idempotently" do
    requirements_path =
      Path.join(System.tmp_dir!(), "requirements_#{System.unique_integer([:positive])}.md")

    File.write!(
      requirements_path,
      """
      # Requirements

      ## Acceptance Criteria
      - First criterion.
      - Second criterion.
      """
    )

    assert {:ok, first_seed} = Tasks.seed_from_requirements(requirements_path)
    assert length(first_seed.created) == 2
    assert first_seed.reactivated == []

    assert {:ok, second_seed} = Tasks.seed_from_requirements(requirements_path)
    assert second_seed.created == []
    assert second_seed.reactivated == []
  end

  test "re-seeding reactivates failed requirement tasks without creating duplicates" do
    requirements_path =
      Path.join(System.tmp_dir!(), "requirements_retry_#{System.unique_integer([:positive])}.md")

    File.write!(
      requirements_path,
      """
      # Requirements

      ## Acceptance Criteria
      - First criterion.
      """
    )

    assert {:ok, first_seed} = Tasks.seed_from_requirements(requirements_path)
    assert length(first_seed.created) == 1
    assert first_seed.reactivated == []

    [task] = first_seed.created

    assert {:ok, _updated} =
             Tasks.update(task["id"], %{"status" => "failed", "last_result" => %{}})

    assert {:ok, second_seed} = Tasks.seed_from_requirements(requirements_path)
    assert second_seed.created == []
    assert length(second_seed.reactivated) == 1

    assert {:ok, tasks} = Tasks.list()
    assert length(tasks) == 1

    [reactivated_task] = tasks
    assert reactivated_task["status"] == "pending"
    assert reactivated_task["last_result"] == nil
  end
end
