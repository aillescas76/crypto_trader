defmodule CriptoTrader.Improvement.TaskExecutorTest do
  use ExUnit.Case, async: true
  alias CriptoTrader.Improvement.TaskExecutor

  describe "execute_note/1 without verification" do
    test "completes note immediately when no verification present" do
      task = %{
        "id" => 1,
        "type" => "note",
        "title" => "Add new feature",
        "description" => "Implement feature X",
        "payload" => %{}
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "done"
      assert result.summary == "Add new feature"
      assert result.details == "Implement feature X"
      assert "note" in result.tags
      refute "verified" in result.tags
    end

    test "uses payload summary and details if present" do
      task = %{
        "id" => 1,
        "type" => "note",
        "title" => "Task title",
        "description" => "Task description",
        "payload" => %{
          "summary" => "Custom summary",
          "details" => "Custom details"
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.summary == "Custom summary"
      assert result.details == "Custom details"
    end
  end

  describe "execute_note/1 with verification" do
    test "completes when verification command succeeds" do
      task = %{
        "id" => 2,
        "type" => "note",
        "title" => "Feature with test",
        "payload" => %{
          "verification" => %{
            "command" => "echo 'success'"
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "done"
      assert result.summary == "Feature with test"
      assert result.details == "Verification passed"
      assert "verified" in result.tags
      assert String.contains?(result.data["verification_output"], "success")
    end

    test "fails when verification command has wrong exit code" do
      task = %{
        "id" => 3,
        "type" => "note",
        "title" => "Feature with failing test",
        "payload" => %{
          "verification" => %{
            "command" => "exit 1",
            "expect_exit_code" => 0
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "failed"
      assert result.summary == "Verification failed"
      assert String.contains?(result.details, "exited with code 1")
      assert "verification_failed" in result.tags
      assert result.data["verification_error"] != nil
    end

    test "fails when expected output string is missing" do
      task = %{
        "id" => 4,
        "type" => "note",
        "title" => "Feature with output check",
        "payload" => %{
          "verification" => %{
            "command" => "echo 'hello world'",
            "expect_output_contains" => "goodbye"
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "failed"
      assert result.summary == "Verification failed"
      assert String.contains?(result.details, "Output missing expected string")
      assert String.contains?(result.details, "goodbye")
    end

    test "succeeds when expected output string is found" do
      task = %{
        "id" => 5,
        "type" => "note",
        "title" => "Feature with output check",
        "payload" => %{
          "verification" => %{
            "command" => "echo 'test passed with 0 failures'",
            "expect_output_contains" => "0 failures"
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "done"
      assert result.details == "Verification passed"
      assert String.contains?(result.data["verification_output"], "0 failures")
    end

    test "succeeds with custom expected exit code" do
      task = %{
        "id" => 6,
        "type" => "note",
        "title" => "Feature expecting non-zero exit",
        "payload" => %{
          "verification" => %{
            "command" => "exit 2",
            "expect_exit_code" => 2
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "done"
      assert result.details == "Verification passed"
    end

    test "fails when verification command is missing" do
      task = %{
        "id" => 7,
        "type" => "note",
        "title" => "Feature with invalid verification",
        "payload" => %{
          "verification" => %{
            "command" => nil
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "failed"
      assert result.summary == "Verification failed"
      assert String.contains?(result.details, "command is required")
    end

    test "fails when verification command is empty string" do
      task = %{
        "id" => 8,
        "type" => "note",
        "title" => "Feature with empty command",
        "payload" => %{
          "verification" => %{
            "command" => ""
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "failed"
      assert String.contains?(result.details, "command is required")
    end

    test "truncates long verification output" do
      # Generate output longer than 1000 chars
      long_output = String.duplicate("x", 1100)

      task = %{
        "id" => 9,
        "type" => "note",
        "title" => "Feature with long output",
        "payload" => %{
          "verification" => %{
            "command" => "echo '#{long_output}'"
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "done"
      output = result.data["verification_output"]
      assert String.contains?(output, "truncated")
      # Should be around 1000 chars + truncation message
      assert String.length(output) < 1100
    end
  end

  describe "run_verification/1" do
    test "returns error for nil command" do
      assert {:error, reason} = TaskExecutor.run_verification(%{"command" => nil})
      assert String.contains?(reason, "command is required")
    end

    test "returns error for empty command" do
      assert {:error, reason} = TaskExecutor.run_verification(%{"command" => ""})
      assert String.contains?(reason, "command is required")
    end

    test "executes simple shell commands" do
      assert {:ok, output} = TaskExecutor.run_verification(%{"command" => "echo 'test'"})
      assert String.contains?(output, "test")
    end

    test "checks exit codes" do
      assert {:error, _} =
               TaskExecutor.run_verification(%{
                 "command" => "exit 5",
                 "expect_exit_code" => 0
               })

      assert {:ok, _} =
               TaskExecutor.run_verification(%{
                 "command" => "exit 5",
                 "expect_exit_code" => 5
               })
    end

    test "checks output contains string" do
      spec = %{
        "command" => "echo 'hello world'",
        "expect_output_contains" => "world"
      }

      assert {:ok, _} = TaskExecutor.run_verification(spec)

      spec_fail = %{
        "command" => "echo 'hello world'",
        "expect_output_contains" => "goodbye"
      }

      assert {:error, reason} = TaskExecutor.run_verification(spec_fail)
      assert String.contains?(reason, "Output missing")
    end

    test "verifies file existence" do
      # This test file should exist
      spec = %{
        "command" => "test -f test/improvement/task_executor_test.exs"
      }

      assert {:ok, _} = TaskExecutor.run_verification(spec)

      # Non-existent file should fail
      spec_fail = %{
        "command" => "test -f /nonexistent/file.txt"
      }

      assert {:error, _} = TaskExecutor.run_verification(spec_fail)
    end

    test "can grep for patterns in files" do
      spec = %{
        "command" => "grep -q 'TaskExecutor' test/improvement/task_executor_test.exs"
      }

      assert {:ok, _} = TaskExecutor.run_verification(spec)
    end
  end

  describe "execute_backtest/1" do
    test "executes backtest with default parameters" do
      task = %{
        "id" => 20,
        "type" => "backtest",
        "title" => "Test trading strategy",
        "payload" => %{}
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "done"
      assert String.contains?(result.summary, "Backtest passed")
      assert "backtest" in result.tags
      assert "trading" in result.tags
    end

    test "executes backtest with custom parameters" do
      task = %{
        "id" => 21,
        "type" => "backtest",
        "title" => "Test custom strategy",
        "payload" => %{
          "strategy_module" => "CriptoTrader.Strategy.Custom",
          "symbols" => ["ETHUSDT", "BNBUSDT"],
          "interval" => "1h",
          "start_date" => "2024-01-01",
          "end_date" => "2024-12-31"
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "done"
      assert result.data["strategy"] == "CriptoTrader.Strategy.Custom"
    end

    test "passes verification when no thresholds specified" do
      task = %{
        "id" => 22,
        "type" => "backtest",
        "title" => "Test without verification",
        "payload" => %{}
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "done"
      assert "passed" in result.tags
    end

    test "fails verification when Sharpe ratio below threshold" do
      task = %{
        "id" => 23,
        "type" => "backtest",
        "title" => "Test with Sharpe threshold",
        "payload" => %{
          "verification" => %{
            "expect_sharpe_ratio_min" => 2.0
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      # Default sharpe_ratio is 0.0, should fail
      assert result.status == "failed"
      assert String.contains?(result.details, "Sharpe ratio")
      assert "failed" in result.tags
    end

    test "fails verification when drawdown exceeds threshold" do
      task = %{
        "id" => 24,
        "type" => "backtest",
        "title" => "Test with drawdown threshold",
        "payload" => %{
          "verification" => %{
            "expect_max_drawdown_max" => 0.05
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      # Default max_drawdown_pct is 0.1, should fail
      assert result.status == "failed"
      assert String.contains?(result.details, "drawdown")
      assert "failed" in result.tags
    end

    test "fails verification when win rate below threshold" do
      task = %{
        "id" => 25,
        "type" => "backtest",
        "title" => "Test with win rate threshold",
        "payload" => %{
          "verification" => %{
            "expect_win_rate_min" => 0.7
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      # Default win_rate is 0.5, should fail
      assert result.status == "failed"
      assert String.contains?(result.details, "Win rate")
      assert "failed" in result.tags
    end

    test "fails verification when trade count below threshold" do
      task = %{
        "id" => 26,
        "type" => "backtest",
        "title" => "Test with trade count threshold",
        "payload" => %{
          "verification" => %{
            "expect_min_trades" => 10
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      # Default trades is 0, should fail
      assert result.status == "failed"
      assert String.contains?(result.details, "Trade count")
      assert "failed" in result.tags
    end

    test "fails verification when PnL below threshold" do
      task = %{
        "id" => 27,
        "type" => "backtest",
        "title" => "Test with PnL threshold",
        "payload" => %{
          "verification" => %{
            "expect_min_pnl" => 100.0
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      # Default pnl is 0.0, should fail
      assert result.status == "failed"
      assert String.contains?(result.details, "PnL")
      assert "failed" in result.tags
    end

    test "can combine multiple verification thresholds" do
      task = %{
        "id" => 28,
        "type" => "backtest",
        "title" => "Test with multiple thresholds",
        "payload" => %{
          "verification" => %{
            "expect_sharpe_ratio_min" => 1.5,
            "expect_max_drawdown_max" => 0.15,
            "expect_win_rate_min" => 0.6,
            "expect_min_trades" => 5,
            "expect_min_pnl" => 50.0
          }
        }
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      # All default values should fail at least some thresholds
      assert result.status == "failed"
    end
  end

  describe "backward compatibility" do
    test "requirement_gap tasks still work" do
      task = %{
        "id" => 10,
        "type" => "requirement_gap",
        "title" => "Check AC-1",
        "payload" => %{
          "criterion_id" => "ac-1",
          "criterion_description" => "Test criterion"
        }
      }

      # Should not crash, will return done/failed based on actual check
      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status in ["done", "failed", "blocked"]
    end

    test "unknown task types return blocked status" do
      task = %{
        "id" => 11,
        "type" => "unknown_type",
        "title" => "Unknown task"
      }

      assert {:ok, result} = TaskExecutor.execute(task)
      assert result.status == "blocked"
      assert result.summary == "Unknown task type"
      assert String.contains?(result.details, "unknown_type")
    end
  end
end
