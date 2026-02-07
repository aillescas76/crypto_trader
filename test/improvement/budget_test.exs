defmodule CriptoTrader.Improvement.BudgetTest do
  use ExUnit.Case, async: false

  alias CriptoTrader.Improvement.{Budget, Config}

  setup do
    original = Application.get_env(:cripto_trader, :improvement)

    base =
      Path.join(
        System.tmp_dir!(),
        "cripto_trader_improvement_budget_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:cripto_trader, :improvement,
      storage_dir: Path.join(base, "storage"),
      adr_dir: Path.join(base, "adr"),
      weekly_budget_seconds: 3600
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

  test "resets and consumes weekly budget" do
    assert {:ok, reset} = Budget.reset()
    assert reset["limit_seconds"] == 3600
    assert reset["remaining_seconds"] == 3600

    assert {:ok, after_consume} = Budget.consume(120)
    assert after_consume["consumed_seconds"] == 120
    assert after_consume["remaining_seconds"] == 3480
  end

  test "resets stale budget window automatically" do
    path = Config.execution_budget_file()

    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "window_start" => "2025-01-06T00:00:00Z",
        "window_end" => "2025-01-13T00:00:00Z",
        "limit_seconds" => 3600,
        "consumed_seconds" => 3599,
        "remaining_seconds" => 1,
        "last_updated_at" => "2025-01-12T20:00:00Z"
      })
    )

    assert {:ok, snap} = Budget.snapshot()
    assert snap["remaining_seconds"] == 3600
    assert snap["consumed_seconds"] == 0
  end
end
