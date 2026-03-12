defmodule CriptoTrader.Experiments.Runner do
  @moduledoc false

  alias CriptoTrader.Experiments.{Config, Metrics}
  alias CriptoTrader.MarketData.ArchiveCandles
  alias CriptoTrader.Simulation.Runner, as: SimRunner
  alias CriptoTrader.Strategy.BuyAndHold

  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(experiment) do
    symbols = get_symbols(experiment)
    interval = Map.get(experiment, "interval") || Config.default_interval()
    initial_balance = get_initial_balance(experiment)
    strategy_module = Map.get(experiment, "strategy_module")
    strategy_params = Map.get(experiment, "strategy_params") || %{}

    cutoff = Config.training_cutoff_ms()
    start_ms = Config.default_start_time_ms()
    end_ms = Config.default_end_time_ms()

    fetch_opts = [
      symbols: symbols,
      interval: interval,
      start_time: start_ms,
      end_time: end_ms,
      cache_dir: Config.cache_dir()
    ]

    with {:ok, candles_by_symbol} <- ArchiveCandles.fetch(fetch_opts),
         {:ok, mod} <- resolve_module(strategy_module),
         {:ok, training_candles} <- split_candles(candles_by_symbol, start_ms, cutoff - 1),
         {:ok, validation_candles} <- split_candles(candles_by_symbol, cutoff, end_ms) do
      strategy_opts = params_to_opts(strategy_params)

      with {:ok, training_result} <-
             run_simulation(mod, symbols, interval, training_candles, initial_balance, strategy_opts),
           {:ok, validation_result} <-
             run_simulation(mod, symbols, interval, validation_candles, initial_balance, strategy_opts),
           {:ok, baseline_training} <-
             run_baseline(symbols, interval, training_candles, initial_balance),
           {:ok, baseline_validation} <-
             run_baseline(symbols, interval, validation_candles, initial_balance) do
        training_enriched =
          Metrics.enrich_result(training_result, training_result.equity_curve, interval)

        validation_enriched =
          Metrics.enrich_result(validation_result, validation_result.equity_curve, interval)

        baseline_training_enriched =
          Metrics.enrich_result(baseline_training, baseline_training.equity_curve, interval)

        baseline_validation_enriched =
          Metrics.enrich_result(baseline_validation, baseline_validation.equity_curve, interval)

        {:ok,
         %{
           training: training_enriched,
           validation: validation_enriched,
           baseline_training: baseline_training_enriched,
           baseline_validation: baseline_validation_enriched
         }}
      end
    end
  end

  defp run_simulation(mod, symbols, interval, candles_by_symbol, initial_balance, strategy_opts) do
    strategy_state = apply(mod, :new_state, [symbols, strategy_opts])
    strategy_fun = &apply(mod, :signal, [&1, &2])

    SimRunner.run(
      symbols: symbols,
      interval: interval,
      candles_by_symbol: candles_by_symbol,
      strategy_fun: strategy_fun,
      strategy_state: strategy_state,
      initial_balance: initial_balance,
      include_equity_curve: true,
      include_trade_log: false,
      log_strategy_decisions: false
    )
  end

  defp run_baseline(symbols, interval, candles_by_symbol, initial_balance) do
    strategy_state = BuyAndHold.new_state(symbols, quote_per_trade: initial_balance / length(symbols))
    strategy_fun = &BuyAndHold.signal/2

    SimRunner.run(
      symbols: symbols,
      interval: interval,
      candles_by_symbol: candles_by_symbol,
      strategy_fun: strategy_fun,
      strategy_state: strategy_state,
      initial_balance: initial_balance,
      include_equity_curve: true,
      include_trade_log: false,
      log_strategy_decisions: false
    )
  end

  defp split_candles(candles_by_symbol, from_ms, to_ms) do
    result =
      Map.new(candles_by_symbol, fn {symbol, candles} ->
        filtered = Enum.filter(candles, fn c ->
          ot = candle_open_time(c)
          ot >= from_ms and ot <= to_ms
        end)
        {symbol, filtered}
      end)

    {:ok, result}
  end

  defp candle_open_time(%{open_time: t}), do: t
  defp candle_open_time(%{"open_time" => t}), do: t

  defp resolve_module(nil), do: {:error, :missing_strategy_module}

  defp resolve_module(module_string) when is_binary(module_string) do
    atom = String.to_existing_atom("Elixir.#{module_string}")
    {:ok, atom}
  rescue
    ArgumentError -> {:error, {:unknown_module, module_string}}
  end

  defp get_symbols(experiment) do
    case Map.get(experiment, "symbols") do
      syms when is_list(syms) and syms != [] -> syms
      _ -> Config.default_symbols()
    end
  end

  defp get_initial_balance(experiment) do
    case Map.get(experiment, "initial_balance") do
      b when is_number(b) and b > 0 -> b * 1.0
      _ -> Config.default_initial_balance()
    end
  end

  defp params_to_opts(params) when is_map(params) do
    Enum.map(params, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp params_to_opts(_), do: []
end
