defmodule CriptoTrader.Improvement.KnowledgeBase do
  @moduledoc false

  alias CriptoTrader.Improvement.{Config, Storage}

  @spec list() :: {:ok, list(map())} | {:error, term()}
  def list do
    Storage.read_json(Config.knowledge_base_file(), [])
  end

  @spec add(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def add(attrs) when is_list(attrs), do: add(Enum.into(attrs, %{}))

  def add(attrs) when is_map(attrs) do
    with {:ok, findings} <- list() do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      finding =
        %{
          "id" => next_finding_id(findings),
          "timestamp" => now,
          "task_id" => Map.get(attrs, "task_id") || Map.get(attrs, :task_id),
          "title" => required_string(attrs, "title", "Untitled finding"),
          "details" => optional_string(attrs, "details"),
          "tags" => normalize_tags(Map.get(attrs, "tags") || Map.get(attrs, :tags)),
          "data" => normalize_data(Map.get(attrs, "data") || Map.get(attrs, :data))
        }

      updated = findings ++ [finding]

      with :ok <- Storage.write_json(Config.knowledge_base_file(), updated) do
        {:ok, finding}
      end
    end
  end

  defp next_finding_id(findings) do
    next_number =
      findings
      |> Enum.map(& &1["id"])
      |> Enum.map(&parse_finding_id/1)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    "finding-#{next_number}"
  end

  defp parse_finding_id("finding-" <> suffix) do
    case Integer.parse(suffix) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp parse_finding_id(_value), do: 0

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

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(fn
      value when is_binary(value) -> String.trim(value)
      value -> to_string(value)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_tags(_tags), do: []

  defp normalize_data(data) when is_map(data), do: data
  defp normalize_data(_data), do: %{}
end
