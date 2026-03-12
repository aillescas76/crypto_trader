defmodule CriptoTrader.Experiments.Engine do
  @moduledoc false

  use GenServer

  require Logger

  alias CriptoTrader.Experiments.{Evaluator, Runner, State}

  @default_poll_interval_ms 30_000

  # Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Server

  @impl GenServer
  def init(opts) do
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    pubsub_server = Keyword.get(opts, :pubsub_server)

    state = %{
      poll_interval_ms: poll_interval_ms,
      pubsub_server: pubsub_server,
      running_task: nil,
      running_experiment_id: nil
    }

    schedule_poll(poll_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, %{running_task: task} = state) when not is_nil(task) do
    # A task is already running; skip this poll
    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    schedule_poll(state.poll_interval_ms)

    case find_pending() do
      nil ->
        {:noreply, state}

      experiment ->
        id = Map.get(experiment, "id")
        Logger.info("[Experiments.Engine] Starting experiment #{id}")

        updated = Map.merge(experiment, %{"status" => "running"})
        State.upsert_experiment(updated)
        broadcast(state.pubsub_server, updated)

        task =
          Task.Supervisor.async_nolink(
            CriptoTrader.Experiments.TaskSupervisor,
            fn -> {id, Runner.run(experiment), Evaluator} end
          )

        {:noreply, %{state | running_task: task, running_experiment_id: id}}
    end
  end

  def handle_info({ref, {id, runner_result, _evaluator_mod}}, state)
      when is_reference(ref) and state.running_task != nil and
             ref == state.running_task.ref do
    Process.demonitor(ref, [:flush])

    experiment =
      case fetch_experiment(id) do
        nil -> %{"id" => id}
        exp -> exp
      end

    {status, training_result, validation_result, baseline_training, baseline_validation, verdict} =
      case runner_result do
        {:ok, results} ->
          evaluation = Evaluator.evaluate(results)

          {
            if(evaluation.verdict == :pass, do: "passed", else: "failed"),
            results.training,
            results.validation,
            results.baseline_training,
            results.baseline_validation,
            evaluation
          }

        {:error, reason} ->
          Logger.error("[Experiments.Engine] Experiment #{id} error: #{inspect(reason)}")
          {"error", nil, nil, nil, nil, %{verdict: :fail, reasons: ["error: #{inspect(reason)}"]}}
      end

    updated =
      Map.merge(experiment, %{
        "status" => status,
        "training_result" => training_result,
        "validation_result" => validation_result,
        "baseline_training" => baseline_training,
        "baseline_validation" => baseline_validation,
        "verdict" => verdict,
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    State.upsert_experiment(updated)
    broadcast(state.pubsub_server, updated)

    Logger.info("[Experiments.Engine] Experiment #{id} finished: #{status}")

    {:noreply, %{state | running_task: nil, running_experiment_id: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when state.running_task != nil and ref == state.running_task.ref do
    id = state.running_experiment_id
    Logger.error("[Experiments.Engine] Experiment #{id} task crashed: #{inspect(reason)}")

    if id do
      experiment = fetch_experiment(id) || %{"id" => id}

      updated =
        Map.merge(experiment, %{
          "status" => "error",
          "verdict" => %{verdict: :fail, reasons: ["task crashed: #{inspect(reason)}"]},
          "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      State.upsert_experiment(updated)
      broadcast(state.pubsub_server, updated)
    end

    {:noreply, %{state | running_task: nil, running_experiment_id: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Helpers

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end

  defp find_pending do
    case State.list_experiments() do
      {:ok, experiments} ->
        Enum.find(experiments, fn e -> Map.get(e, "status") == "pending" end)

      _ ->
        nil
    end
  end

  defp fetch_experiment(id) do
    case State.list_experiments() do
      {:ok, experiments} ->
        Enum.find(experiments, fn e -> Map.get(e, "id") == id end)

      _ ->
        nil
    end
  end

  defp broadcast(nil, _experiment), do: :ok

  defp broadcast(pubsub_server, experiment) do
    Phoenix.PubSub.broadcast(pubsub_server, "experiments:updates", {:experiment_update, experiment})
  rescue
    _ -> :ok
  end
end
