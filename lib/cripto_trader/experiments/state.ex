defmodule CriptoTrader.Experiments.State do
  @moduledoc false

  alias CriptoTrader.Experiments.Config
  alias CriptoTrader.Improvement.Storage

  @spec list_experiments() :: {:ok, [map()]} | {:error, term()}
  def list_experiments do
    Storage.read_json(Config.experiments_file(), [])
  end

  @spec upsert_experiment(map()) :: :ok | {:error, term()}
  def upsert_experiment(experiment) do
    with {:ok, experiments} <- list_experiments() do
      id = Map.get(experiment, "id") || Map.get(experiment, :id)

      updated =
        case Enum.find_index(experiments, fn e ->
               Map.get(e, "id") == id || Map.get(e, :id) == id
             end) do
          nil -> experiments ++ [stringify_keys(experiment)]
          idx -> List.replace_at(experiments, idx, stringify_keys(experiment))
        end

      Storage.write_json(Config.experiments_file(), updated)
    end
  end

  @spec add_hypothesis(map()) :: {:ok, String.t()} | {:error, term()}
  def add_hypothesis(hypothesis) do
    with {:ok, hypotheses} <- Storage.read_json(Config.hypotheses_file(), []) do
      id = Map.get(hypothesis, "id") || Map.get(hypothesis, :id) || generate_id("hyp")
      entry = stringify_keys(Map.put(hypothesis, "id", id))
      :ok = Storage.write_json(Config.hypotheses_file(), hypotheses ++ [entry])
      {:ok, id}
    end
  end

  @spec list_findings() :: {:ok, [map()]} | {:error, term()}
  def list_findings do
    Storage.read_json(Config.findings_file(), [])
  end

  @spec add_finding(map()) :: {:ok, String.t()} | {:error, term()}
  def add_finding(finding) do
    with {:ok, findings} <- list_findings() do
      id = Map.get(finding, "id") || Map.get(finding, :id) || generate_id("fnd")

      entry =
        finding
        |> Map.put("id", id)
        |> Map.put_new("added_at", iso_now())
        |> stringify_keys()

      :ok = Storage.write_json(Config.findings_file(), findings ++ [entry])
      {:ok, id}
    end
  end

  @spec list_feedback() :: {:ok, [map()]} | {:error, term()}
  def list_feedback do
    Storage.read_json(Config.feedback_file(), [])
  end

  @spec add_feedback(map()) :: {:ok, String.t()} | {:error, term()}
  def add_feedback(feedback) do
    with {:ok, all_feedback} <- list_feedback() do
      id = Map.get(feedback, "id") || Map.get(feedback, :id) || generate_id("fbk")

      entry =
        feedback
        |> Map.put("id", id)
        |> Map.put_new("added_at", iso_now())
        |> Map.put_new("acknowledged", false)
        |> stringify_keys()

      :ok = Storage.write_json(Config.feedback_file(), all_feedback ++ [entry])
      {:ok, id}
    end
  end

  @spec acknowledge_feedback(String.t()) :: :ok | {:error, term()}
  def acknowledge_feedback(id) do
    with {:ok, all_feedback} <- list_feedback() do
      updated =
        Enum.map(all_feedback, fn entry ->
          if Map.get(entry, "id") == id do
            Map.put(entry, "acknowledged", true)
          else
            entry
          end
        end)

      Storage.write_json(Config.feedback_file(), updated)
    end
  end

  defp generate_id(prefix) do
    ts = System.system_time(:millisecond)
    suffix = :rand.uniform(9999) |> Integer.to_string() |> String.pad_leading(4, "0")
    "#{prefix}-#{ts}-#{suffix}"
  end

  defp iso_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
