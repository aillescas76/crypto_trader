defmodule CriptoTrader.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Finch, name: CriptoTrader.Finch},
        CriptoTrader.Paper.Orders
      ] ++ web_children()

    opts = [strategy: :one_for_one, name: CriptoTrader.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp web_children do
    if Mix.env() == :test do
      []
    else
      [
        {Phoenix.PubSub, name: CriptoTrader.PubSub},
        CriptoTraderWeb.Endpoint,
        {Task.Supervisor, name: CriptoTrader.Experiments.TaskSupervisor},
        {CriptoTrader.Experiments.Engine,
         poll_interval_ms: 30_000, pubsub_server: CriptoTrader.PubSub}
      ]
    end
  end
end
