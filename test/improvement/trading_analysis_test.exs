defmodule CriptoTrader.Improvement.TradingAnalysisTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Improvement.TradingAnalysis

  describe "build_analysis_prompt/3" do
    test "generates prompt with current performance" do
      prompt = TradingAnalysis.build_analysis_prompt("CriptoTrader.Strategy.Alternating", 1)

      assert prompt =~ "iteration 1"
      assert prompt =~ "STRATEGY: CriptoTrader.Strategy.Alternating"
      assert prompt =~ "CURRENT PERFORMANCE:"
      assert prompt =~ "PnL:"
      assert prompt =~ "Win Rate:"
      assert prompt =~ "Max Drawdown:"
    end

    test "includes baseline comparison when baseline exists" do
      # This test would need to set up baseline data
      # For now, just verify the prompt structure
      prompt = TradingAnalysis.build_analysis_prompt("CriptoTrader.Strategy.Alternating", 2)

      assert prompt =~ "BASELINE:"
      assert prompt =~ "DATA SOURCES:"
      assert prompt =~ "ANALYSIS OBJECTIVES:"
    end

    test "includes budget context when provided" do
      budget = %{"remaining_seconds" => 3600, "window_end" => "2026-03-01T00:00:00Z"}
      prompt = TradingAnalysis.build_analysis_prompt("CriptoTrader.Strategy.Alternating", 1, budget: budget)

      assert prompt =~ "BUDGET:"
      assert prompt =~ "3600 seconds"
    end
  end

  describe "format_number/2" do
    test "formats number with specified decimals" do
      assert TradingAnalysis.format_number(123.456, 2) == "123.46"
      assert TradingAnalysis.format_number(0.0, 2) == "0.00"
      assert TradingAnalysis.format_number(-50.123, 2) == "-50.12"
    end

    test "returns N/A for nil" do
      assert TradingAnalysis.format_number(nil, 2) == "N/A"
    end
  end

  describe "format_pct/1" do
    test "formats decimal as percentage" do
      assert TradingAnalysis.format_pct(0.5) == "50.00%"
      assert TradingAnalysis.format_pct(0.123) == "12.30%"
      assert TradingAnalysis.format_pct(1.0) == "100.00%"
    end

    test "returns N/A for nil" do
      assert TradingAnalysis.format_pct(nil) == "N/A"
    end
  end
end
