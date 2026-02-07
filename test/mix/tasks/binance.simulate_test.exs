defmodule Mix.Tasks.Binance.SimulateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup_all do
    Mix.start()
    :ok
  end

  setup do
    previous_fetch_fun = Application.get_env(:cripto_trader, :simulation_candles_fetch_fun)

    previous_archive_fetch_fun =
      Application.get_env(:cripto_trader, :simulation_archive_candles_fetch_fun)

    previous_runner_fun = Application.get_env(:cripto_trader, :simulation_runner_fun)
    previous_skip_app_start = Application.get_env(:cripto_trader, :skip_mix_app_start)

    Application.put_env(:cripto_trader, :skip_mix_app_start, true)

    on_exit(fn ->
      restore_env(:simulation_candles_fetch_fun, previous_fetch_fun)
      restore_env(:simulation_archive_candles_fetch_fun, previous_archive_fetch_fun)
      restore_env(:simulation_runner_fun, previous_runner_fun)
      restore_env(:skip_mix_app_start, previous_skip_app_start)
    end)

    :ok
  end

  test "runs multi-symbol simulation and prints JSON payload" do
    parent = self()

    Application.put_env(:cripto_trader, :simulation_archive_candles_fetch_fun, fn opts ->
      send(parent, {:archive_fetch_opts, opts})

      {:ok,
       %{
         "BTCUSDT" => [%{open_time: 1_704_067_200_000, close: "100.0"}],
         "ETHUSDT" => [%{open_time: 1_704_067_200_000, close: "200.0"}]
       }}
    end)

    Application.put_env(:cripto_trader, :simulation_runner_fun, fn opts ->
      send(parent, {:runner_opts, opts})

      strategy_fun = Keyword.fetch!(opts, :strategy_fun)
      strategy_state = Keyword.fetch!(opts, :strategy_state)

      {orders_1, state_1} = strategy_fun.(%{symbol: "BTCUSDT"}, strategy_state)
      {orders_2, _state_2} = strategy_fun.(%{symbol: "BTCUSDT"}, state_1)
      send(parent, {:strategy_orders, orders_1, orders_2})

      {:ok,
       %{
         trade_log: [%{status: "filled", symbol: "BTCUSDT"}],
         summary: %{
           pnl: 10.0,
           win_rate: 1.0,
           max_drawdown_pct: 0.0,
           trades: 1,
           rejected_orders: 0,
           closed_trades: 0,
           events_processed: 2
         },
         equity_curve: [%{open_time: 1_704_067_200_000, equity: 5_010.0}]
       }}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--source",
          "archive",
          "--symbol",
          "btcusdt",
          "--symbols",
          "ETHUSDT",
          "--interval",
          "15m",
          "--start-time",
          "2024-01-01T00:00:00Z",
          "--end-time",
          "2024-01-01T00:15:00Z",
          "--speed",
          "50",
          "--quantity",
          "0.2",
          "--strategy",
          "alternating",
          "--initial-balance",
          "5000",
          "--include-equity-curve"
        ])
      end)

    assert_receive {:archive_fetch_opts, fetch_opts}
    assert Keyword.fetch!(fetch_opts, :symbols) == ["BTCUSDT", "ETHUSDT"]
    assert Keyword.fetch!(fetch_opts, :interval) == "15m"
    assert Keyword.fetch!(fetch_opts, :start_time) == 1_704_067_200_000
    assert Keyword.fetch!(fetch_opts, :end_time) == 1_704_068_100_000
    refute Keyword.has_key?(fetch_opts, :limit)

    assert_receive {:runner_opts, runner_opts}
    assert Keyword.fetch!(runner_opts, :symbols) == ["BTCUSDT", "ETHUSDT"]
    assert Keyword.fetch!(runner_opts, :speed) == 50
    assert Keyword.fetch!(runner_opts, :trading_mode) == :paper
    assert Keyword.fetch!(runner_opts, :initial_balance) == 5_000.0
    assert Keyword.fetch!(runner_opts, :include_equity_curve)
    assert Keyword.fetch!(runner_opts, :log_strategy_decisions) == false

    assert_receive {:strategy_orders, [order_1], [order_2]}
    assert order_1.side == "BUY"
    assert order_1.quantity == 0.2
    assert order_2.side == "SELL"
    assert order_2.quantity == 0.2

    payload = Jason.decode!(output)
    assert payload["source"] == "binance_spot_archive"
    assert payload["strategy"] == "alternating"
    assert payload["symbols"] == ["BTCUSDT", "ETHUSDT"]
    assert payload["interval"] == "15m"
    assert payload["speed"] == 50
    assert payload["mode"] == "paper"
    assert payload["log_strategy_decisions"] == false
    assert payload["initial_balance"] == 5_000.0
    assert payload["result"]["summary"]["events_processed"] == 2
  end

  test "passes explicit live mode to runner" do
    parent = self()

    Application.put_env(:cripto_trader, :simulation_archive_candles_fetch_fun, fn _opts ->
      {:ok, %{"BTCUSDT" => [%{open_time: 1_704_067_200_000, close: "100.0"}]}}
    end)

    Application.put_env(:cripto_trader, :simulation_runner_fun, fn opts ->
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
           events_processed: 1
         },
         equity_curve: []
       }}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--symbol",
          "BTCUSDT",
          "--interval",
          "15m",
          "--start-time",
          "2024-01-01T00:00:00Z",
          "--end-time",
          "2024-01-01T00:15:00Z",
          "--mode",
          "live"
        ])
      end)

    assert_receive {:runner_opts, runner_opts}
    assert Keyword.fetch!(runner_opts, :trading_mode) == :live

    payload = Jason.decode!(output)
    assert payload["mode"] == "live"
  end

  test "enables strategy decision logging when requested" do
    parent = self()

    Application.put_env(:cripto_trader, :simulation_archive_candles_fetch_fun, fn _opts ->
      {:ok, %{"BTCUSDT" => [%{open_time: 1_704_067_200_000, close: "100.0"}]}}
    end)

    Application.put_env(:cripto_trader, :simulation_runner_fun, fn opts ->
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
           events_processed: 1
         },
         equity_curve: []
       }}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--symbol",
          "BTCUSDT",
          "--interval",
          "15m",
          "--start-time",
          "2024-01-01T00:00:00Z",
          "--end-time",
          "2024-01-01T00:15:00Z",
          "--log-strategy-decisions"
        ])
      end)

    assert_receive {:runner_opts, runner_opts}
    assert Keyword.fetch!(runner_opts, :log_strategy_decisions) == true

    payload = Jason.decode!(output)
    assert payload["log_strategy_decisions"] == true
  end

  test "rejects invalid strategy value" do
    assert_raise Mix.Error, ~r/Invalid --strategy. Accepted values: alternating/, fn ->
      run_task([
        "--symbol",
        "BTCUSDT",
        "--interval",
        "15m",
        "--start-time",
        "2024-01-01T00:00:00Z",
        "--end-time",
        "2024-01-01T00:15:00Z",
        "--strategy",
        "mean_reversion"
      ])
    end
  end

  test "rejects invalid mode value" do
    assert_raise Mix.Error, ~r/Invalid --mode. Accepted values: paper, live/, fn ->
      run_task([
        "--symbol",
        "BTCUSDT",
        "--interval",
        "15m",
        "--start-time",
        "2024-01-01T00:00:00Z",
        "--end-time",
        "2024-01-01T00:15:00Z",
        "--mode",
        "invalid"
      ])
    end
  end

  test "requires explicit date range" do
    assert_raise Mix.Error, ~r/Missing required option --end-time/, fn ->
      run_task([
        "--symbol",
        "BTCUSDT",
        "--interval",
        "15m",
        "--start-time",
        "2024-01-01T00:00:00Z"
      ])
    end
  end

  defp run_task(args) do
    Mix.Tasks.Binance.Simulate.run(args)
  end

  defp restore_env(key, nil), do: Application.delete_env(:cripto_trader, key)
  defp restore_env(key, value), do: Application.put_env(:cripto_trader, key, value)
end
