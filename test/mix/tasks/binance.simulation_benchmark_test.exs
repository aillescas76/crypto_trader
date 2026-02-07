defmodule Mix.Tasks.Binance.SimulationBenchmarkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup_all do
    Mix.start()
    :ok
  end

  setup do
    previous_runner_fun = Application.get_env(:cripto_trader, :simulation_benchmark_runner_fun)
    previous_timer_fun = Application.get_env(:cripto_trader, :simulation_benchmark_timer_fun)
    previous_skip_app_start = Application.get_env(:cripto_trader, :skip_mix_app_start)

    Application.put_env(:cripto_trader, :skip_mix_app_start, true)

    on_exit(fn ->
      restore_env(:simulation_benchmark_runner_fun, previous_runner_fun)
      restore_env(:simulation_benchmark_timer_fun, previous_timer_fun)
      restore_env(:skip_mix_app_start, previous_skip_app_start)
    end)

    :ok
  end

  test "prints benchmark payload and marks pass when under threshold" do
    parent = self()

    Application.put_env(:cripto_trader, :simulation_benchmark_runner_fun, fn opts ->
      send(parent, {:runner_opts, opts})

      {:ok,
       %{
         trade_log: [],
         summary: %{
           pnl: 0.0,
           win_rate: 0.0,
           max_drawdown_pct: 0.0,
           trades: 0,
           rejected_orders: 0,
           closed_trades: 0,
           events_processed: 384
         },
         equity_curve: []
       }}
    end)

    Application.put_env(:cripto_trader, :simulation_benchmark_timer_fun, fn fun ->
      {1_250_000, fun.()}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--symbols",
          "btcusdt,ETHUSDT",
          "--days",
          "2",
          "--speed",
          "50",
          "--max-seconds",
          "2.0",
          "--quantity",
          "0.2",
          "--initial-balance",
          "5000"
        ])
      end)

    assert_receive {:runner_opts, runner_opts}
    assert Keyword.fetch!(runner_opts, :symbols) == ["BTCUSDT", "ETHUSDT"]
    assert Keyword.fetch!(runner_opts, :interval) == "15m"
    assert Keyword.fetch!(runner_opts, :speed) == 50
    assert Keyword.fetch!(runner_opts, :initial_balance) == 5_000.0
    assert Keyword.fetch!(runner_opts, :include_trade_log) == false
    assert Keyword.fetch!(runner_opts, :log_strategy_decisions) == false
    assert is_function(Keyword.fetch!(runner_opts, :strategy_fun), 2)
    assert is_map(Keyword.fetch!(runner_opts, :strategy_state))

    candles_by_symbol = Keyword.fetch!(runner_opts, :candles_by_symbol)
    assert Enum.all?(candles_by_symbol, fn {_symbol, candles} -> length(candles) == 192 end)

    strategy_fun = Keyword.fetch!(runner_opts, :strategy_fun)
    strategy_state = Keyword.fetch!(runner_opts, :strategy_state)

    {first_orders, next_state} = strategy_fun.(%{symbol: "BTCUSDT"}, strategy_state)
    {second_orders, third_state} = strategy_fun.(%{symbol: "BTCUSDT"}, next_state)
    {other_symbol_orders, _state} = strategy_fun.(%{symbol: "ETHUSDT"}, third_state)

    assert first_orders == [%{symbol: "BTCUSDT", side: "BUY", quantity: 0.2}]
    assert second_orders == [%{symbol: "BTCUSDT", side: "SELL", quantity: 0.2}]
    assert other_symbol_orders == [%{symbol: "ETHUSDT", side: "BUY", quantity: 0.2}]

    payload = Jason.decode!(output)
    assert payload["benchmark"]["passed"]
    assert payload["benchmark"]["elapsed_seconds"] == 1.25
    assert payload["benchmark"]["threshold_seconds"] == 2.0
    assert payload["simulation"]["expected_events"] == 384
  end

  test "raises when runtime exceeds threshold" do
    Application.put_env(:cripto_trader, :simulation_benchmark_runner_fun, fn _opts ->
      {:ok,
       %{
         trade_log: [],
         summary: %{
           pnl: 0.0,
           win_rate: 0.0,
           max_drawdown_pct: 0.0,
           trades: 0,
           rejected_orders: 0,
           closed_trades: 0,
           events_processed: 288
         },
         equity_curve: []
       }}
    end)

    Application.put_env(:cripto_trader, :simulation_benchmark_timer_fun, fn fun ->
      {2_500_000, fun.()}
    end)

    capture_io(fn ->
      assert_raise Mix.Error,
                   ~r/Simulation benchmark failed: elapsed 2.5s exceeded threshold 2.0s/,
                   fn ->
                     run_task(["--days", "1", "--max-seconds", "2.0"])
                   end
    end)
  end

  test "raises when processed event count is not the expected workload" do
    Application.put_env(:cripto_trader, :simulation_benchmark_runner_fun, fn _opts ->
      {:ok,
       %{
         trade_log: [],
         summary: %{
           pnl: 0.0,
           win_rate: 0.0,
           max_drawdown_pct: 0.0,
           trades: 0,
           rejected_orders: 0,
           closed_trades: 0,
           events_processed: 123
         },
         equity_curve: []
       }}
    end)

    Application.put_env(:cripto_trader, :simulation_benchmark_timer_fun, fn fun ->
      {1_000_000, fun.()}
    end)

    capture_io(fn ->
      assert_raise Mix.Error,
                   ~r/Simulation benchmark failed: expected 288 events, got 123/,
                   fn ->
                     run_task(["--days", "1"])
                   end
    end)
  end

  defp run_task(args) do
    Mix.Tasks.Binance.SimulationBenchmark.run(args)
  end

  defp restore_env(key, nil), do: Application.delete_env(:cripto_trader, key)
  defp restore_env(key, value), do: Application.put_env(:cripto_trader, key, value)
end
