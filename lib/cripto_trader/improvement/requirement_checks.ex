defmodule CriptoTrader.Improvement.RequirementChecks do
  @moduledoc false

  alias CriptoTrader.Binance.Client, as: BinanceClient
  alias CriptoTrader.MarketData.Candles
  alias CriptoTrader.OrderManager
  alias CriptoTrader.Risk.Config, as: RiskConfig
  alias CriptoTrader.Simulation.Runner
  alias CriptoTrader.Strategy.Alternating

  @type check_result :: %{
          status: :met | :gap | :unknown,
          summary: String.t(),
          details: String.t(),
          evidence: list(String.t()),
          tags: list(String.t())
        }

  @ac2_symbols ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
  @ac2_days 90
  @ac2_interval "15m"
  @ac2_speed 100
  @ac2_max_runtime_us 300_000_000
  @fifteen_min_ms 15 * 60 * 1_000
  @candles_per_day div(24 * 60, 15)
  @check_receive_timeout_ms 500

  @spec check(String.t(), String.t()) :: check_result()
  def check("ac-1", description) do
    tags = ["requirements", "data_extraction"]

    with {:ok, task_evidence} <- verify_fetch_task_module(),
         {:ok, fetch_evidence} <- verify_fetch_task_cli() do
      met_result(description, task_evidence ++ fetch_evidence, tags)
    else
      {:error, evidence, guidance} ->
        gap_result(description, evidence, tags, guidance)
    end
  end

  def check("ac-2", description) do
    tags = ["requirements", "simulation", "performance"]

    with {:ok, task_evidence} <- verify_simulation_benchmark_task_module(),
         {:ok, cli_evidence} <- verify_simulation_benchmark_cli(),
         {:ok, result} <- benchmark_three_month_simulation() do
      met_result(
        description,
        task_evidence ++
          cli_evidence ++
          [
            "Processed #{result.events_processed} events in #{formatted_seconds(result.elapsed_us)}s",
            "Threshold: #{formatted_seconds(@ac2_max_runtime_us)}s for #{@ac2_days} days of #{@ac2_interval} candles"
          ],
        tags
      )
    else
      {:error, evidence, guidance} ->
        gap_result(description, evidence, tags, guidance)
    end
  end

  def check("ac-3", description) do
    tags = ["requirements", "simulation", "multi_symbol"]

    with {:ok, evidence} <- verify_multi_symbol_strategy_execution() do
      met_result(description, evidence, tags)
    else
      {:error, evidence, guidance} ->
        gap_result(description, evidence, tags, guidance)
    end
  end

  def check("ac-4", description) do
    tags = ["requirements", "risk", "paper", "live"]

    with {:ok, evidence} <- verify_risk_enforcement_paths() do
      met_result(description, evidence, tags)
    else
      {:error, evidence, guidance} ->
        gap_result(
          description,
          evidence,
          tags,
          guidance
        )
    end
  end

  def check(_criterion_id, description) do
    %{
      status: :unknown,
      summary: "No automated check for requirement",
      details: description,
      evidence: [],
      tags: ["requirements", "manual_review"]
    }
  end

  defp verify_fetch_task_module do
    module = Mix.Tasks.Binance.FetchCandles

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :run, 1) do
          {:ok, ["Found #{inspect(module)}.run/1"]}
        else
          {:error, ["Missing #{inspect(module)}.run/1"],
           "Implement a Mix task entrypoint that accepts CLI args and fetches candles."}
        end

      {:error, reason} ->
        {:error, ["Could not load #{inspect(module)}: #{inspect(reason)}"],
         "Add a Mix task to fetch Binance Spot klines with symbol/interval/date-range pagination."}
    end
  end

  defp verify_fetch_task_cli do
    parent = self()
    expected_symbol = "BTCUSDT"
    expected_interval = "1m"
    start_time = 1_704_067_200_000
    second_open_time = start_time + 60_000
    third_open_time = second_open_time + 60_000
    end_time = third_open_time
    expected_limit = 2
    expected_second_cursor = second_open_time + 1
    previous_fetch_fun = Application.get_env(:cripto_trader, :candles_fetch_fun)
    previous_skip_app_start = Application.get_env(:cripto_trader, :skip_mix_app_start)
    previous_shell = Mix.shell()

    Application.put_env(:cripto_trader, :skip_mix_app_start, true)
    Mix.shell(Mix.Shell.Process)

    Application.put_env(:cripto_trader, :candles_fetch_fun, fn opts ->
      send(parent, {:ac1_fetch_task_opts, opts})

      Candles.fetch(
        opts
        |> Keyword.put(:max_concurrency, 1)
        |> Keyword.put(:klines_fun, fn _client, params ->
          send(parent, {:ac1_klines_params, params})

          case Keyword.get(params, :startTime, start_time) do
            ^start_time ->
              {:ok,
               [ac1_raw_kline(start_time, "101.0"), ac1_raw_kline(second_open_time, "102.0")]}

            ^expected_second_cursor ->
              {:ok, [ac1_raw_kline(third_open_time, "103.0")]}

            other ->
              {:error, {:unexpected_cursor, other}}
          end
        end)
      )
    end)

    try do
      Mix.Tasks.Binance.FetchCandles.run([
        "--symbol",
        expected_symbol,
        "--interval",
        expected_interval,
        "--start-time",
        Integer.to_string(start_time),
        "--end-time",
        Integer.to_string(end_time),
        "--limit",
        Integer.to_string(expected_limit)
      ])

      with {:ok, opts} <- receive_fetch_task_opts(),
           true <-
             ac1_task_opts_match?(
               opts,
               expected_symbol,
               expected_interval,
               start_time,
               end_time,
               expected_limit
             ),
           {:ok, requests} <- receive_ac1_klines_requests(2),
           true <-
             ac1_klines_requests_match?(
               requests,
               expected_symbol,
               expected_interval,
               start_time,
               end_time,
               expected_limit,
               expected_second_cursor
             ),
           {:ok, payload} <- receive_fetch_task_output(),
           true <-
             ac1_payload_matches?(
               payload,
               expected_symbol,
               expected_interval,
               start_time,
               end_time,
               second_open_time,
               third_open_time
             ) do
        {:ok,
         [
           "`Mix.Tasks.Binance.FetchCandles` executes paginated symbol/interval/date-range fetch path"
         ]}
      else
        false ->
          {:error, ["CLI task output/options did not match expected request payload"],
           "Ensure candle extraction CLI prints expected symbol/interval/date-range results for requested candles."}

        {:error, reason} ->
          {:error, ["CLI task verification failed: #{inspect(reason)}"],
           "Ensure candle extraction CLI executes and prints deterministic candle payloads for requested symbol/interval."}
      end
    rescue
      exception in Mix.Error ->
        {:error, ["Candle extraction CLI failed: #{Exception.message(exception)}"],
         "Ensure the candle extraction CLI can fetch at least one symbol and interval."}
    after
      Mix.shell(previous_shell)
      restore_env(:candles_fetch_fun, previous_fetch_fun)
      restore_env(:skip_mix_app_start, previous_skip_app_start)
    end
  end

  defp verify_simulation_benchmark_task_module do
    module = Mix.Tasks.Binance.SimulationBenchmark

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :run, 1) do
          {:ok, ["Found #{inspect(module)}.run/1"]}
        else
          {:error, ["Missing #{inspect(module)}.run/1"],
           "Implement a Mix task entrypoint that benchmarks 3-month 15m simulation throughput."}
        end

      {:error, reason} ->
        {:error, ["Could not load #{inspect(module)}: #{inspect(reason)}"],
         "Expose a Mix task to benchmark deterministic 3-month 15m simulation throughput."}
    end
  end

  defp verify_simulation_benchmark_cli do
    parent = self()
    expected_symbols = @ac2_symbols
    expected_days = @ac2_days
    expected_speed = @ac2_speed
    expected_initial_balance = 10_000.0
    expected_quantity = 1.0
    expected_events = expected_days * @candles_per_day * length(expected_symbols)
    expected_elapsed_us = 1_250_000
    previous_runner_fun = Application.get_env(:cripto_trader, :simulation_benchmark_runner_fun)
    previous_timer_fun = Application.get_env(:cripto_trader, :simulation_benchmark_timer_fun)
    previous_skip_app_start = Application.get_env(:cripto_trader, :skip_mix_app_start)
    previous_shell = Mix.shell()

    Application.put_env(:cripto_trader, :skip_mix_app_start, true)
    Mix.shell(Mix.Shell.Process)

    Application.put_env(:cripto_trader, :simulation_benchmark_runner_fun, fn opts ->
      send(
        parent,
        {:ac2_benchmark_runner_opts,
         ac2_runner_opts_snapshot(opts, expected_symbols, expected_quantity)}
      )

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
           events_processed: expected_events
         },
         equity_curve: []
       }}
    end)

    Application.put_env(:cripto_trader, :simulation_benchmark_timer_fun, fn fun ->
      {expected_elapsed_us, fun.()}
    end)

    try do
      Mix.Tasks.Binance.SimulationBenchmark.run([])

      with {:ok, runner_opts} <- receive_simulation_benchmark_runner_opts(),
           true <-
             ac2_runner_opts_match?(
               runner_opts,
               expected_symbols,
               expected_speed,
               expected_initial_balance
             ),
           {:ok, payload} <- receive_simulation_benchmark_payload(),
           true <-
             ac2_benchmark_payload_matches?(
               payload,
               expected_symbols,
               expected_days,
               expected_speed,
               expected_elapsed_us,
               expected_events
             ) do
        {:ok,
         [
           "`Mix.Tasks.Binance.SimulationBenchmark` executes deterministic 3-month 15m benchmark path"
         ]}
      else
        false ->
          {:error, ["Simulation benchmark CLI output/options did not match expected payload"],
           "Ensure benchmark CLI emits deterministic throughput payload for default 3-month 15m run."}

        {:error, reason} ->
          {:error, ["Simulation benchmark CLI verification failed: #{inspect(reason)}"],
           "Ensure benchmark CLI executes and reports deterministic 3-month 15m throughput evidence."}
      end
    rescue
      exception in Mix.Error ->
        {:error, ["Simulation benchmark CLI failed: #{Exception.message(exception)}"],
         "Ensure benchmark CLI can execute deterministic 3-month 15m simulation throughput checks."}
    after
      Mix.shell(previous_shell)
      restore_env(:simulation_benchmark_runner_fun, previous_runner_fun)
      restore_env(:simulation_benchmark_timer_fun, previous_timer_fun)
      restore_env(:skip_mix_app_start, previous_skip_app_start)
    end
  end

  defp benchmark_three_month_simulation do
    candles = build_15m_candles(1_700_000_000_000, @ac2_days)
    candles_by_symbol = Map.new(@ac2_symbols, fn symbol -> {symbol, candles} end)
    expected_events = length(candles) * length(@ac2_symbols)

    run_opts = [
      symbols: @ac2_symbols,
      interval: @ac2_interval,
      candles_by_symbol: candles_by_symbol,
      speed: @ac2_speed,
      include_trade_log: false,
      log_strategy_decisions: false,
      include_equity_curve: false,
      strategy_fun: &Alternating.signal/2,
      strategy_state: Alternating.new_state(@ac2_symbols, 1.0),
      order_executor: fn params, _opts ->
        {:ok, %{status: "FILLED", symbol: params.symbol, side: params.side}}
      end
    ]

    {elapsed_us, run_result} = :timer.tc(fn -> Runner.run(run_opts) end)

    case run_result do
      {:ok, %{summary: %{events_processed: ^expected_events}}} ->
        if elapsed_us <= @ac2_max_runtime_us do
          {:ok, %{elapsed_us: elapsed_us, events_processed: expected_events}}
        else
          {:error,
           [
             "Simulation processed #{expected_events} events in #{formatted_seconds(elapsed_us)}s",
             "Exceeded max runtime #{formatted_seconds(@ac2_max_runtime_us)}s"
           ], "Optimize replay/event-processing throughput for 90 days of 15m candles."}
        end

      {:ok, %{summary: %{events_processed: processed_events}}} ->
        {:error,
         [
           "Expected #{expected_events} processed events but got #{inspect(processed_events)}",
           "Elapsed runtime was #{formatted_seconds(elapsed_us)}s"
         ], "Ensure simulation processes the full 3-month 15m workload."}

      {:error, reason} ->
        {:error, ["Simulation benchmark run failed: #{inspect(reason)}"],
         "Implement deterministic multi-symbol simulation replay for historical candles."}
    end
  end

  defp verify_multi_symbol_strategy_execution do
    ref = make_ref()
    parent = self()
    symbols = ["BTCUSDT", "ETHUSDT"]

    candles_by_symbol = %{
      "BTCUSDT" => [%{open_time: 1_000, close: "100.0"}],
      "ETHUSDT" => [%{open_time: 1_000, close: "200.0"}]
    }

    strategy_fun = fn event, state ->
      send(parent, {:ac3_strategy_call, ref, event.symbol})
      {[%{side: "BUY", quantity: 0.1}], state}
    end

    order_executor = fn params, _opts ->
      {:ok, %{status: "FILLED", symbol: params.symbol, side: params.side}}
    end

    case Runner.run(
           symbols: symbols,
           interval: "1m",
           candles_by_symbol: candles_by_symbol,
           strategy_fun: strategy_fun,
           order_executor: order_executor
         ) do
      {:ok, result} ->
        called_symbols = collect_strategy_symbols(ref, length(symbols), MapSet.new())
        expected_symbols = MapSet.new(symbols)

        trade_symbols =
          result.trade_log
          |> Enum.map(&Map.get(&1, :symbol))
          |> MapSet.new()

        cond do
          called_symbols == :timeout ->
            {:error, ["Timed out while collecting strategy calls for multi-symbol run"],
             "Ensure one strategy function receives events for each configured symbol."}

          result.summary.events_processed != length(symbols) ->
            {:error,
             [
               "Expected #{length(symbols)} events but got #{inspect(result.summary.events_processed)}"
             ], "Ensure simulation replays all symbols through one strategy execution path."}

          called_symbols != expected_symbols ->
            {:error,
             [
               "Strategy saw symbols #{inspect(called_symbols)} instead of #{inspect(expected_symbols)}"
             ], "Ensure one strategy function is executed for each configured symbol event."}

          trade_symbols != expected_symbols ->
            {:error,
             [
               "Trade log symbols #{inspect(trade_symbols)} do not match configured symbols #{inspect(expected_symbols)}"
             ], "Ensure simulation order execution handles multiple symbols in a single run."}

          true ->
            {:ok,
             [
               "One strategy function processed events for #{length(symbols)} symbols in one simulation run",
               "Trade log contains fills for all configured symbols"
             ]}
        end

      {:error, reason} ->
        {:error, ["Multi-symbol simulation run failed: #{inspect(reason)}"],
         "Support one strategy across multiple symbols in simulation inputs and execution path."}
    end
  end

  defp verify_risk_enforcement_paths do
    parent = self()
    blocked_ref = make_ref()

    order = %{
      symbol: "BTCUSDT",
      side: "BUY",
      type: "LIMIT",
      quantity: 1.0,
      price: 100.0
    }

    strict_risk = %RiskConfig{
      max_order_quote: 10.0,
      max_drawdown_pct: 0.5,
      circuit_breaker: false
    }

    relaxed_risk = %RiskConfig{
      max_order_quote: 10_000.0,
      max_drawdown_pct: 0.5,
      circuit_breaker: false
    }

    with {:ok, _} <- ensure_paper_orders_started(),
         {:ok, order_manager_content} <- File.read("lib/cripto_trader/order_manager.ex"),
         true <- String.contains?(order_manager_content, "defp submit_order(params, :live, opts)"),
         true <- String.contains?(order_manager_content, "Spot.new_order"),
         {:error, {:risk, :max_order_quote}} <-
           OrderManager.place_order(order, trading_mode: :paper, risk_config: strict_risk),
         {:error, {:risk, :max_order_quote}} <-
           OrderManager.place_order(
             order,
             trading_mode: :live,
             risk_config: strict_risk,
             client: ac4_live_stub_client(parent, blocked_ref)
           ),
         false <- ac4_live_submit_received?(blocked_ref),
         {:ok, _paper_response} <-
           OrderManager.place_order(order, trading_mode: :paper, risk_config: relaxed_risk) do
      {:ok,
       [
         "Risk checks reject oversized orders before paper submission",
         "Risk checks reject oversized orders before live submission",
         "Paper mode accepts valid orders after risk checks",
         "OrderManager defines a dedicated live submission branch through Spot.new_order"
       ]}
    else
      {:error, reason} ->
        {:error, ["Risk enforcement verification failed: #{inspect(reason)}"],
         "Ensure risk checks run before order submission for both paper and live paths."}

      true ->
        {:error,
         ["Live submit path was called even though risk check should have rejected the order"],
         "Ensure live submission is gated by risk checks."}

      other ->
        {:error, ["Unexpected risk enforcement result: #{inspect(other)}"],
         "Ensure risk checks run before order submission for both paper and live paths."}
    end
  end

  defp ensure_paper_orders_started do
    case Process.whereis(CriptoTrader.Paper.Orders) do
      nil ->
        case CriptoTrader.Paper.Orders.start_link([]) do
          {:ok, _pid} -> {:ok, :started}
          {:error, {:already_started, _pid}} -> {:ok, :already_started}
          {:error, reason} -> {:error, {:paper_orders_start_failed, reason}}
        end

      _pid ->
        {:ok, :already_started}
    end
  end

  defp ac4_live_stub_client(parent, ref) do
    BinanceClient.new(
      api_key: "ac4-test-key",
      api_secret: "ac4-test-secret",
      request_fn: fn _opts ->
        send(parent, {:ac4_live_submit, ref})
        {:ok, %{status: 200, body: %{"status" => "FILLED"}}}
      end
    )
  end

  defp ac4_live_submit_received?(ref) do
    receive do
      {:ac4_live_submit, ^ref} -> true
    after
      100 -> false
    end
  end

  defp receive_fetch_task_opts do
    receive do
      {:ac1_fetch_task_opts, opts} -> {:ok, opts}
    after
      100 -> {:error, :timeout}
    end
  end

  defp ac1_task_opts_match?(
         opts,
         expected_symbol,
         expected_interval,
         start_time,
         end_time,
         expected_limit
       ) do
    Keyword.get(opts, :symbols) == [expected_symbol] and
      Keyword.get(opts, :interval) == expected_interval and
      Keyword.get(opts, :start_time) == start_time and
      Keyword.get(opts, :end_time) == end_time and
      Keyword.get(opts, :limit) == expected_limit
  end

  defp receive_ac1_klines_requests(expected_count)
       when is_integer(expected_count) and expected_count > 0 do
    do_receive_ac1_klines_requests(expected_count, [])
  end

  defp do_receive_ac1_klines_requests(0, acc), do: {:ok, Enum.reverse(acc)}

  defp do_receive_ac1_klines_requests(remaining, acc) do
    receive do
      {:ac1_klines_params, params} ->
        do_receive_ac1_klines_requests(remaining - 1, [params | acc])
    after
      100 -> {:error, :ac1_klines_timeout}
    end
  end

  defp ac1_klines_requests_match?(
         requests,
         expected_symbol,
         expected_interval,
         start_time,
         end_time,
         expected_limit,
         expected_second_cursor
       ) do
    requests == [
      [
        symbol: expected_symbol,
        interval: expected_interval,
        limit: expected_limit,
        startTime: start_time,
        endTime: end_time
      ],
      [
        symbol: expected_symbol,
        interval: expected_interval,
        limit: expected_limit,
        startTime: expected_second_cursor,
        endTime: end_time
      ]
    ]
  end

  defp receive_fetch_task_output do
    receive do
      {:mix_shell, :info, [output]} when is_binary(output) ->
        case Jason.decode(output) do
          {:ok, payload} -> {:ok, payload}
          {:error, reason} -> {:error, {:invalid_cli_json, reason}}
        end
    after
      100 -> {:error, :task_output_timeout}
    end
  end

  defp receive_simulation_benchmark_runner_opts do
    receive do
      {:ac2_benchmark_runner_opts, opts} -> {:ok, opts}
    after
      @check_receive_timeout_ms -> {:error, :ac2_runner_opts_timeout}
    end
  end

  defp ac2_runner_opts_match?(
         opts_snapshot,
         expected_symbols,
         expected_speed,
         expected_initial_balance
       ) do
    is_map(opts_snapshot) and
      opts_snapshot.symbols == expected_symbols and
      opts_snapshot.interval == @ac2_interval and
      opts_snapshot.speed == expected_speed and
      opts_snapshot.initial_balance == expected_initial_balance and
      opts_snapshot.include_trade_log == false and
      opts_snapshot.log_strategy_decisions == false and
      opts_snapshot.strategy_config_valid? and
      Enum.all?(expected_symbols, fn symbol ->
        Map.get(opts_snapshot.candle_counts_by_symbol, symbol) == @ac2_days * @candles_per_day
      end)
  end

  defp ac2_runner_opts_snapshot(opts, expected_symbols, expected_quantity) do
    candles_by_symbol = Keyword.get(opts, :candles_by_symbol, %{})

    %{
      symbols: Keyword.get(opts, :symbols),
      interval: Keyword.get(opts, :interval),
      speed: Keyword.get(opts, :speed),
      initial_balance: Keyword.get(opts, :initial_balance),
      include_trade_log: Keyword.get(opts, :include_trade_log),
      log_strategy_decisions: Keyword.get(opts, :log_strategy_decisions),
      candle_counts_by_symbol: ac2_candle_counts_snapshot(candles_by_symbol, expected_symbols),
      strategy_config_valid?:
        ac2_strategy_config_match?(opts, expected_symbols, expected_quantity)
    }
  end

  defp ac2_candle_counts_snapshot(candles_by_symbol, expected_symbols) do
    Map.new(expected_symbols, fn symbol ->
      count =
        case Map.get(candles_by_symbol, symbol) do
          candles when is_list(candles) -> length(candles)
          _ -> :invalid
        end

      {symbol, count}
    end)
  end

  defp ac2_strategy_config_match?(opts, expected_symbols, expected_quantity) do
    strategy_fun = Keyword.get(opts, :strategy_fun)
    strategy_state = Keyword.get(opts, :strategy_state)

    with true <- is_function(strategy_fun, 2),
         true <- is_map(strategy_state),
         {[first_symbol_order], first_symbol_state} <-
           strategy_fun.(%{symbol: hd(expected_symbols)}, strategy_state),
         {[second_symbol_order], _second_symbol_state} <-
           strategy_fun.(%{symbol: hd(expected_symbols)}, first_symbol_state),
         {[other_symbol_order], _other_symbol_state} <-
           strategy_fun.(%{symbol: Enum.at(expected_symbols, 1)}, first_symbol_state) do
      first_symbol_order.symbol == hd(expected_symbols) and
        first_symbol_order.side == "BUY" and
        first_symbol_order.quantity == expected_quantity and
        second_symbol_order.symbol == hd(expected_symbols) and
        second_symbol_order.side == "SELL" and
        second_symbol_order.quantity == expected_quantity and
        other_symbol_order.symbol == Enum.at(expected_symbols, 1) and
        other_symbol_order.side == "BUY" and
        other_symbol_order.quantity == expected_quantity
    else
      _ -> false
    end
  end

  defp receive_simulation_benchmark_payload do
    receive do
      {:mix_shell, :info, [output]} when is_binary(output) ->
        case Jason.decode(output) do
          {:ok, payload} -> {:ok, payload}
          {:error, reason} -> {:error, {:invalid_benchmark_cli_json, reason}}
        end
    after
      @check_receive_timeout_ms -> {:error, :ac2_payload_timeout}
    end
  end

  defp ac2_benchmark_payload_matches?(
         payload,
         expected_symbols,
         expected_days,
         expected_speed,
         expected_elapsed_us,
         expected_events
       ) do
    benchmark = payload["benchmark"] || %{}
    simulation = payload["simulation"] || %{}
    summary = simulation["summary"] || %{}

    benchmark["interval"] == @ac2_interval and
      benchmark["symbols"] == expected_symbols and
      benchmark["days"] == expected_days and
      benchmark["speed"] == expected_speed and
      benchmark["elapsed_seconds"] == expected_elapsed_us / 1_000_000 and
      benchmark["threshold_seconds"] == @ac2_max_runtime_us / 1_000_000 and
      benchmark["passed"] == true and
      simulation["expected_events"] == expected_events and
      simulation["trade_log_entries"] == 0 and
      summary["events_processed"] == expected_events
  end

  defp ac1_payload_matches?(
         payload,
         expected_symbol,
         expected_interval,
         start_time,
         end_time,
         second_open_time,
         third_open_time
       ) do
    expected_candles = [
      %{"open_time" => start_time, "close" => "101.0"},
      %{"open_time" => second_open_time, "close" => "102.0"},
      %{"open_time" => third_open_time, "close" => "103.0"}
    ]

    symbols_match? =
      case payload["symbols"] do
        [%{"symbol" => ^expected_symbol, "candles" => candles}] when is_list(candles) ->
          Enum.map(candles, &Map.take(&1, ["open_time", "close"])) == expected_candles

        _ ->
          false
      end

    payload["source"] == "binance_spot_rest" and
      payload["interval"] == expected_interval and
      payload["start_time"] == start_time and
      payload["end_time"] == end_time and
      symbols_match?
  end

  defp ac1_raw_kline(open_time, close) do
    [
      open_time,
      "100.0",
      "102.0",
      "99.0",
      close,
      "10.0",
      open_time + 59_999,
      "1010.0",
      20,
      "4.0",
      "404.0",
      "0"
    ]
  end

  defp collect_strategy_symbols(_ref, 0, symbols), do: symbols

  defp collect_strategy_symbols(ref, remaining, symbols) do
    receive do
      {:ac3_strategy_call, ^ref, symbol} ->
        collect_strategy_symbols(ref, remaining - 1, MapSet.put(symbols, symbol))
    after
      100 -> :timeout
    end
  end

  defp build_15m_candles(start_ms, days) do
    total = days * @candles_per_day

    Enum.map(0..(total - 1), fn index ->
      %{
        open_time: start_ms + index * @fifteen_min_ms,
        close: Float.to_string(100.0 + rem(index, 20) * 0.25)
      }
    end)
  end

  defp formatted_seconds(microseconds) do
    microseconds
    |> Kernel./(1_000_000)
    |> :erlang.float_to_binary(decimals: 6)
  end

  defp met_result(description, evidence, tags) do
    %{
      status: :met,
      summary: "Requirement appears satisfied",
      details: description,
      evidence: evidence,
      tags: tags
    }
  end

  defp gap_result(description, evidence, tags, guidance) do
    %{
      status: :gap,
      summary: "Requirement gap detected",
      details: "#{description} Guidance: #{guidance}",
      evidence: evidence,
      tags: tags
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:cripto_trader, key)
  defp restore_env(key, value), do: Application.put_env(:cripto_trader, key, value)
end
