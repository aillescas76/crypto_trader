defmodule CriptoTrader.Simulation.RunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CriptoTrader.Simulation.Runner

  test "replays multiple symbols deterministically with one strategy" do
    candles_by_symbol = %{
      "ETHUSDT" => [
        %{open_time: 1_000, close: "200.0"}
      ],
      "BTCUSDT" => [
        %{open_time: 1_000, close: "100.0"},
        %{open_time: 2_000, close: "120.0"}
      ]
    }

    strategy_fun = fn event, state ->
      orders =
        case {event.symbol, event.open_time} do
          {"BTCUSDT", 1_000} -> [%{side: "BUY", quantity: 1.0}]
          {"BTCUSDT", 2_000} -> [%{side: "SELL", quantity: 1.0}]
          _ -> []
        end

      {orders, state}
    end

    order_executor = fn params, opts ->
      send(self(), {:executed, params, opts, Keyword.fetch!(opts, :context)})
      {:ok, %{status: "FILLED", symbol: params.symbol}}
    end

    event_handler = fn event ->
      send(self(), {:event, event.symbol, event.open_time, event.emitted_at})
    end

    assert {:ok, result} =
             Runner.run(
               symbols: ["ETHUSDT", "BTCUSDT"],
               interval: "15m",
               candles_by_symbol: candles_by_symbol,
               speed: 10,
               start_emitted_at: 10_000,
               include_equity_curve: true,
               strategy_fun: strategy_fun,
               strategy_state: %{},
               order_executor: order_executor,
               event_handler: event_handler
             )

    assert_receive {:event, "ETHUSDT", 1_000, 10_000}
    assert_receive {:event, "BTCUSDT", 1_000, 10_000}
    assert_receive {:event, "BTCUSDT", 2_000, 10_100}

    assert_receive {:executed, %{symbol: "BTCUSDT", side: "BUY", quantity: 1.0, price: 100.0},
                    executor_opts_1, context_1}

    assert Keyword.fetch!(executor_opts_1, :trading_mode) == :paper
    assert context_1.order_quote == 100.0

    assert_receive {:executed, %{symbol: "BTCUSDT", side: "SELL", quantity: 1.0, price: 120.0},
                    executor_opts_2, context_2}

    assert Keyword.fetch!(executor_opts_2, :trading_mode) == :paper
    assert context_2.order_quote == 120.0

    assert result.summary.events_processed == 3
    assert result.summary.trades == 2
    assert result.summary.rejected_orders == 0
    assert result.summary.closed_trades == 1
    assert_in_delta result.summary.pnl, 20.0, 1.0e-8
    assert_in_delta result.summary.win_rate, 1.0, 1.0e-8
    assert length(result.trade_log) == 2
    assert length(result.equity_curve) == 3
  end

  test "sanitizes volatile executor response fields for deterministic trade logs" do
    candles_by_symbol = %{"BTCUSDT" => [%{open_time: 1_000, close: "100.0"}]}

    strategy_fun = fn _event, state ->
      {[%{side: "BUY", quantity: 1.0}], state}
    end

    order_executor = fn params, _opts ->
      nonce = :erlang.unique_integer([:positive, :monotonic])
      now = System.system_time(:millisecond)

      {:ok,
       %{
         "clientOrderId" => "cid-#{nonce}",
         "orderId" => nonce,
         "transactTime" => now,
         :order_id => nonce + 1,
         :transact_time => now + 1,
         "status" => "FILLED",
         "symbol" => params.symbol,
         "side" => params.side
       }}
    end

    run_opts = [
      symbols: ["BTCUSDT"],
      interval: "1m",
      candles_by_symbol: candles_by_symbol,
      strategy_fun: strategy_fun,
      order_executor: order_executor
    ]

    assert {:ok, first} = Runner.run(run_opts)
    assert {:ok, second} = Runner.run(run_opts)
    assert first.trade_log == second.trade_log

    assert [
             %{
               status: "filled",
               order_response: %{
                 "status" => "FILLED",
                 "symbol" => "BTCUSDT",
                 "side" => "BUY"
               }
             }
           ] = first.trade_log
  end

  test "disables trade log accumulation when include_trade_log is false" do
    candles_by_symbol = %{"BTCUSDT" => [%{open_time: 1_000, close: "100.0"}]}

    strategy_fun = fn _event, state ->
      {[%{side: "BUY", quantity: 1.0}], state}
    end

    order_executor = fn _params, _opts ->
      {:ok, %{status: "FILLED"}}
    end

    assert {:ok, result} =
             Runner.run(
               symbols: ["BTCUSDT"],
               interval: "1m",
               candles_by_symbol: candles_by_symbol,
               strategy_fun: strategy_fun,
               order_executor: order_executor,
               include_trade_log: false
             )

    assert result.summary.events_processed == 1
    assert result.summary.trades == 1
    assert result.summary.rejected_orders == 0
    assert result.trade_log == []
  end

  test "rejects spot sell orders when position is unavailable" do
    candles_by_symbol = %{"BTCUSDT" => [%{open_time: 1_000, close: "100.0"}]}

    strategy_fun = fn _event, state ->
      {[%{side: "SELL", quantity: 1.0}], state}
    end

    order_executor = fn _params, _opts ->
      send(self(), :executor_called)
      {:ok, %{status: "FILLED"}}
    end

    assert {:ok, result} =
             Runner.run(
               symbols: ["BTCUSDT"],
               interval: "15m",
               candles_by_symbol: candles_by_symbol,
               strategy_fun: strategy_fun,
               order_executor: order_executor
             )

    refute_received :executor_called
    assert result.summary.trades == 0
    assert result.summary.rejected_orders == 1

    assert [entry] = result.trade_log
    assert entry.status == "rejected"
    assert entry.reason == :insufficient_position
  end

  test "preserves deterministic order for tied timestamps across symbols" do
    candles_by_symbol = %{
      "BTCUSDT" => [
        %{open_time: 2_000, close: "101.0"},
        %{open_time: 1_000, close: "100.0"},
        %{open_time: 2_000, close: "102.0"}
      ],
      "ETHUSDT" => [
        %{open_time: 1_000, close: "200.0"},
        %{open_time: 2_000, close: "201.0"}
      ],
      "SOLUSDT" => [
        %{open_time: 1_500, close: "50.0"}
      ]
    }

    event_handler = fn event ->
      send(self(), {:event, event.symbol, event.open_time, event.candle.close})
    end

    assert {:ok, result} =
             Runner.run(
               symbols: ["BTCUSDT", "ETHUSDT", "SOLUSDT"],
               interval: "15m",
               candles_by_symbol: candles_by_symbol,
               event_handler: event_handler
             )

    assert_receive {:event, "BTCUSDT", 1_000, 100.0}
    assert_receive {:event, "ETHUSDT", 1_000, 200.0}
    assert_receive {:event, "SOLUSDT", 1_500, 50.0}
    assert_receive {:event, "BTCUSDT", 2_000, 101.0}
    assert_receive {:event, "BTCUSDT", 2_000, 102.0}
    assert_receive {:event, "ETHUSDT", 2_000, 201.0}

    assert result.summary.events_processed == 6
    assert result.summary.trades == 0
    assert result.trade_log == []
  end

  test "preserves intra-symbol order for tied timestamps when candles are already sorted" do
    candles_by_symbol = %{
      "BTCUSDT" => [
        %{open_time: 1_000, close: "100.0"},
        %{open_time: 1_000, close: "101.0"},
        %{open_time: 2_000, close: "102.0"}
      ],
      "ETHUSDT" => [
        %{open_time: 1_000, close: "200.0"},
        %{open_time: 2_000, close: "201.0"}
      ]
    }

    event_handler = fn event ->
      send(self(), {:event, event.symbol, event.open_time, event.candle.close})
    end

    assert {:ok, result} =
             Runner.run(
               symbols: ["BTCUSDT", "ETHUSDT"],
               interval: "15m",
               candles_by_symbol: candles_by_symbol,
               event_handler: event_handler
             )

    assert_receive {:event, "BTCUSDT", 1_000, 100.0}
    assert_receive {:event, "BTCUSDT", 1_000, 101.0}
    assert_receive {:event, "ETHUSDT", 1_000, 200.0}
    assert_receive {:event, "BTCUSDT", 2_000, 102.0}
    assert_receive {:event, "ETHUSDT", 2_000, 201.0}

    assert result.summary.events_processed == 5
    assert result.summary.trades == 0
    assert result.trade_log == []
  end

  test "defaults emitted timestamps to earliest candle across all symbols" do
    candles_by_symbol = %{
      "BTCUSDT" => [%{open_time: 1_000, close: "100.0"}],
      "ETHUSDT" => [%{open_time: 900, close: "200.0"}]
    }

    event_handler = fn event ->
      send(self(), {:event, event.symbol, event.open_time, event.emitted_at})
    end

    assert {:ok, result} =
             Runner.run(
               symbols: ["BTCUSDT", "ETHUSDT"],
               interval: "1m",
               candles_by_symbol: candles_by_symbol,
               event_handler: event_handler
             )

    assert_receive {:event, "ETHUSDT", 900, 900}
    assert_receive {:event, "BTCUSDT", 1_000, 1_000}
    assert result.summary.events_processed == 2
  end

  test "supports explicit simulation trading mode override" do
    candles_by_symbol = %{"BTCUSDT" => [%{open_time: 1_000, close: "100.0"}]}

    order_executor = fn _params, opts ->
      send(self(), {:executor_mode, Keyword.fetch!(opts, :trading_mode)})
      {:ok, %{status: "FILLED"}}
    end

    strategy_fun = fn _event, state ->
      {[%{side: "BUY", quantity: 1.0}], state}
    end

    assert {:ok, _result} =
             Runner.run(
               symbols: ["BTCUSDT"],
               interval: "1m",
               candles_by_symbol: candles_by_symbol,
               strategy_fun: strategy_fun,
               order_executor: order_executor,
               trading_mode: :live
             )

    assert_receive {:executor_mode, :live}
  end

  test "returns error for invalid simulation trading mode" do
    assert {:error, :invalid_trading_mode} =
             Runner.run(
               symbols: ["BTCUSDT"],
               interval: "1m",
               candles_by_symbol: %{"BTCUSDT" => [%{open_time: 1_000, close: "100.0"}]},
               trading_mode: :sandbox
             )
  end

  test "emits structured logs for strategy decisions when enabled" do
    candles_by_symbol = %{"BTCUSDT" => [%{open_time: 1_000, close: "100.0"}]}

    strategy_fun = fn _event, state ->
      {[%{side: "BUY", quantity: 1.0}], state}
    end

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, _result} =
                 Runner.run(
                   symbols: ["BTCUSDT"],
                   interval: "1m",
                   candles_by_symbol: candles_by_symbol,
                   log_strategy_decisions: true,
                   strategy_fun: strategy_fun,
                   order_executor: fn _params, _opts -> {:ok, %{status: "FILLED"}} end
                 )
      end)

    assert log =~ "simulation_event"
    assert log =~ "\"event\":\"strategy_decision\""
    assert log =~ "\"symbol\":\"BTCUSDT\""
    assert log =~ "\"orders\":1"
  end

  test "does not emit strategy decision logs by default" do
    candles_by_symbol = %{"BTCUSDT" => [%{open_time: 1_000, close: "100.0"}]}

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, result} =
                 Runner.run(
                   symbols: ["BTCUSDT"],
                   interval: "1m",
                   candles_by_symbol: candles_by_symbol,
                   strategy_fun: fn _event, state -> {[], state} end
                 )

        assert result.summary.events_processed == 1
      end)

    refute log =~ "simulation_event"
  end
end
