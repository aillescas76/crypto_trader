defmodule CriptoTrader.LiveSim.BinanceStream do
  @moduledoc """
  GenServer that manages a WebSockex connection to the Binance multi-stream kline feed.
  Forwards closed 15m candles to LiveSim.Manager as {:candle, event} casts.
  """

  use GenServer
  require Logger

  @base_url "wss://stream.binance.com:9443/stream?streams="

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Signal the stream to reconnect with a new symbol list."
  def update_symbols(symbols) when is_list(symbols) do
    GenServer.cast(__MODULE__, {:update_symbols, symbols})
  end

  @impl true
  def init(_) do
    {:ok, %{ws_pid: nil, symbols: []}, {:continue, :initial_connect}}
  end

  @impl true
  def handle_continue(:initial_connect, state) do
    symbols =
      try do
        GenServer.call(CriptoTrader.LiveSim.Manager, :get_symbols, 5_000)
      catch
        _, _ -> []
      end

    {:noreply, do_connect(%{state | symbols: symbols})}
  end

  @impl true
  def handle_cast({:update_symbols, symbols}, state) do
    if state.ws_pid && Process.alive?(state.ws_pid) do
      Process.exit(state.ws_pid, :kill)
    end

    Process.send_after(self(), :reconnect, 300)
    {:noreply, %{state | symbols: symbols, ws_pid: nil}}
  end

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, do_connect(state)}

  def handle_info({:DOWN, _, :process, pid, reason}, %{ws_pid: pid} = state) do
    if reason not in [:normal, :shutdown] do
      Logger.warning("BinanceStream WS exited (#{inspect(reason)}), reconnecting in 5s")
    end

    Process.send_after(self(), :reconnect, 5_000)
    {:noreply, %{state | ws_pid: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # -- helpers --

  defp do_connect(%{symbols: []} = state), do: state

  defp do_connect(%{symbols: symbols} = state) do
    streams = Enum.map_join(symbols, "/", &"#{String.downcase(&1)}@kline_15m")
    url = @base_url <> streams

    case WebSockex.start_link(url, CriptoTrader.LiveSim.BinanceStream.Client, %{}) do
      {:ok, pid} ->
        Process.monitor(pid)
        Logger.info("BinanceStream connected: #{length(symbols)} symbols")
        %{state | ws_pid: pid}

      {:error, reason} ->
        Logger.error("BinanceStream connect failed: #{inspect(reason)}, retry in 10s")
        Process.send_after(self(), :reconnect, 10_000)
        state
    end
  end
end

defmodule CriptoTrader.LiveSim.BinanceStream.Client do
  @moduledoc false
  use WebSockex
  require Logger

  @impl true
  def handle_frame({:text, msg}, state) do
    with {:ok, %{"data" => %{"k" => k}}} <- Jason.decode(msg),
         true <- k["x"] == true do
      event = %{
        symbol: k["s"],
        open_time: k["t"],
        candle: %{
          open: k["o"],
          high: k["h"],
          low: k["l"],
          close: k["c"],
          volume: k["v"],
          quote_volume: k["q"],
          taker_buy_quote_volume: k["Q"]
        }
      }

      GenServer.cast(CriptoTrader.LiveSim.Manager, {:candle, event})
    end

    {:ok, state}
  end

  def handle_frame(_, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.debug("BinanceStream.Client disconnected: #{inspect(reason)}")
    # Let BinanceStream GenServer handle reconnection via :DOWN
    {:ok, state}
  end
end
