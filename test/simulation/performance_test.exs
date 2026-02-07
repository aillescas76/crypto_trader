defmodule CriptoTrader.Simulation.PerformanceTest do
  use ExUnit.Case, async: false

  alias CriptoTrader.Simulation.Runner

  @tag :performance
  test "replays three months of 15m candles across multiple symbols under five minutes" do
    candles = build_15m_candles(1_700_000_000_000, 90)
    symbols = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
    candles_by_symbol = Map.new(symbols, fn symbol -> {symbol, candles} end)
    total_events = length(candles) * length(symbols)

    strategy_fun = fn event, state ->
      {[%{symbol: event.symbol, side: "BUY", quantity: 1.0}], state}
    end

    order_executor = fn params, _opts ->
      {:ok, %{status: "FILLED", symbol: params.symbol, side: params.side}}
    end

    {elapsed_us, run_result} =
      :timer.tc(fn ->
        Runner.run(
          symbols: symbols,
          interval: "15m",
          candles_by_symbol: candles_by_symbol,
          log_strategy_decisions: false,
          include_trade_log: false,
          strategy_fun: strategy_fun,
          strategy_state: %{},
          order_executor: order_executor,
          include_equity_curve: false,
          speed: 100
        )
      end)

    assert {:ok, result} = run_result
    assert elapsed_us < 300_000_000
    assert result.summary.events_processed == total_events
    assert result.summary.trades == total_events
    assert result.summary.rejected_orders == 0
    assert result.trade_log == []
  end

  defp build_15m_candles(start_ms, days) do
    candles_per_day = 24 * 4
    total = days * candles_per_day
    step_ms = 15 * 60 * 1_000

    Enum.map(0..(total - 1), fn index ->
      %{
        open_time: start_ms + index * step_ms,
        close: Float.to_string(100.0 + rem(index, 20) * 0.25)
      }
    end)
  end
end
