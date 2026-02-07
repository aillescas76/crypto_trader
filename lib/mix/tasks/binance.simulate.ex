defmodule Mix.Tasks.Binance.Simulate do
  use Mix.Task

  alias CriptoTrader.MarketData.{ArchiveCandles, Candles}
  alias CriptoTrader.Simulation.Runner
  alias CriptoTrader.Strategy.Alternating

  @shortdoc "Run a Binance Spot simulation from historical candles"
  @default_speed 100
  @default_limit 1_000
  @default_initial_balance 10_000.0
  @default_quantity 0.1

  @impl Mix.Task
  def run(args) do
    maybe_start_app()

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        switches: [
          symbol: :keep,
          symbols: :string,
          source: :string,
          interval: :string,
          start_time: :string,
          end_time: :string,
          speed: :string,
          mode: :string,
          limit: :integer,
          strategy: :string,
          quantity: :string,
          initial_balance: :string,
          include_equity_curve: :boolean,
          log_strategy_decisions: :boolean
        ],
        aliases: [s: :symbol, i: :interval]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    symbols = parse_symbols(opts)
    source = parse_source!(Keyword.get(opts, :source, "archive"))
    interval = required_string!(opts, :interval)
    start_time = required_time!(opts, :start_time)
    end_time = required_time!(opts, :end_time)
    validate_range!(start_time, end_time)
    speed = parse_speed!(Keyword.get(opts, :speed, Integer.to_string(@default_speed)))
    mode = parse_mode!(Keyword.get(opts, :mode, "paper"))
    quantity = parse_positive_number!(Keyword.get(opts, :quantity, @default_quantity), :quantity)

    initial_balance =
      parse_positive_number!(
        Keyword.get(opts, :initial_balance, @default_initial_balance),
        :initial_balance
      )

    strategy = parse_strategy!(Keyword.get(opts, :strategy, "alternating"))
    include_equity_curve = Keyword.get(opts, :include_equity_curve, false)
    log_strategy_decisions = Keyword.get(opts, :log_strategy_decisions, false)

    fetch_opts = fetch_opts!(source, symbols, interval, start_time, end_time, opts)
    fetch_fun = candles_fetch_fun(source)
    runner_fun = simulation_runner_fun()
    {strategy_fun, strategy_state} = strategy_config(strategy, symbols, quantity)

    case fetch_fun.(fetch_opts) do
      {:ok, candles_by_symbol} ->
        simulation_opts = [
          symbols: symbols,
          interval: interval,
          candles_by_symbol: candles_by_symbol,
          speed: speed,
          trading_mode: mode,
          strategy_fun: strategy_fun,
          strategy_state: strategy_state,
          initial_balance: initial_balance,
          include_equity_curve: include_equity_curve,
          log_strategy_decisions: log_strategy_decisions
        ]

        case runner_fun.(simulation_opts) do
          {:ok, result} ->
            payload = %{
              source: output_source(source),
              strategy: output_strategy(strategy),
              symbols: symbols,
              interval: interval,
              start_time: start_time,
              end_time: end_time,
              speed: speed,
              mode: output_mode(mode),
              log_strategy_decisions: log_strategy_decisions,
              initial_balance: initial_balance,
              result: result
            }

            Mix.shell().info(Jason.encode!(payload, pretty: true))

          {:error, reason} ->
            Mix.raise("Simulation failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("Failed to load candles: #{inspect(reason)}")
    end
  end

  defp fetch_opts!(:rest, symbols, interval, start_time, end_time, opts) do
    limit = parse_limit!(Keyword.get(opts, :limit, @default_limit))

    [
      symbols: symbols,
      interval: interval,
      start_time: start_time,
      end_time: end_time,
      limit: limit
    ]
  end

  defp fetch_opts!(:archive, symbols, interval, start_time, end_time, _opts) do
    [
      symbols: symbols,
      interval: interval,
      start_time: start_time,
      end_time: end_time
    ]
  end

  defp parse_symbols(opts) do
    explicit =
      opts
      |> Keyword.get_values(:symbol)
      |> Enum.map(&String.upcase/1)

    grouped =
      opts
      |> Keyword.get(:symbols, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.upcase/1)

    symbols = Enum.uniq(explicit ++ grouped)

    if symbols == [] do
      Mix.raise("At least one symbol is required (--symbol BTCUSDT or --symbols BTCUSDT,ETHUSDT)")
    end

    symbols
  end

  defp parse_source!(source) when is_binary(source) do
    case source |> String.trim() |> String.downcase() do
      "rest" -> :rest
      "archive" -> :archive
      _ -> Mix.raise("Invalid --source. Accepted values: rest, archive")
    end
  end

  defp parse_source!(_), do: Mix.raise("Invalid --source. Accepted values: rest, archive")

  defp required_string!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        Mix.raise("Missing required option --#{key |> to_string() |> String.replace("_", "-")}")
    end
  end

  defp required_time!(opts, key) do
    value =
      case Keyword.get(opts, key) do
        nil ->
          Mix.raise("Missing required option --#{key |> to_string() |> String.replace("_", "-")}")

        time ->
          time
      end

    parse_time!(value)
  end

  defp parse_time!(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 ->
        int

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          _ -> Mix.raise("Invalid timestamp #{inspect(value)}. Use unix ms or ISO8601.")
        end
    end
  end

  defp parse_time!(value) when is_integer(value) and value >= 0, do: value

  defp parse_time!(value),
    do: Mix.raise("Invalid timestamp #{inspect(value)}. Use unix ms or ISO8601.")

  defp validate_range!(start_time, end_time) when start_time <= end_time, do: :ok

  defp validate_range!(_start_time, _end_time),
    do: Mix.raise("--start-time must be <= --end-time")

  defp parse_speed!(speed) when is_integer(speed) and speed > 0, do: speed

  defp parse_speed!(speed) when is_binary(speed) do
    case Integer.parse(String.trim(speed)) do
      {int, ""} when int > 0 -> int
      _ -> Mix.raise("Invalid --speed. Use a positive integer.")
    end
  end

  defp parse_speed!(_), do: Mix.raise("Invalid --speed. Use a positive integer.")

  defp parse_mode!(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "paper" -> :paper
      "live" -> :live
      _ -> Mix.raise("Invalid --mode. Accepted values: paper, live")
    end
  end

  defp parse_mode!(_), do: Mix.raise("Invalid --mode. Accepted values: paper, live")

  defp parse_positive_number!(value, _key) when is_number(value) and value > 0 do
    value * 1.0
  end

  defp parse_positive_number!(value, key) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} when number > 0.0 ->
        number

      _ ->
        Mix.raise(
          "Invalid --#{key |> to_string() |> String.replace("_", "-")}. Use a positive number."
        )
    end
  end

  defp parse_positive_number!(_value, key) do
    Mix.raise(
      "Invalid --#{key |> to_string() |> String.replace("_", "-")}. Use a positive number."
    )
  end

  defp parse_limit!(limit) when is_integer(limit) and limit > 0 and limit <= @default_limit,
    do: limit

  defp parse_limit!(_), do: Mix.raise("Invalid --limit. Accepted range: 1..#{@default_limit}")

  defp parse_strategy!(strategy) when is_binary(strategy) do
    case strategy |> String.trim() |> String.downcase() do
      "alternating" -> :alternating
      _ -> Mix.raise("Invalid --strategy. Accepted values: alternating")
    end
  end

  defp parse_strategy!(_), do: Mix.raise("Invalid --strategy. Accepted values: alternating")

  defp strategy_config(:alternating, symbols, quantity) do
    {&Alternating.signal/2, Alternating.new_state(symbols, quantity)}
  end

  defp candles_fetch_fun(:rest) do
    case Application.get_env(:cripto_trader, :simulation_candles_fetch_fun) do
      nil -> &Candles.fetch/1
      fun when is_function(fun, 1) -> fun
      other -> Mix.raise("Invalid :simulation_candles_fetch_fun config: #{inspect(other)}")
    end
  end

  defp candles_fetch_fun(:archive) do
    case Application.get_env(:cripto_trader, :simulation_archive_candles_fetch_fun) do
      nil ->
        &ArchiveCandles.fetch/1

      fun when is_function(fun, 1) ->
        fun

      other ->
        Mix.raise("Invalid :simulation_archive_candles_fetch_fun config: #{inspect(other)}")
    end
  end

  defp simulation_runner_fun do
    case Application.get_env(:cripto_trader, :simulation_runner_fun) do
      nil -> &Runner.run/1
      fun when is_function(fun, 1) -> fun
      other -> Mix.raise("Invalid :simulation_runner_fun config: #{inspect(other)}")
    end
  end

  defp output_source(:rest), do: "binance_spot_rest"
  defp output_source(:archive), do: "binance_spot_archive"
  defp output_strategy(:alternating), do: "alternating"
  defp output_mode(:paper), do: "paper"
  defp output_mode(:live), do: "live"

  defp maybe_start_app do
    unless Application.get_env(:cripto_trader, :skip_mix_app_start, false) do
      Mix.Task.run("app.start")
    end
  end
end
