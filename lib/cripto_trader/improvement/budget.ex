defmodule CriptoTrader.Improvement.Budget do
  @moduledoc false

  alias CriptoTrader.Improvement.{Config, Storage}

  @type snapshot :: map()

  @spec snapshot() :: {:ok, snapshot()} | {:error, term()}
  def snapshot do
    with {:ok, state} <- load_state() do
      {:ok, build_snapshot(state)}
    end
  end

  @spec ensure_available(non_neg_integer()) ::
          {:ok, snapshot()} | {:error, :budget_exhausted, snapshot()}
  def ensure_available(required_seconds \\ 1)
      when is_integer(required_seconds) and required_seconds >= 0 do
    with {:ok, snap} <- snapshot() do
      if snap["remaining_seconds"] >= required_seconds do
        {:ok, snap}
      else
        {:error, :budget_exhausted, snap}
      end
    end
  end

  @spec consume(non_neg_integer()) :: {:ok, snapshot()} | {:error, term()}
  def consume(seconds) when is_integer(seconds) and seconds >= 0 do
    with {:ok, state} <- load_state() do
      updated =
        state
        |> Map.update!("consumed_seconds", &(&1 + seconds))
        |> Map.put("last_updated_at", now_iso())

      snap = build_snapshot(updated)

      persist_snapshot(snap)
    end
  end

  @spec reset() :: {:ok, snapshot()} | {:error, term()}
  def reset do
    now = DateTime.utc_now()
    window = current_window(now)

    snapshot = %{
      "window_start" => window.start,
      "window_end" => window.finish,
      "limit_seconds" => Config.weekly_budget_seconds(),
      "consumed_seconds" => 0,
      "remaining_seconds" => Config.weekly_budget_seconds(),
      "last_updated_at" => now_iso()
    }

    persist_snapshot(snapshot)
  end

  defp load_state do
    with {:ok, state} <- Storage.read_json(Config.execution_budget_file(), nil) do
      ensure_current_window(state)
    end
  end

  defp ensure_current_window(nil), do: reset()

  defp ensure_current_window(state) when is_map(state) do
    now = DateTime.utc_now()
    window = current_window(now)

    if state_window_matches?(state, window) do
      state
      |> normalize_snapshot()
      |> persist_if_needed()
    else
      reset()
    end
  end

  defp persist_if_needed(snapshot) do
    case persist_snapshot(snapshot) do
      {:ok, persisted} -> {:ok, persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_snapshot(snapshot) do
    with :ok <- Storage.write_json(Config.execution_budget_file(), snapshot) do
      {:ok, snapshot}
    end
  end

  defp state_window_matches?(state, window) do
    state_start = Map.get(state, "window_start")
    state_end = Map.get(state, "window_end")

    state_start == window.start and state_end == window.finish
  end

  defp build_snapshot(state) do
    limit = normalize_positive_int(state["limit_seconds"], Config.weekly_budget_seconds())
    consumed = normalize_non_negative_int(state["consumed_seconds"], 0)
    remaining = max(limit - consumed, 0)

    %{
      "window_start" => state["window_start"],
      "window_end" => state["window_end"],
      "limit_seconds" => limit,
      "consumed_seconds" => consumed,
      "remaining_seconds" => remaining,
      "last_updated_at" => Map.get(state, "last_updated_at", now_iso())
    }
  end

  defp normalize_snapshot(state) do
    build_snapshot(%{
      "window_start" => Map.get(state, "window_start"),
      "window_end" => Map.get(state, "window_end"),
      "limit_seconds" => Map.get(state, "limit_seconds"),
      "consumed_seconds" => Map.get(state, "consumed_seconds"),
      "last_updated_at" => Map.get(state, "last_updated_at")
    })
  end

  defp current_window(now) do
    today = DateTime.to_date(now)
    week_start_date = Date.beginning_of_week(today, :monday)

    start = DateTime.new!(week_start_date, ~T[00:00:00], "Etc/UTC")
    finish = DateTime.add(start, 7 * 24 * 60 * 60, :second)

    %{
      start: DateTime.to_iso8601(start),
      finish: DateTime.to_iso8601(finish)
    }
  end

  defp now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
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
end
