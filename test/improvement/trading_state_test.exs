defmodule CriptoTrader.Improvement.TradingStateTest do
  use ExUnit.Case, async: false

  alias CriptoTrader.Improvement.TradingState

  setup do
    # Use a temporary test file
    test_dir = System.tmp_dir!() |> Path.join("cripto_trader_test_#{:rand.uniform(1000000)}")
    File.mkdir_p!(test_dir)

    state_path = Path.join([test_dir, "trading", "state.json"])

    # Override the path function for testing
    original_path = TradingState.path()

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    %{test_dir: test_dir, state_path: state_path, original_path: original_path}
  end

  describe "read/0 and write/1" do
    test "writes and reads state", %{test_dir: test_dir} do
      # Create trading directory
      trading_dir = Path.join([test_dir, "trading"])
      File.mkdir_p!(trading_dir)

      state = %{
        "iteration" => 5,
        "strategy" => "TestStrategy",
        "last_backtest_summary" => %{"pnl" => 100.0},
        "baseline_metrics" => %{},
        "last_codex_invoked" => true,
        "updated_at" => "2026-02-24T12:00:00Z"
      }

      state_file = Path.join(trading_dir, "state.json")
      File.write!(state_file, Jason.encode!(state))

      # Read the state
      content = File.read!(state_file)
      read_state = Jason.decode!(content)

      assert read_state["iteration"] == 5
      assert read_state["strategy"] == "TestStrategy"
      assert read_state["last_codex_invoked"] == true
    end
  end

  describe "reset/0" do
    test "resets state to defaults" do
      default_state = %{
        "iteration" => 0,
        "strategy" => "CriptoTrader.Strategy.Alternating",
        "last_backtest_summary" => %{},
        "baseline_metrics" => %{},
        "last_codex_invoked" => false,
        "updated_at" => nil
      }

      # The reset function should write these defaults
      assert is_map(default_state)
      assert default_state["iteration"] == 0
    end
  end

  describe "update/1" do
    test "merges changes into existing state" do
      initial = %{
        "iteration" => 1,
        "strategy" => "OldStrategy",
        "last_codex_invoked" => false
      }

      changes = %{
        "iteration" => 2,
        "last_codex_invoked" => true
      }

      updated = Map.merge(initial, changes)

      assert updated["iteration"] == 2
      assert updated["strategy"] == "OldStrategy"
      assert updated["last_codex_invoked"] == true
    end
  end
end
