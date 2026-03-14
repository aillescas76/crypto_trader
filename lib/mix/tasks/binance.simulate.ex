defmodule Mix.Tasks.Binance.Simulate do
  use Mix.Task

  alias CriptoTrader.MarketData.{ArchiveCandles, Candles}
  alias CriptoTrader.Simulation.Runner

  alias CriptoTrader.Strategy.{
    AltcoinCycle,
    Alternating,
    BbRsiReversion,
    BuyAndHold,
    IntradayMomentum,
    LateralRange,
    RegimeDetector,
    SharpeRankRotation
  }

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
          quote_per_trade: :string,
          stop_loss_pct: :string,
          trail_pct: :string,
          alt_trail_pct: :string,
          entry_ath: :string,
          initial_ath: :string,
          initial_balance: :string,
          include_equity_curve: :boolean,
          log_strategy_decisions: :boolean,
          cache_dir: :string,
          no_cache: :boolean
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

    quote_per_trade =
      parse_positive_number!(
        Keyword.get(opts, :quote_per_trade, "100.0"),
        :quote_per_trade
      )

    stop_loss_pct =
      parse_positive_number!(
        Keyword.get(opts, :stop_loss_pct, "0.02"),
        :stop_loss_pct
      )

    trail_pct =
      parse_positive_number!(
        Keyword.get(opts, :trail_pct, "0.003"),
        :trail_pct
      )

    alt_trail_pct =
      parse_positive_number!(
        Keyword.get(opts, :alt_trail_pct, "0.35"),
        :alt_trail_pct
      )

    entry_ath =
      parse_nonneg_number!(
        Keyword.get(opts, :entry_ath, "0.0"),
        :entry_ath
      )

    initial_ath =
      parse_nonneg_number!(
        Keyword.get(opts, :initial_ath, "0.0"),
        :initial_ath
      )

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

    {strategy_fun, strategy_state} =
      strategy_config(strategy, symbols, %{
        quantity: quantity,
        quote_per_trade: quote_per_trade,
        stop_loss_pct: stop_loss_pct,
        trail_pct: trail_pct,
        alt_trail_pct: alt_trail_pct,
        entry_ath: entry_ath,
        initial_ath: initial_ath
      })

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
              result: json_safe(result)
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

  defp fetch_opts!(:archive, symbols, interval, start_time, end_time, opts) do
    base = [
      symbols: symbols,
      interval: interval,
      start_time: start_time,
      end_time: end_time
    ]

    if Keyword.get(opts, :no_cache, false) do
      base
    else
      cache_dir =
        Keyword.get(opts, :cache_dir) ||
          Path.join(System.user_home!(), ".cripto_trader/archive_cache")

      base ++ [cache_dir: cache_dir]
    end
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

  defp parse_nonneg_number!(value, _key) when is_number(value) and value >= 0, do: value * 1.0

  defp parse_nonneg_number!(value, key) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} when number >= 0.0 ->
        number

      _ ->
        Mix.raise(
          "Invalid --#{key |> to_string() |> String.replace("_", "-")}. Use a non-negative number."
        )
    end
  end

  defp parse_nonneg_number!(_value, key) do
    Mix.raise(
      "Invalid --#{key |> to_string() |> String.replace("_", "-")}. Use a non-negative number."
    )
  end

  defp parse_limit!(limit) when is_integer(limit) and limit > 0 and limit <= @default_limit,
    do: limit

  defp parse_limit!(_), do: Mix.raise("Invalid --limit. Accepted range: 1..#{@default_limit}")

  defp parse_strategy!(strategy) when is_binary(strategy) do
    case strategy |> String.trim() |> String.downcase() do
      "alternating" ->
        :alternating

      "intraday_momentum" ->
        :intraday_momentum

      "bb_rsi_reversion" ->
        :bb_rsi_reversion

      "lateral_range" ->
        :lateral_range

      "regime_detector" ->
        :regime_detector

      "buy_and_hold" ->
        :buy_and_hold

      "altcoin_cycle" ->
        :altcoin_cycle

      "sharpe_rank_rotation" ->
        :sharpe_rank_rotation

      _ ->
        Mix.raise(
          "Invalid --strategy. Accepted values: alternating, intraday_momentum, bb_rsi_reversion, lateral_range, regime_detector, buy_and_hold, altcoin_cycle, sharpe_rank_rotation"
        )
    end
  end

  defp parse_strategy!(_),
    do:
      Mix.raise(
        "Invalid --strategy. Accepted values: alternating, intraday_momentum, bb_rsi_reversion, lateral_range, regime_detector, buy_and_hold, altcoin_cycle, sharpe_rank_rotation"
      )

  defp strategy_config(:alternating, symbols, %{quantity: quantity}) do
    {&Alternating.signal/2, Alternating.new_state(symbols, quantity)}
  end

  defp strategy_config(:buy_and_hold, symbols, %{quote_per_trade: quote_per_trade}) do
    {&BuyAndHold.signal/2, BuyAndHold.new_state(symbols, quote_per_trade: quote_per_trade)}
  end

  defp strategy_config(:bb_rsi_reversion, symbols, %{quote_per_trade: quote_per_trade}) do
    {&BbRsiReversion.signal/2,
     BbRsiReversion.new_state(symbols, quote_per_trade: quote_per_trade)}
  end

  defp strategy_config(:lateral_range, symbols, %{
         quote_per_trade: quote_per_trade,
         stop_loss_pct: stop_loss_pct
       }) do
    {&LateralRange.signal/2,
     LateralRange.new_state(symbols,
       quote_per_trade: quote_per_trade,
       stop_loss_pct: stop_loss_pct
     )}
  end

  defp strategy_config(:regime_detector, symbols, %{
         quote_per_trade: quote_per_trade,
         stop_loss_pct: stop_loss_pct,
         trail_pct: trail_pct
       }) do
    {&RegimeDetector.signal/2,
     RegimeDetector.new_state(symbols,
       quote_per_trade: quote_per_trade,
       stop_loss_pct: stop_loss_pct,
       trail_pct: trail_pct,
       # Use 1h candles for regime detection regardless of signal interval
       adx_timeframe_ms: 3_600_000
     )}
  end

  defp strategy_config(:sharpe_rank_rotation, symbols, %{quote_per_trade: quote_per_position}) do
    {&SharpeRankRotation.signal/2,
     SharpeRankRotation.new_state(symbols, quote_per_position: quote_per_position)}
  end

  defp strategy_config(:altcoin_cycle, symbols, %{
         quote_per_trade: quote_per_trade,
         trail_pct: trail_pct,
         alt_trail_pct: alt_trail_pct,
         entry_ath: entry_ath,
         initial_ath: initial_ath
       }) do
    {&AltcoinCycle.signal/2,
     AltcoinCycle.new_state(symbols,
       quote_per_trade: quote_per_trade,
       trail_pct: trail_pct,
       alt_trail_pct: alt_trail_pct,
       entry_ath: entry_ath,
       initial_ath: initial_ath
     )}
  end

  defp strategy_config(:intraday_momentum, symbols, %{
         quote_per_trade: quote_per_trade,
         stop_loss_pct: stop_loss_pct,
         trail_pct: trail_pct
       }) do
    {&IntradayMomentum.signal/2,
     IntradayMomentum.new_state(symbols,
       quote_per_trade: quote_per_trade,
       stop_loss_pct: stop_loss_pct,
       trail_pct: trail_pct
     )}
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
  defp output_strategy(:altcoin_cycle), do: "altcoin_cycle"
  defp output_strategy(:regime_detector), do: "regime_detector"
  defp output_strategy(:alternating), do: "alternating"
  defp output_strategy(:bb_rsi_reversion), do: "bb_rsi_reversion"
  defp output_strategy(:intraday_momentum), do: "intraday_momentum"
  defp output_strategy(:lateral_range), do: "lateral_range"
  defp output_strategy(:buy_and_hold), do: "buy_and_hold"
  defp output_mode(:paper), do: "paper"
  defp output_mode(:live), do: "live"

  defp maybe_start_app do
    unless Application.get_env(:cripto_trader, :skip_mix_app_start, false) do
      Mix.Task.run("app.start")
    end
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, json_safe(v)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(other), do: other
end
