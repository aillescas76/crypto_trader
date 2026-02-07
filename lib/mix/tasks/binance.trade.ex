defmodule Mix.Tasks.Binance.Trade do
  use Mix.Task

  alias CriptoTrader.Strategy.Alternating
  alias CriptoTrader.Trading.Robot

  @shortdoc "Run a Binance Spot trading robot loop (paper by default)"
  @default_iterations 1
  @default_poll_ms 0
  @default_limit 1
  @default_quantity 0.1

  @impl Mix.Task
  def run(args) do
    maybe_start_app()

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        switches: [
          symbol: :keep,
          symbols: :string,
          interval: :string,
          mode: :string,
          strategy: :string,
          quantity: :string,
          iterations: :integer,
          poll_ms: :integer,
          limit: :integer,
          start_time: :string,
          end_time: :string
        ],
        aliases: [s: :symbol, i: :interval]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    symbols = parse_symbols(opts)
    interval = required_string!(opts, :interval)
    mode = parse_mode!(Keyword.get(opts, :mode, "paper"))
    strategy = parse_strategy!(Keyword.get(opts, :strategy, "alternating"))
    quantity = parse_positive_number!(Keyword.get(opts, :quantity, @default_quantity), :quantity)
    iterations = parse_pos_int!(Keyword.get(opts, :iterations, @default_iterations), :iterations)
    poll_ms = parse_non_neg_int!(Keyword.get(opts, :poll_ms, @default_poll_ms), :poll_ms)
    limit = parse_pos_int!(Keyword.get(opts, :limit, @default_limit), :limit)
    start_time = parse_optional_time!(Keyword.get(opts, :start_time))
    end_time = parse_optional_time!(Keyword.get(opts, :end_time))
    validate_range!(start_time, end_time)

    {strategy_fun, strategy_state} = strategy_config(strategy, symbols, quantity)

    robot_opts =
      [
        symbols: symbols,
        interval: interval,
        trading_mode: mode,
        strategy_fun: strategy_fun,
        strategy_state: strategy_state,
        iterations: iterations,
        poll_ms: poll_ms,
        limit: limit,
        start_time: start_time,
        end_time: end_time
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case robot_fun().(robot_opts) do
      {:ok, result} ->
        payload = %{
          symbols: symbols,
          interval: interval,
          mode: output_mode(mode),
          strategy: output_strategy(strategy),
          quantity: quantity,
          iterations: iterations,
          poll_ms: poll_ms,
          limit: limit,
          start_time: start_time,
          end_time: end_time,
          result: result
        }

        Mix.shell().info(Jason.encode!(payload, pretty: true))

      {:error, reason} ->
        Mix.raise("Trading run failed: #{inspect(reason)}")
    end
  end

  defp parse_symbols(opts) do
    explicit =
      opts
      |> Keyword.get_values(:symbol)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
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

  defp required_string!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        Mix.raise("Missing required option --#{key |> to_string() |> String.replace("_", "-")}")
    end
  end

  defp parse_mode!(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "paper" -> :paper
      "live" -> :live
      _ -> Mix.raise("Invalid --mode. Accepted values: paper, live")
    end
  end

  defp parse_mode!(_), do: Mix.raise("Invalid --mode. Accepted values: paper, live")

  defp parse_strategy!(strategy) when is_binary(strategy) do
    case strategy |> String.trim() |> String.downcase() do
      "alternating" -> :alternating
      _ -> Mix.raise("Invalid --strategy. Accepted values: alternating")
    end
  end

  defp parse_strategy!(_), do: Mix.raise("Invalid --strategy. Accepted values: alternating")

  defp parse_positive_number!(value, _key) when is_number(value) and value > 0, do: value * 1.0

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

  defp parse_pos_int!(value, _key) when is_integer(value) and value > 0, do: value

  defp parse_pos_int!(_value, key) do
    Mix.raise(
      "Invalid --#{key |> to_string() |> String.replace("_", "-")}. Use a positive integer."
    )
  end

  defp parse_non_neg_int!(value, _key) when is_integer(value) and value >= 0, do: value

  defp parse_non_neg_int!(_value, key) do
    Mix.raise(
      "Invalid --#{key |> to_string() |> String.replace("_", "-")}. Use a non-negative integer."
    )
  end

  defp parse_optional_time!(nil), do: nil
  defp parse_optional_time!(value), do: parse_time!(value)

  defp parse_time!(value) when is_integer(value) and value >= 0, do: value

  defp parse_time!(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 ->
        int

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          _ -> Mix.raise("Invalid timestamp #{inspect(value)}. Use unix ms or ISO8601.")
        end
    end
  end

  defp parse_time!(value),
    do: Mix.raise("Invalid timestamp #{inspect(value)}. Use unix ms or ISO8601.")

  defp validate_range!(nil, nil), do: :ok
  defp validate_range!(start_time, nil) when is_integer(start_time), do: :ok
  defp validate_range!(nil, end_time) when is_integer(end_time), do: :ok
  defp validate_range!(start_time, end_time) when start_time <= end_time, do: :ok

  defp validate_range!(_start_time, _end_time),
    do: Mix.raise("--start-time must be <= --end-time")

  defp strategy_config(:alternating, symbols, quantity) do
    {&Alternating.signal/2, Alternating.new_state(symbols, quantity)}
  end

  defp output_mode(:paper), do: "paper"
  defp output_mode(:live), do: "live"
  defp output_strategy(:alternating), do: "alternating"

  defp robot_fun do
    case Application.get_env(:cripto_trader, :trading_robot_fun) do
      nil -> &Robot.run/1
      fun when is_function(fun, 1) -> fun
      other -> Mix.raise("Invalid :trading_robot_fun config: #{inspect(other)}")
    end
  end

  defp maybe_start_app do
    unless Application.get_env(:cripto_trader, :skip_mix_app_start, false) do
      Mix.Task.run("app.start")
    end
  end
end
