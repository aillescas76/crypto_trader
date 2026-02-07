defmodule CriptoTrader.Paper.Orders do
  @moduledoc false

  use GenServer

  @name __MODULE__

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  @spec submit(map() | keyword()) :: {:ok, map()}
  def submit(params) do
    GenServer.call(@name, {:submit, params})
  end

  @spec list() :: list(map())
  def list do
    GenServer.call(@name, :list)
  end

  @impl true
  def init(_opts) do
    {:ok, %{next_id: 1, orders: []}}
  end

  @impl true
  def handle_call({:submit, params}, _from, state) do
    order = build_order(state.next_id, params)
    new_state = %{state | next_id: state.next_id + 1, orders: [order | state.orders]}
    {:reply, {:ok, order}, new_state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.reverse(state.orders), state}
  end

  defp build_order(id, params) do
    params_map = Enum.into(params, %{})

    %{
      order_id: id,
      symbol: Map.get(params_map, :symbol) || Map.get(params_map, "symbol"),
      side: Map.get(params_map, :side) || Map.get(params_map, "side"),
      type: Map.get(params_map, :type) || Map.get(params_map, "type"),
      status: "FILLED",
      executed_qty: Map.get(params_map, :quantity) || Map.get(params_map, "quantity"),
      quote_order_qty:
        Map.get(params_map, :quote_order_qty) || Map.get(params_map, "quoteOrderQty"),
      transact_time: System.system_time(:millisecond)
    }
  end
end
