defmodule CriptoTrader.Trading.RobotTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CriptoTrader.Trading.Robot
  alias CriptoTrader.Risk
  alias CriptoTrader.Risk.Config

  test "processes multiple symbols with one strategy in paper mode by default" do
    parent = self()

    candles_fetch_fun = fn opts ->
      symbol = opts |> Keyword.fetch!(:symbols) |> hd()
      send(parent, {:fetch_opts, symbol, opts})

      candles =
        case symbol do
          "BTCUSDT" ->
            [
              %{open_time: 2_000, close: "101.0"},
              %{open_time: 1_000, close: "100.0"}
            ]

          "ETHUSDT" ->
            [%{open_time: 1_500, close: "200.0"}]
        end

      {:ok, %{symbol => candles}}
    end

    strategy_fun = fn _event, state ->
      {[%{side: "BUY", quantity: 0.5}], state}
    end

    order_executor = fn params, opts ->
      send(parent, {:order, params, opts})
      {:ok, %{status: "FILLED"}}
    end

    assert {:ok, result} =
             Robot.run(
               symbols: ["BTCUSDT", "ETHUSDT"],
               interval: "1m",
               limit: 10,
               iterations: 1,
               candles_fetch_fun: candles_fetch_fun,
               strategy_fun: strategy_fun,
               order_executor: order_executor
             )

    assert result.mode == "paper"
    assert result.summary.events_processed == 3
    assert result.summary.accepted_orders == 3
    assert result.summary.rejected_orders == 0
    assert result.last_open_time_by_symbol["BTCUSDT"] == 2_000
    assert result.last_open_time_by_symbol["ETHUSDT"] == 1_500

    assert_receive {:fetch_opts, "BTCUSDT", fetch_opts_btc}
    assert Keyword.fetch!(fetch_opts_btc, :interval) == "1m"
    assert Keyword.fetch!(fetch_opts_btc, :limit) == 10

    assert_receive {:fetch_opts, "ETHUSDT", fetch_opts_eth}
    assert Keyword.fetch!(fetch_opts_eth, :interval) == "1m"
    assert Keyword.fetch!(fetch_opts_eth, :limit) == 10

    assert_receive {:order, _params_1, order_opts_1}
    assert Keyword.fetch!(order_opts_1, :trading_mode) == :paper

    assert_receive {:order, _params_2, order_opts_2}
    assert Keyword.fetch!(order_opts_2, :trading_mode) == :paper

    assert_receive {:order, _params_3, order_opts_3}
    assert Keyword.fetch!(order_opts_3, :trading_mode) == :paper
  end

  test "advances start cursor across iterations for a symbol" do
    parent = self()

    candles_fetch_fun = fn opts ->
      send(parent, {:fetch_opts, opts})
      start_time = Keyword.get(opts, :start_time)

      candles =
        case start_time do
          1_000 -> [%{open_time: 1_000, close: "100.0"}]
          1_001 -> [%{open_time: 2_000, close: "101.0"}]
          _ -> []
        end

      {:ok, %{"BTCUSDT" => candles}}
    end

    strategy_fun = fn _event, state -> {[], state} end

    assert {:ok, result} =
             Robot.run(
               symbols: ["BTCUSDT"],
               interval: "1m",
               iterations: 2,
               start_time: 1_000,
               candles_fetch_fun: candles_fetch_fun,
               strategy_fun: strategy_fun
             )

    assert result.summary.events_processed == 2
    assert result.last_open_time_by_symbol["BTCUSDT"] == 2_000

    assert_receive {:fetch_opts, fetch_opts_1}
    assert Keyword.fetch!(fetch_opts_1, :start_time) == 1_000

    assert_receive {:fetch_opts, fetch_opts_2}
    assert Keyword.fetch!(fetch_opts_2, :start_time) == 1_001
  end

  test "fetches symbol candles concurrently within one iteration" do
    parent = self()

    candles_fetch_fun = fn opts ->
      symbol = opts |> Keyword.fetch!(:symbols) |> hd()
      send(parent, {:fetch_started, symbol, self()})

      receive do
        {:release_fetch, ^symbol} ->
          {:ok, %{symbol => [%{open_time: 1_000, close: "100.0"}]}}
      after
        1_000 ->
          {:error, :fetch_release_timeout}
      end
    end

    robot_task =
      Task.async(fn ->
        Robot.run(
          symbols: ["BTCUSDT", "ETHUSDT"],
          interval: "1m",
          iterations: 1,
          candles_fetch_fun: candles_fetch_fun,
          strategy_fun: fn _event, state -> {[], state} end
        )
      end)

    fetch_starts = collect_fetch_starts(2, %{})

    assert Map.keys(fetch_starts) |> MapSet.new() == MapSet.new(["BTCUSDT", "ETHUSDT"])

    Enum.each(fetch_starts, fn {symbol, pid} ->
      send(pid, {:release_fetch, symbol})
    end)

    assert {:ok, result} = Task.await(robot_task, 5_000)
    assert result.summary.events_processed == 2
  end

  test "records order rejection when executor returns an error" do
    strategy_fun = fn _event, state ->
      {[%{side: "BUY", quantity: 2.0}], state}
    end

    assert {:ok, result} =
             Robot.run(
               symbols: ["BTCUSDT"],
               interval: "1m",
               iterations: 1,
               candles_fetch_fun: fn _opts ->
                 {:ok, %{"BTCUSDT" => [%{open_time: 1_000, close: "100.0"}]}}
               end,
               strategy_fun: strategy_fun,
               order_executor: fn _params, _opts -> {:error, {:risk, :max_order_quote}} end
             )

    assert result.summary.events_processed == 1
    assert result.summary.accepted_orders == 0
    assert result.summary.rejected_orders == 1

    assert [%{status: "rejected", reason: {:risk, :max_order_quote}}] = result.trade_log
  end

  test "passes drawdown context to risk checks and rejects orders past max drawdown" do
    risk_config = %Config{max_order_quote: nil, max_drawdown_pct: 0.2, circuit_breaker: false}

    candles_fetch_fun = fn _opts ->
      {:ok,
       %{
         "BTCUSDT" => [
           %{open_time: 1_000, close: "100.0"},
           %{open_time: 2_000, close: "50.0"}
         ]
       }}
    end

    strategy_fun = fn _event, state ->
      {[%{side: "BUY", quantity: 100.0}], state}
    end

    order_executor = fn params, opts ->
      context = opts |> Keyword.get(:context, %{}) |> Map.new()

      case Risk.check_order(params, risk_config, context) do
        :ok -> {:ok, %{status: "FILLED"}}
        {:error, reason} -> {:error, reason}
      end
    end

    assert {:ok, result} =
             Robot.run(
               symbols: ["BTCUSDT"],
               interval: "1m",
               iterations: 1,
               candles_fetch_fun: candles_fetch_fun,
               strategy_fun: strategy_fun,
               order_executor: order_executor
             )

    assert result.summary.events_processed == 2
    assert result.summary.accepted_orders == 1
    assert result.summary.rejected_orders == 1
    assert result.summary.max_drawdown_pct >= 0.5

    assert [
             %{status: "filled", open_time: 1_000},
             %{status: "rejected", open_time: 2_000, reason: {:risk, :max_drawdown}}
           ] = result.trade_log
  end

  test "emits structured strategy decision logs for trading runs" do
    log =
      capture_log(fn ->
        assert {:ok, result} =
                 Robot.run(
                   symbols: ["BTCUSDT"],
                   interval: "1m",
                   iterations: 1,
                   candles_fetch_fun: fn _opts ->
                     {:ok, %{"BTCUSDT" => [%{open_time: 1_000, close: "100.0"}]}}
                   end,
                   strategy_fun: fn _event, state -> {[], state} end
                 )

        assert result.summary.events_processed == 1
      end)

    assert log =~ "trading_event"
    assert log =~ "\"event\":\"strategy_decision\""
    assert log =~ "\"runner\":\"trading_robot\""
    assert log =~ "\"symbol\":\"BTCUSDT\""
    assert log =~ "\"trading_mode\":\"paper\""
    assert log =~ "\"orders\":0"
  end

  defp collect_fetch_starts(0, acc), do: acc

  defp collect_fetch_starts(remaining, acc) do
    assert_receive {:fetch_started, symbol, pid}
    collect_fetch_starts(remaining - 1, Map.put(acc, symbol, pid))
  end
end
