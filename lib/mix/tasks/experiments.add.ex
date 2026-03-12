defmodule Mix.Tasks.Experiments.Add do
  use Mix.Task

  alias CriptoTrader.Experiments.{Config, State}

  @shortdoc "Queue a new experiment"
  @moduledoc """
  Queues a new experiment by writing entries to hypotheses.json and experiments.json.

  ## Usage

      mix experiments.add \\
        --strategy MODULE \\
        --hypothesis "Text of hypothesis" \\
        [--symbols SYM1,SYM2] \\
        [--interval 15m] \\
        [--balance 10000] \\
        [--param key=val ...]

  ## Examples

      mix experiments.add \\
        --strategy CriptoTrader.Strategy.BuyAndHold \\
        --hypothesis "Sanity check baseline" \\
        --symbols BTCUSDC,ETHUSDC \\
        --interval 15m
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        switches: [
          strategy: :string,
          hypothesis: :string,
          symbols: :string,
          interval: :string,
          balance: :string,
          param: :keep
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    strategy = required!(opts, :strategy, "--strategy")
    hypothesis_text = required!(opts, :hypothesis, "--hypothesis")

    symbols =
      opts
      |> Keyword.get(:symbols, Enum.join(Config.default_symbols(), ","))
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.upcase/1)

    interval = Keyword.get(opts, :interval, Config.default_interval())

    balance =
      opts
      |> Keyword.get(:balance, to_string(Config.default_initial_balance()))
      |> parse_float!(:balance)

    params =
      opts
      |> Keyword.get_values(:param)
      |> Enum.reduce(%{}, fn param_str, acc ->
        case String.split(param_str, "=", parts: 2) do
          [k, v] -> Map.put(acc, k, v)
          _ -> Mix.raise("Invalid --param format (expected key=value): #{param_str}")
        end
      end)

    mix_start_app()

    {:ok, hypothesis_id} =
      State.add_hypothesis(%{
        "text" => hypothesis_text,
        "strategy_module" => strategy,
        "queued_at" => iso_now()
      })

    exp_id = generate_exp_id()

    experiment = %{
      "id" => exp_id,
      "hypothesis_id" => hypothesis_id,
      "strategy_module" => strategy,
      "strategy_params" => params,
      "symbols" => symbols,
      "interval" => interval,
      "initial_balance" => balance,
      "status" => "pending",
      "training_result" => nil,
      "validation_result" => nil,
      "baseline_training" => nil,
      "baseline_validation" => nil,
      "verdict" => nil,
      "queued_at" => iso_now(),
      "finished_at" => nil
    }

    :ok = State.upsert_experiment(experiment)

    Mix.shell().info("Queued experiment #{exp_id} (hypothesis #{hypothesis_id})")
    Mix.shell().info("  strategy: #{strategy}")
    Mix.shell().info("  symbols:  #{Enum.join(symbols, ", ")}")
    Mix.shell().info("  interval: #{interval}, balance: #{balance}")
  end

  defp required!(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("Missing required option #{flag}")
    end
  end

  defp parse_float!(value, key) do
    case Float.parse(to_string(value)) do
      {f, _} when f > 0 -> f
      _ -> Mix.raise("Invalid value for --#{key}: #{value}")
    end
  end

  defp generate_exp_id do
    ts = System.system_time(:millisecond)
    suffix = :rand.uniform(9999) |> Integer.to_string() |> String.pad_leading(4, "0")
    "exp-#{ts}-#{suffix}"
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp mix_start_app do
    Mix.Task.run("app.start", [])
  end
end
