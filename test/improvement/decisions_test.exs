defmodule CriptoTrader.Improvement.DecisionsTest do
  use ExUnit.Case, async: false

  alias CriptoTrader.Improvement.Decisions

  setup do
    original = Application.get_env(:cripto_trader, :improvement)

    base =
      Path.join(
        System.tmp_dir!(),
        "cripto_trader_improvement_decisions_#{System.unique_integer([:positive])}"
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

  test "creates adr and updates adr index" do
    assert {:ok, decision} =
             Decisions.record(%{
               title: "Use deterministic improvement loop",
               context: "Need repeatable progress",
               decision: "Persist tasks and findings in JSON files",
               consequences: "Changes are auditable in git"
             })

    assert decision.id == "0001"
    assert File.exists?(decision.path)

    index_path =
      Path.join(Application.fetch_env!(:cripto_trader, :improvement)[:adr_dir], "README.md")

    index = File.read!(index_path)

    assert index =~ "Use deterministic improvement loop"
    assert index =~ "0001"
  end
end
