defmodule CriptoTrader.Improvement.LoopState do
  @moduledoc false

  alias CriptoTrader.Improvement.{Config, Storage}

  @default_state %{
    "run_id" => nil,
    "iteration" => 0,
    "status" => "idle",
    "last_stop_reason" => nil,
    "last_updated_at" => nil,
    "last_codex_result" => %{},
    "last_loop_result" => %{}
  }

  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    with {:ok, state} <- Storage.read_json(Config.loop_state_file(), @default_state) do
      {:ok, Map.merge(@default_state, state)}
    end
  end

  @spec save(map()) :: :ok | {:error, term()}
  def save(state) when is_map(state) do
    with {:ok, existing} <- Storage.read_json(Config.loop_state_file(), @default_state) do
      merged =
        @default_state
        |> Map.merge(existing)
        |> Map.merge(state)
        |> Map.put("last_updated_at", now_iso())

      Storage.write_json(Config.loop_state_file(), merged)
    end
  end

  @spec begin_run(String.t()) :: :ok | {:error, term()}
  def begin_run(run_id) do
    save(%{
      "run_id" => run_id,
      "iteration" => 0,
      "status" => "running",
      "last_stop_reason" => nil
    })
  end

  @spec update_iteration(non_neg_integer(), map(), map()) :: :ok | {:error, term()}
  def update_iteration(iteration, codex_result, loop_result) do
    save(%{
      "iteration" => iteration,
      "status" => "running",
      "last_codex_result" => codex_result,
      "last_loop_result" => loop_result
    })
  end

  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(reason) do
    with {:ok, state} <- load() do
      save(%{
        "run_id" => state["run_id"],
        "iteration" => state["iteration"],
        "status" => "stopped",
        "last_stop_reason" => reason,
        "last_codex_result" => state["last_codex_result"],
        "last_loop_result" => state["last_loop_result"]
      })
    end
  end

  defp now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
