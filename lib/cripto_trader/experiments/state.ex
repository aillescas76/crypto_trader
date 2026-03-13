defmodule CriptoTrader.Experiments.State do
  @moduledoc false

  alias CriptoTrader.Experiments.Config
  alias CriptoTrader.Improvement.Storage

  @spec read_session() :: map()
  def read_session do
    case Storage.read_json(Config.session_file(), nil) do
      {:ok, nil} -> %{}
      {:ok, session} when is_map(session) -> session
      _ -> %{}
    end
  end

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

  @spec list_principles() :: {:ok, [map()]} | {:error, term()}
  def list_principles do
    Storage.read_json(Config.principles_file(), [])
  end

  @spec add_principle(map()) :: {:ok, String.t()} | {:error, term()}
  def add_principle(principle) do
    with {:ok, principles} <- list_principles() do
      id = Map.get(principle, "id") || Map.get(principle, :id) || generate_id("prn")

      entry =
        principle
        |> Map.put("id", id)
        |> Map.put_new("added_at", iso_now())
        |> stringify_keys()

      :ok = Storage.write_json(Config.principles_file(), principles ++ [entry])
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

  @spec list_investigations() :: {:ok, [map()]} | {:error, term()}
  def list_investigations do
    Storage.read_json(Config.investigations_file(), [])
  end

  @spec add_investigation(map()) :: {:ok, String.t()} | {:error, term()}
  def add_investigation(inv) do
    with {:ok, investigations} <- list_investigations() do
      id = Map.get(inv, "id") || Map.get(inv, :id) || generate_id("inv")
      now = iso_now()

      entry =
        inv
        |> Map.put("id", id)
        |> Map.put_new("status", "active")
        |> Map.put_new("experiments", [])
        |> Map.put_new("discard_reason", nil)
        |> Map.put_new("created_at", now)
        |> Map.put("updated_at", now)
        |> stringify_keys()

      :ok = Storage.write_json(Config.investigations_file(), investigations ++ [entry])
      {:ok, id}
    end
  end

  @spec discard_investigation(String.t(), String.t()) :: :ok | {:error, term()}
  def discard_investigation(id, reason) do
    with {:ok, investigations} <- list_investigations() do
      updated =
        Enum.map(investigations, fn inv ->
          if Map.get(inv, "id") == id do
            inv
            |> Map.put("status", "discarded")
            |> Map.put("discard_reason", reason)
            |> Map.put("updated_at", iso_now())
          else
            inv
          end
        end)

      Storage.write_json(Config.investigations_file(), updated)
    end
  end

  @spec freeze_investigation(String.t()) :: :ok | {:error, term()}
  def freeze_investigation(id) do
    with {:ok, investigations} <- list_investigations() do
      updated =
        Enum.map(investigations, fn inv ->
          if Map.get(inv, "id") == id do
            inv
            |> Map.put("status", "frozen")
            |> Map.put("updated_at", iso_now())
          else
            inv
          end
        end)

      Storage.write_json(Config.investigations_file(), updated)
    end
  end

  @spec unfreeze_investigation(String.t()) :: :ok | {:error, term()}
  def unfreeze_investigation(id) do
    with {:ok, investigations} <- list_investigations() do
      updated =
        Enum.map(investigations, fn inv ->
          if Map.get(inv, "id") == id do
            inv
            |> Map.put("status", "active")
            |> Map.put("updated_at", iso_now())
          else
            inv
          end
        end)

      Storage.write_json(Config.investigations_file(), updated)
    end
  end

  @spec graduate_investigation(String.t()) :: :ok | {:error, term()}
  def graduate_investigation(id) do
    with {:ok, investigations} <- list_investigations() do
      updated =
        Enum.map(investigations, fn inv ->
          if Map.get(inv, "id") == id do
            inv
            |> Map.put("status", "graduated")
            |> Map.put("updated_at", iso_now())
          else
            inv
          end
        end)

      Storage.write_json(Config.investigations_file(), updated)
    end
  end

  @spec link_experiment_to_investigation(String.t(), String.t()) :: :ok | {:error, term()}
  def link_experiment_to_investigation(exp_id, inv_id) do
    with {:ok, investigations} <- list_investigations() do
      updated =
        Enum.map(investigations, fn inv ->
          if Map.get(inv, "id") == inv_id do
            exps = inv |> Map.get("experiments", []) |> Enum.uniq()
            inv
            |> Map.put("experiments", Enum.uniq(exps ++ [exp_id]))
            |> Map.put("updated_at", iso_now())
          else
            inv
          end
        end)

      Storage.write_json(Config.investigations_file(), updated)
    end
  end

  @spec save_session_data(String.t(), String.t()) :: :ok | {:error, term()}
  def save_session_data(step, content) when is_binary(step) and is_binary(content) do
    path = Path.join(Config.session_data_dir(), "#{step}.md")

    with :ok <- File.mkdir_p(Config.session_data_dir()),
         :ok <- File.write(path, content) do
      :ok
    end
  end

  @spec read_session_data(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def read_session_data(step) when is_binary(step) do
    path = Path.join(Config.session_data_dir(), "#{step}.md")

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  @spec list_session_data() :: [{String.t(), String.t()}]
  def list_session_data do
    dir = Config.session_data_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(fn file ->
          step = String.replace_suffix(file, ".md", "")
          content = File.read!(Path.join(dir, file))
          {step, content}
        end)

      {:error, _} ->
        []
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
