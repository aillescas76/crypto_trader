defmodule Mix.Tasks.Binance.TradeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup_all do
    Mix.start()
    :ok
  end

  setup do
    previous_robot_fun = Application.get_env(:cripto_trader, :trading_robot_fun)
    previous_skip_app_start = Application.get_env(:cripto_trader, :skip_mix_app_start)

    Application.put_env(:cripto_trader, :skip_mix_app_start, true)

    on_exit(fn ->
      restore_env(:trading_robot_fun, previous_robot_fun)
      restore_env(:skip_mix_app_start, previous_skip_app_start)
    end)

    :ok
  end

  test "runs robot with paper-safe defaults and prints JSON payload" do
    parent = self()

    Application.put_env(:cripto_trader, :trading_robot_fun, fn opts ->
      send(parent, {:robot_opts, opts})

      strategy_fun = Keyword.fetch!(opts, :strategy_fun)
      strategy_state = Keyword.fetch!(opts, :strategy_state)
      {orders_1, state_1} = strategy_fun.(%{symbol: "BTCUSDT"}, strategy_state)
      {orders_2, _state_2} = strategy_fun.(%{symbol: "BTCUSDT"}, state_1)
      send(parent, {:strategy_orders, orders_1, orders_2})

      {:ok,
       %{
         mode: "paper",
         summary: %{events_processed: 2, accepted_orders: 2, rejected_orders: 0},
         trade_log: []
       }}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--symbol",
          "btcusdt",
          "--symbols",
          "ETHUSDT",
          "--interval",
          "1m",
          "--iterations",
          "2",
          "--limit",
          "3",
          "--quantity",
          "0.2"
        ])
      end)

    assert_receive {:robot_opts, opts}
    assert Keyword.fetch!(opts, :symbols) == ["BTCUSDT", "ETHUSDT"]
    assert Keyword.fetch!(opts, :interval) == "1m"
    assert Keyword.fetch!(opts, :trading_mode) == :paper
    assert Keyword.fetch!(opts, :iterations) == 2
    assert Keyword.fetch!(opts, :limit) == 3
    assert Keyword.fetch!(opts, :poll_ms) == 0

    assert_receive {:strategy_orders, [order_1], [order_2]}
    assert order_1.side == "BUY"
    assert order_1.quantity == 0.2
    assert order_2.side == "SELL"
    assert order_2.quantity == 0.2

    payload = Jason.decode!(output)
    assert payload["mode"] == "paper"
    assert payload["strategy"] == "alternating"
    assert payload["symbols"] == ["BTCUSDT", "ETHUSDT"]
    assert payload["iterations"] == 2
    assert payload["result"]["summary"]["events_processed"] == 2
  end

  test "passes explicit live mode to the robot runner" do
    parent = self()

    Application.put_env(:cripto_trader, :trading_robot_fun, fn opts ->
      send(parent, {:robot_opts, opts})

      {:ok,
       %{mode: "live", summary: %{events_processed: 0, accepted_orders: 0, rejected_orders: 0}}}
    end)

    output =
      capture_io(fn ->
        run_task([
          "--symbol",
          "BTCUSDT",
          "--interval",
          "1m",
          "--mode",
          "live"
        ])
      end)

    assert_receive {:robot_opts, opts}
    assert Keyword.fetch!(opts, :trading_mode) == :live

    payload = Jason.decode!(output)
    assert payload["mode"] == "live"
  end

  test "rejects invalid mode value" do
    assert_raise Mix.Error, ~r/Invalid --mode. Accepted values: paper, live/, fn ->
      run_task([
        "--symbol",
        "BTCUSDT",
        "--interval",
        "1m",
        "--mode",
        "sandbox"
      ])
    end
  end

  defp run_task(args) do
    Mix.Tasks.Binance.Trade.run(args)
  end

  defp restore_env(key, nil), do: Application.delete_env(:cripto_trader, key)
  defp restore_env(key, value), do: Application.put_env(:cripto_trader, key, value)
end
