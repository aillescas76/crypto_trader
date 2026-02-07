defmodule Mix.Tasks.Binance.SimulationBenchmark do
  use Mix.Task

  alias CriptoTrader.Simulation.Runner
  alias CriptoTrader.Strategy.Alternating

  @shortdoc "Benchmark simulation throughput for 3 months of 15m candles"
  @default_symbols ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
  @default_days 90
  @default_speed 100
  @default_initial_balance 10_000.0
  @default_quantity 1.0
  @default_max_seconds 300.0
  @default_start_time_ms 1_700_000_000_000
  @interval "15m"
  @step_ms 15 * 60 * 1_000
  @candles_per_day div(24 * 60, 15)

  @impl Mix.Task
  def run(args) do
    maybe_start_app()

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        switches: [
          symbols: :string,
          days: :integer,
          speed: :integer,
          max_seconds: :float,
          initial_balance: :float,
          quantity: :float,
          start_time: :string,
          include_equity_curve: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    symbols = parse_symbols(opts)
    days = parse_days!(Keyword.get(opts, :days, @default_days))
    speed = parse_speed!(Keyword.get(opts, :speed, @default_speed))

    max_seconds =
      parse_positive_float!(Keyword.get(opts, :max_seconds, @default_max_seconds), :max_seconds)

    quantity =
      parse_positive_float!(Keyword.get(opts, :quantity, @default_quantity), :quantity)

    initial_balance =
      parse_positive_float!(
        Keyword.get(opts, :initial_balance, @default_initial_balance),
        :initial_balance
      )

    start_time =
      parse_time!(Keyword.get(opts, :start_time, Integer.to_string(@default_start_time_ms)))

    include_equity_curve = Keyword.get(opts, :include_equity_curve, false)

    candles = build_15m_candles(start_time, days)
    candles_by_symbol = Map.new(symbols, fn symbol -> {symbol, candles} end)
    runner_fun = simulation_benchmark_runner_fun()
    timer_fun = simulation_benchmark_timer_fun()
    max_microseconds = round(max_seconds * 1_000_000)
    total_events = length(candles) * length(symbols)

    run_opts = [
      symbols: symbols,
      interval: @interval,
      candles_by_symbol: candles_by_symbol,
      speed: speed,
      include_trade_log: false,
      log_strategy_decisions: false,
      strategy_fun: &Alternating.signal/2,
      strategy_state: Alternating.new_state(symbols, quantity),
      order_executor: &order_executor/2,
      include_equity_curve: include_equity_curve,
      initial_balance: initial_balance
    ]

    {elapsed_us, run_result} = timer_fun.(fn -> runner_fun.(run_opts) end)

    case run_result do
      {:ok, result} ->
        processed_events = get_in(result, [:summary, :events_processed])

        if processed_events != total_events do
          Mix.raise(
            "Simulation benchmark failed: expected #{total_events} events, got #{inspect(processed_events)}"
          )
        end

        payload = %{
          benchmark: %{
            interval: @interval,
            symbols: symbols,
            days: days,
            start_time: start_time,
            speed: speed,
            elapsed_seconds: elapsed_us / 1_000_000,
            threshold_seconds: max_seconds,
            passed: elapsed_us <= max_microseconds
          },
          simulation: %{
            expected_events: total_events,
            summary: result.summary,
            trade_log_entries: length(result.trade_log),
            equity_curve_points: length(result.equity_curve)
          }
        }

        Mix.shell().info(Jason.encode!(payload, pretty: true))

        if elapsed_us > max_microseconds do
          Mix.raise(
            "Simulation benchmark failed: elapsed #{elapsed_us / 1_000_000}s exceeded threshold #{max_seconds}s"
          )
        end

      {:error, reason} ->
        Mix.raise("Simulation benchmark failed to run: #{inspect(reason)}")
    end
  end

  defp parse_symbols(opts) do
    symbols =
      opts
      |> Keyword.get(:symbols, Enum.join(@default_symbols, ","))
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.upcase/1)
      |> Enum.uniq()

    if symbols == [] do
      Mix.raise("At least one symbol is required (--symbols BTCUSDT,ETHUSDT)")
    end

    symbols
  end

  defp parse_days!(days) when is_integer(days) and days > 0, do: days
  defp parse_days!(_), do: Mix.raise("Invalid --days. Use a positive integer.")

  defp parse_speed!(speed) when is_integer(speed) and speed > 0, do: speed
  defp parse_speed!(_), do: Mix.raise("Invalid --speed. Use a positive integer.")

  defp parse_positive_float!(value, _key) when is_number(value) and value > 0.0 do
    value * 1.0
  end

  defp parse_positive_float!(_value, key) do
    Mix.raise(
      "Invalid --#{key |> to_string() |> String.replace("_", "-")}. Use a positive number."
    )
  end

  defp parse_time!(value) when is_integer(value) and value >= 0, do: value

  defp parse_time!(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 ->
        int

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          _ -> Mix.raise("Invalid --start-time #{inspect(value)}. Use unix ms or ISO8601.")
        end
    end
  end

  defp parse_time!(_), do: Mix.raise("Invalid --start-time. Use unix ms or ISO8601.")

  defp build_15m_candles(start_ms, days) do
    total = days * @candles_per_day

    Enum.map(0..(total - 1), fn index ->
      %{
        open_time: start_ms + index * @step_ms,
        close: Float.to_string(100.0 + rem(index, 20) * 0.25)
      }
    end)
  end

  defp order_executor(params, _opts) do
    {:ok, %{status: "FILLED", symbol: params.symbol, side: params.side}}
  end

  defp simulation_benchmark_runner_fun do
    case Application.get_env(:cripto_trader, :simulation_benchmark_runner_fun) do
      nil -> &Runner.run/1
      fun when is_function(fun, 1) -> fun
      other -> Mix.raise("Invalid :simulation_benchmark_runner_fun config: #{inspect(other)}")
    end
  end

  defp simulation_benchmark_timer_fun do
    case Application.get_env(:cripto_trader, :simulation_benchmark_timer_fun) do
      nil -> &:timer.tc/1
      fun when is_function(fun, 1) -> fun
      other -> Mix.raise("Invalid :simulation_benchmark_timer_fun config: #{inspect(other)}")
    end
  end

  defp maybe_start_app do
    unless Application.get_env(:cripto_trader, :skip_mix_app_start, false) do
      Mix.Task.run("app.start")
    end
  end
end
