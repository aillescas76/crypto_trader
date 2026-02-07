defmodule CriptoTrader.Improvement.Tasks do
  @moduledoc false

  alias CriptoTrader.Improvement.{Config, Requirements, Storage}

  @default_state %{"next_id" => 1, "tasks" => []}
  @valid_statuses ~w(pending in_progress done failed blocked)

  @spec create(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def create(attrs) when is_list(attrs), do: create(Enum.into(attrs, %{}))

  def create(attrs) when is_map(attrs) do
    with {:ok, state} <- load_state() do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      id = state["next_id"]

      task =
        %{
          "id" => id,
          "title" => required_string(attrs, "title", "Untitled task"),
          "description" => optional_string(attrs, "description"),
          "type" => required_string(attrs, "type", "note"),
          "status" => normalize_status(optional_string(attrs, "status") || "pending"),
          "priority" => normalize_priority(optional_string(attrs, "priority") || "normal"),
          "payload" => normalize_payload(Map.get(attrs, "payload") || Map.get(attrs, :payload)),
          "created_at" => now,
          "updated_at" => now,
          "last_result" => Map.get(attrs, "last_result") || Map.get(attrs, :last_result)
        }

      new_state = %{
        "next_id" => id + 1,
        "tasks" => state["tasks"] ++ [task]
      }

      with :ok <- save_state(new_state) do
        {:ok, task}
      end
    end
  end

  @spec update(pos_integer(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def update(id, attrs) when is_list(attrs), do: update(id, Enum.into(attrs, %{}))

  def update(id, attrs) when is_integer(id) and is_map(attrs) do
    with {:ok, state} <- load_state(),
         {:ok, updated_state, task} <- update_in_state(state, id, attrs),
         :ok <- save_state(updated_state) do
      {:ok, task}
    end
  end

  @spec list(keyword()) :: {:ok, list(map())} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, state} <- load_state() do
      tasks =
        state["tasks"]
        |> filter_status(Keyword.get(opts, :status))
        |> filter_type(Keyword.get(opts, :type))
        |> Enum.sort_by(& &1["id"])

      {:ok, tasks}
    end
  end

  @spec pending(non_neg_integer() | nil) :: {:ok, list(map())} | {:error, term()}
  def pending(limit \\ nil) do
    with {:ok, tasks} <- list(status: "pending") do
      tasks =
        tasks
        |> Enum.sort_by(fn task -> {priority_rank(task["priority"]), task["id"]} end)

      limited =
        case limit do
          value when is_integer(value) and value > 0 -> Enum.take(tasks, value)
          _ -> tasks
        end

      {:ok, limited}
    end
  end

  @spec seed_from_requirements(String.t()) :: {:ok, map()} | {:error, term()}
  def seed_from_requirements(path \\ "docs/requirements.md") do
    with {:ok, criteria} <- Requirements.acceptance_criteria(path),
         {:ok, state} <- load_state() do
      criteria_by_id = Map.new(criteria, &{&1["id"], &1})
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      {updated_tasks, reactivated} =
        Enum.map_reduce(state["tasks"], [], fn task, acc ->
          maybe_reactivate_requirement_task(task, criteria_by_id, now, acc)
        end)

      existing_criteria_ids =
        updated_tasks
        |> Enum.filter(&(&1["type"] == "requirement_gap"))
        |> Enum.map(&get_in(&1, ["payload", "criterion_id"]))
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      {next_id, created} =
        Enum.reduce(criteria, {state["next_id"], []}, fn criterion, {acc_next_id, acc_created} ->
          criterion_id = criterion["id"]

          if MapSet.member?(existing_criteria_ids, criterion_id) do
            {acc_next_id, acc_created}
          else
            task = new_requirement_task(acc_next_id, criterion, now)
            {acc_next_id + 1, [task | acc_created]}
          end
        end)

      new_state = %{
        "next_id" => next_id,
        "tasks" => updated_tasks ++ Enum.reverse(created)
      }

      with :ok <- save_state(new_state) do
        {:ok,
         %{
           created: Enum.reverse(created),
           reactivated: Enum.reverse(reactivated),
           total_criteria: length(criteria)
         }}
      end
    end
  end

  @spec set_status(pos_integer(), String.t(), map() | nil) :: {:ok, map()} | {:error, term()}
  def set_status(id, status, last_result \\ nil) when is_integer(id) and is_binary(status) do
    attrs = %{"status" => status, "last_result" => last_result}
    update(id, attrs)
  end

  defp update_in_state(state, id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Enum.find(state["tasks"], &(&1["id"] == id)) do
      nil ->
        {:error, :task_not_found}

      task ->
        updated_task =
          task
          |> maybe_put(attrs, "title", &required_string(%{"title" => &1}, "title", task["title"]))
          |> maybe_put(
            attrs,
            "description",
            &optional_string(%{"description" => &1}, "description")
          )
          |> maybe_put(attrs, "type", &required_string(%{"type" => &1}, "type", task["type"]))
          |> maybe_put(attrs, "status", &normalize_status/1)
          |> maybe_put(attrs, "priority", &normalize_priority/1)
          |> maybe_put(attrs, "payload", &normalize_payload/1)
          |> maybe_put(attrs, "last_result", & &1)
          |> Map.put("updated_at", now)

        new_tasks =
          Enum.map(state["tasks"], fn current ->
            if current["id"] == id, do: updated_task, else: current
          end)

        updated_state = %{"next_id" => state["next_id"], "tasks" => new_tasks}
        {:ok, updated_state, updated_task}
    end
  end

  defp maybe_put(task, attrs, key, transform) do
    value = Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

    if is_nil(value) do
      task
    else
      Map.put(task, key, transform.(value))
    end
  end

  defp filter_status(tasks, nil), do: tasks

  defp filter_status(tasks, status) when is_binary(status) do
    normalized = normalize_status(status)
    Enum.filter(tasks, &(&1["status"] == normalized))
  end

  defp filter_type(tasks, nil), do: tasks
  defp filter_type(tasks, type), do: Enum.filter(tasks, &(&1["type"] == type))

  defp normalize_priority("high"), do: "high"
  defp normalize_priority("low"), do: "low"
  defp normalize_priority(_value), do: "normal"

  defp normalize_status(status) when status in @valid_statuses, do: status
  defp normalize_status(_status), do: "pending"

  defp normalize_payload(value) when is_map(value), do: value
  defp normalize_payload(value) when is_list(value), do: Enum.into(value, %{})
  defp normalize_payload(_value), do: %{}

  defp required_string(attrs, key, default) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp optional_string(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) -> String.trim(value)
      nil -> nil
      value -> to_string(value)
    end
  end

  defp priority_rank("high"), do: 0
  defp priority_rank("normal"), do: 1
  defp priority_rank("low"), do: 2
  defp priority_rank(_value), do: 1

  defp maybe_reactivate_requirement_task(task, criteria_by_id, now, acc) do
    criterion_id = get_in(task, ["payload", "criterion_id"])
    criterion = Map.get(criteria_by_id, criterion_id)

    if task["type"] == "requirement_gap" and is_binary(criterion_id) and is_map(criterion) do
      refreshed =
        task
        |> Map.put("description", criterion["description"])
        |> Map.put("payload", %{
          "criterion_id" => criterion_id,
          "criterion_description" => criterion["description"]
        })
        |> maybe_touch_updated_at(task, now)

      if refreshed["status"] in ["failed", "blocked"] do
        reactivated =
          refreshed
          |> Map.put("status", "pending")
          |> Map.put("last_result", nil)
          |> Map.put("updated_at", now)

        {reactivated, [reactivated | acc]}
      else
        {refreshed, acc}
      end
    else
      {task, acc}
    end
  end

  defp maybe_touch_updated_at(task, original, now) do
    if task == original do
      task
    else
      Map.put(task, "updated_at", now)
    end
  end

  defp new_requirement_task(id, criterion, now) do
    %{
      "id" => id,
      "title" => "Requirement check #{criterion["id"]}",
      "description" => criterion["description"],
      "type" => "requirement_gap",
      "status" => "pending",
      "priority" => "normal",
      "payload" => %{
        "criterion_id" => criterion["id"],
        "criterion_description" => criterion["description"]
      },
      "created_at" => now,
      "updated_at" => now,
      "last_result" => nil
    }
  end

  defp load_state do
    with {:ok, state} <- Storage.read_json(Config.tasks_file(), @default_state) do
      normalized = %{
        "next_id" => normalize_next_id(state["next_id"]),
        "tasks" => normalize_tasks(state["tasks"])
      }

      {:ok, normalized}
    end
  end

  defp save_state(state) do
    Storage.write_json(Config.tasks_file(), state)
  end

  defp normalize_next_id(value) when is_integer(value) and value > 0, do: value
  defp normalize_next_id(_value), do: 1

  defp normalize_tasks(tasks) when is_list(tasks), do: tasks
  defp normalize_tasks(_tasks), do: []
end
