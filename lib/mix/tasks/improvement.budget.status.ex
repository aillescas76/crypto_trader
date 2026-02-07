defmodule Mix.Tasks.Improvement.Budget.Status do
  use Mix.Task

  alias CriptoTrader.Improvement.Budget

  @shortdoc "Show improvement execution budget status"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Budget.snapshot() do
      {:ok, budget} ->
        Mix.shell().info("window_start=#{budget["window_start"]}")
        Mix.shell().info("window_end=#{budget["window_end"]}")
        Mix.shell().info("limit_seconds=#{budget["limit_seconds"]}")
        Mix.shell().info("consumed_seconds=#{budget["consumed_seconds"]}")
        Mix.shell().info("remaining_seconds=#{budget["remaining_seconds"]}")

      {:error, reason} ->
        Mix.raise("Failed to read budget status: #{inspect(reason)}")
    end
  end
end
