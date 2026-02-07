defmodule CriptoTrader.Improvement.LoopTest do
  use ExUnit.Case, async: false

  alias CriptoTrader.Improvement.{KnowledgeBase, Loop, Tasks}

  setup do
    original = Application.get_env(:cripto_trader, :improvement)

    base =
      Path.join(
        System.tmp_dir!(),
        "cripto_trader_improvement_loop_#{System.unique_integer([:positive])}"
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

  test "runs a note task and stores a finding" do
    assert {:ok, _task} =
             Tasks.create(%{
               "title" => "Capture observation",
               "description" => "Paper mode should stay default",
               "type" => "note",
               "payload" => %{"summary" => "Paper mode safety check"}
             })

    assert {:ok, report} = Loop.run_once(max_tasks: 1)
    assert report.processed_count == 1
    assert report.error_count == 0

    assert {:ok, tasks} = Tasks.list()
    assert Enum.at(tasks, 0)["status"] == "done"

    assert {:ok, findings} = KnowledgeBase.list()
    assert length(findings) == 1
    assert Enum.at(findings, 0)["title"] == "Paper mode safety check"
  end
end
