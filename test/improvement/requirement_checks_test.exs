defmodule CriptoTrader.Improvement.RequirementChecksTest do
  use ExUnit.Case, async: false

  alias CriptoTrader.Improvement.RequirementChecks

  setup_all do
    Mix.start()
    :ok
  end

  test "ac-1 executable check validates candle extraction command path" do
    result =
      RequirementChecks.check(
        "ac-1",
        "A CLI command fetches candles for at least one symbol and interval."
      )

    assert result.status == :met
    assert Enum.any?(result.evidence, &String.contains?(&1, "Mix.Tasks.Binance.FetchCandles"))

    assert Enum.any?(
             result.evidence,
             &String.contains?(&1, "paginated symbol/interval/date-range fetch path")
           )
  end

  @tag timeout: 120_000
  test "ac-2 executable check validates 3-month 15m simulation throughput" do
    result =
      RequirementChecks.check(
        "ac-2",
        "A simulation run can process 3 months of 15m candles in under 5 minutes on a dev machine."
      )

    assert result.status == :met

    assert Enum.any?(
             result.evidence,
             &String.contains?(&1, "Mix.Tasks.Binance.SimulationBenchmark")
           )

    assert Enum.any?(
             result.evidence,
             &String.contains?(&1, "deterministic 3-month 15m benchmark path")
           )

    assert Enum.any?(result.evidence, &String.contains?(&1, "Processed 25920 events"))
    assert Enum.any?(result.evidence, &String.contains?(&1, "Threshold: 300.000000s"))
  end

  test "ac-3 executable check validates one strategy across multiple symbols" do
    result =
      RequirementChecks.check(
        "ac-3",
        "A single strategy can run against multiple symbols in simulation."
      )

    assert result.status == :met

    assert Enum.any?(
             result.evidence,
             &String.contains?(&1, "One strategy function processed events for 2 symbols")
           )
  end

  test "ac-4 executable check validates risk checks for paper and live submissions" do
    result =
      RequirementChecks.check(
        "ac-4",
        "All risk checks are enforced in both paper and live modes."
      )

    assert result.status == :met

    assert Enum.any?(
             result.evidence,
             &String.contains?(&1, "Risk checks reject oversized orders before paper submission")
           )

    assert Enum.any?(
             result.evidence,
             &String.contains?(&1, "Risk checks reject oversized orders before live submission")
           )

    assert Enum.any?(
             result.evidence,
             &String.contains?(
               &1,
               "OrderManager defines a dedicated live submission branch through Spot.new_order"
             )
           )
  end
end
