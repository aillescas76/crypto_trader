defmodule CriptoTrader.Improvement.TradingState do
  @moduledoc """
  Manages trading loop state persistence.

  Tracks iteration count, current strategy, backtest metrics,
  baseline performance, and Codex invocation status.
  """

  alias CriptoTrader.Improvement.{Config, Storage}

  @default_state %{
    "iteration" => 0,
    "strategy" => "CriptoTrader.Strategy.Alternating",
    "last_backtest_summary" => %{},
    "baseline_metrics" => %{},
    "last_codex_invoked" => false,
    "updated_at" => nil
  }

  @doc """
  Returns the path to the trading state file.
  """
  def path do
    base = Config.storage_dir()
    Path.join([base, "trading", "state.json"])
  end

  @doc """
  Reads the current trading state.

  Returns default state if file doesn't exist or cannot be read.
  """
  def read do
    case Storage.read_json(path(), @default_state) do
      {:ok, state} when is_map(state) -> state
      _ -> @default_state
    end
  end

  @doc """
  Writes trading state to disk.
  """
  def write(state) do
    Storage.write_json(path(), state)
  end

  @doc """
  Resets trading state to default values.
  """
  def reset do
    write(@default_state)
  end

  @doc """
  Updates specific fields in the state.

  ## Examples

      iex> TradingState.update(%{"iteration" => 5})
      :ok

  """
  def update(changes) when is_map(changes) do
    state = read()
    new_state = Map.merge(state, changes)
    write(new_state)
  end

  @doc """
  Increments the iteration counter.
  """
  def increment_iteration do
    state = read()
    new_iteration = (state["iteration"] || 0) + 1
    update(%{"iteration" => new_iteration, "updated_at" => iso8601_now()})
  end

  @doc """
  Sets the baseline metrics from the current backtest summary.

  This is typically called after the first successful backtest
  to establish a performance baseline for comparison.
  """
  def set_baseline_from_current do
    state = read()
    summary = state["last_backtest_summary"] || %{}

    if map_size(summary) > 0 do
      update(%{"baseline_metrics" => summary})
    else
      {:error, "No backtest summary available to set as baseline"}
    end
  end

  defp iso8601_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
