defmodule CriptoTrader.Improvement.AutonomousLoop do
  @moduledoc false

  alias CriptoTrader.Improvement.{
    Budget,
    Codex,
    Loop,
    LoopState,
    Reports,
    Tasks
  }

  @default_iterations 100
  @default_sleep_ms 300
  @default_max_tasks 10

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    run_id = run_id()
    iterations = normalize_positive_int(Keyword.get(opts, :iterations), @default_iterations)
    sleep_ms = normalize_non_negative_int(Keyword.get(opts, :sleep_ms), @default_sleep_ms)
    max_tasks = normalize_positive_int(Keyword.get(opts, :max_tasks), @default_max_tasks)
    requirements_path = Keyword.get(opts, :requirements_path, "docs/requirements.md")
    seed_requirements = Keyword.get(opts, :seed_requirements, true)
    stop_when_clean = Keyword.get(opts, :stop_when_clean, false)
    codex_enabled = Keyword.get(opts, :codex_enabled, true)
    min_iteration_budget = normalize_positive_int(Keyword.get(opts, :min_iteration_budget), 1)

    with :ok <- LoopState.begin_run(run_id) do
      iterate(
        1,
        iterations,
        %{
          run_id: run_id,
          sleep_ms: sleep_ms,
          max_tasks: max_tasks,
          requirements_path: requirements_path,
          seed_requirements: seed_requirements,
          stop_when_clean: stop_when_clean,
          codex_enabled: codex_enabled,
          min_iteration_budget: min_iteration_budget
        },
        []
      )
    end
  end

  defp iterate(current, max_iterations, settings, acc) when current > max_iterations do
    stop_reason = "stopped_iteration_cap"
    finalize(settings, current - 1, stop_reason, acc)
  end

  defp iterate(current, max_iterations, settings, acc) do
    case Budget.ensure_available(settings.min_iteration_budget) do
      {:ok, budget_before} ->
        started = System.monotonic_time(:millisecond)

        with :ok <-
               maybe_seed_requirements(settings.seed_requirements, settings.requirements_path),
             codex_result <- maybe_run_codex(settings, current, budget_before),
             {:ok, loop_result} <- Loop.run_once(max_tasks: settings.max_tasks),
             elapsed_seconds <- elapsed_seconds(started),
             {:ok, budget_after} <- Budget.consume(elapsed_seconds),
             :ok <- LoopState.update_iteration(current, codex_result, loop_result),
             {:ok, report} <-
               Reports.write(
                 run_id: settings.run_id,
                 iteration: current,
                 codex_result: codex_result,
                 loop_result: loop_result,
                 budget_snapshot: budget_after,
                 requirements_path: settings.requirements_path
               ) do
          iteration_entry = %{
            iteration: current,
            codex_exit_status: codex_result[:exit_status] || codex_result["exit_status"],
            processed_count: loop_result.processed_count,
            errors_count: loop_result.error_count,
            budget_remaining_seconds: budget_after["remaining_seconds"]
          }

          cond do
            settings.stop_when_clean and clean_state?(report.progress_report) ->
              finalize(settings, current, "stopped_clean", [iteration_entry | acc])

            current == max_iterations ->
              finalize(settings, current, "stopped_iteration_cap", [iteration_entry | acc])

            true ->
              sleep_if_needed(settings.sleep_ms)
              iterate(current + 1, max_iterations, settings, [iteration_entry | acc])
          end
        else
          {:error, reason} ->
            finalize(settings, current, "stopped_error", acc, reason)
        end

      {:error, :budget_exhausted, _snapshot} ->
        finalize(settings, current - 1, "paused_budget_exhausted", acc)
    end
  end

  defp finalize(settings, completed_iterations, stop_reason, iterations, reason \\ nil) do
    summary = %{
      run_id: settings.run_id,
      completed_iterations: completed_iterations,
      stop_reason: stop_reason,
      iterations: Enum.reverse(iterations)
    }

    with :ok <- LoopState.stop(stop_reason),
         {:ok, _} <- write_final_report(settings, completed_iterations, stop_reason) do
      if is_nil(reason) do
        {:ok, summary}
      else
        {:error, %{reason: reason, summary: summary}}
      end
    else
      {:error, finalize_reason} ->
        {:error, %{reason: merge_reasons(reason, finalize_reason), summary: summary}}
    end
  end

  defp write_final_report(settings, completed_iterations, stop_reason) do
    {codex_result, loop_result} =
      case LoopState.load() do
        {:ok, state} ->
          {Map.get(state, "last_codex_result", %{}), Map.get(state, "last_loop_result", %{})}

        {:error, _reason} ->
          {%{}, %{}}
      end

    budget_snapshot =
      case Budget.snapshot() do
        {:ok, snapshot} -> snapshot
        {:error, _reason} -> %{}
      end

    Reports.write(
      run_id: settings.run_id,
      iteration: completed_iterations,
      stop_reason: stop_reason,
      codex_result: codex_result,
      loop_result: loop_result,
      budget_snapshot: budget_snapshot,
      requirements_path: settings.requirements_path
    )
  end

  defp maybe_seed_requirements(true, path) do
    case Tasks.seed_from_requirements(path) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_seed_requirements(false, _path), do: :ok

  defp maybe_run_codex(settings, iteration, budget_before) do
    if settings.codex_enabled do
      prompt = build_codex_prompt(settings, iteration, budget_before)

      case Codex.run(prompt) do
        {:ok, result} -> result
        {:error, reason, result} -> Map.put(result, :error, inspect(reason))
      end
    else
      %{invoked: false, exit_status: nil, output_tail: "codex_disabled"}
    end
  end

  defp build_codex_prompt(_settings, iteration, budget_before) do
    """
    You are running autonomous improvement iteration #{iteration} for this Elixir Binance bot.

    Objective:
    - Move the project closer to fully meeting docs/requirements.md.

    Constraints:
    - Binance Spot only.
    - Paper mode default safety.
    - Keep architecture cleanly separated.
    - Do not run `mix improvement.loop.autorun` recursively.
    - Perform exactly one implementation pass and stop.

    Sources of truth:
    - docs/requirements.md
    - priv/improvement/progress_report.json
    - priv/improvement/agent_context.json
    - priv/improvement/tasks.json
    - priv/improvement/knowledge_base.json
    - docs/adr/

    Required outputs for this pass:
    1. Implement the highest-impact pending requirement gap.
    2. Add/update tests for changed behavior.
    3. Update docs if behavior changes.
    4. Record architecture decisions in docs/adr/ when needed.
    5. Keep changes deterministic and runnable via Mix.

    Budget context:
    - Weekly remaining seconds: #{budget_before["remaining_seconds"]}
    - Weekly reset at: #{budget_before["window_end"]}

    At the end, provide a concise summary of what changed and which acceptance criterion moved forward.
    """
    |> String.trim_leading()
  end

  defp clean_state?(progress_report) do
    requirements_open = get_in(progress_report, ["requirements", "open"]) || 0
    pending_count = get_in(progress_report, ["tasks", "by_status", "pending"]) || 0

    requirements_open == 0 and pending_count == 0
  end

  defp sleep_if_needed(ms) when is_integer(ms) and ms > 0 do
    Process.sleep(ms)
  end

  defp sleep_if_needed(_ms), do: :ok

  defp elapsed_seconds(started_millis) do
    diff = System.monotonic_time(:millisecond) - started_millis
    seconds = max(div(diff + 999, 1000), 1)
    seconds
  end

  defp run_id do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace([":", "-"], "")
  end

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_int(_value, default), do: default

  defp normalize_non_negative_int(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp normalize_non_negative_int(_value, default), do: default

  defp merge_reasons(nil, finalize_reason), do: {:finalization_failed, finalize_reason}

  defp merge_reasons(reason, finalize_reason),
    do: {reason, {:finalization_failed, finalize_reason}}
end
