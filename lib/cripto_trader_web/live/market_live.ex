defmodule CriptoTraderWeb.MarketLive do
  use Phoenix.LiveView

  alias CriptoTrader.LiveSim.Manager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CriptoTrader.PubSub, "live_sim:updates")
    end

    snap = Manager.snapshot()
    symbols = all_symbols(snap.strategies)

    db_candles = load_db_candles(symbols)
    candles_by_symbol = merge_all(db_candles, Map.get(snap, :candles, %{}))

    {:ok,
     assign(socket,
       symbols: symbols,
       last_prices: snap.last_prices,
       candles_by_symbol: candles_by_symbol,
       strategy_count: length(snap.strategies)
     )}
  end

  @impl true
  def handle_info({:update, snap}, socket) do
    symbols = all_symbols(snap.strategies)

    candles_by_symbol =
      merge_all(socket.assigns.candles_by_symbol, Map.get(snap, :candles, %{}))

    socket =
      Enum.reduce(candles_by_symbol, socket, fn {symbol, candles}, acc ->
        push_event(acc, "candle_update:#{symbol}", %{candles: candles, markers: []})
      end)

    {:noreply,
     assign(socket,
       symbols: symbols,
       last_prices: snap.last_prices,
       candles_by_symbol: candles_by_symbol,
       strategy_count: length(snap.strategies)
     )}
  end

  @impl true
  def handle_event("chart_ready", %{"symbol" => symbol}, socket) do
    candles = Map.get(socket.assigns.candles_by_symbol, symbol, [])
    {:noreply, push_event(socket, "candle_update:#{symbol}", %{candles: candles, markers: []})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Market Feed</h1>
    <p style="color:#8b949e; margin-top:-8px; margin-bottom:20px">
      Live 15m Binance candles for active strategy pairs.
      <span style="color:#c9d1d9"><%= @strategy_count %> <%= if @strategy_count == 1, do: "strategy", else: "strategies" %></span>
      watching
      <span style="color:#c9d1d9"><%= length(@symbols) %> <%= if length(@symbols) == 1, do: "pair", else: "pairs" %></span>.
    </p>

    <%= if @symbols == [] do %>
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:40px; text-align:center; color:#8b949e">
        No active strategies. Add a strategy on the
        <a href="/live-sim" style="color:#58a6ff">Live Sim</a> page to see market data here.
      </div>
    <% else %>
      <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(520px,1fr)); gap:20px">
        <%= for symbol <- @symbols do %>
          <% price = Map.get(@last_prices, symbol) %>
          <% candle = last_candle(@candles_by_symbol, symbol) %>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:16px">

            <%!-- Symbol header --%>
            <div style="display:flex; align-items:baseline; justify-content:space-between; margin-bottom:14px">
              <div>
                <span style="color:#f0f6fc; font-size:1.3em; font-weight:bold"><%= base_currency(symbol) %></span>
                <span style="color:#8b949e; font-size:0.82em; margin-left:6px"><%= symbol %></span>
              </div>
              <%= if price do %>
                <span style="color:#f0f6fc; font-size:1.2em; font-weight:bold; font-family:monospace">
                  <%= format_price(price) %>
                </span>
              <% else %>
                <span style="color:#8b949e; font-size:0.88em">awaiting candle…</span>
              <% end %>
            </div>

            <%!-- Last candle OHLC --%>
            <%= if candle do %>
              <div style="display:grid; grid-template-columns:repeat(4,1fr); gap:6px; margin-bottom:14px">
                <div style="background:#0d1117; border-radius:4px; padding:6px 8px">
                  <div style="color:#8b949e; font-size:0.68em; margin-bottom:2px">OPEN</div>
                  <div style="color:#c9d1d9; font-size:0.82em; font-family:monospace"><%= format_price(candle.open) %></div>
                </div>
                <div style="background:#0d1117; border-radius:4px; padding:6px 8px">
                  <div style="color:#8b949e; font-size:0.68em; margin-bottom:2px">HIGH</div>
                  <div style="color:#3fb950; font-size:0.82em; font-family:monospace"><%= format_price(candle.high) %></div>
                </div>
                <div style="background:#0d1117; border-radius:4px; padding:6px 8px">
                  <div style="color:#8b949e; font-size:0.68em; margin-bottom:2px">LOW</div>
                  <div style="color:#f85149; font-size:0.82em; font-family:monospace"><%= format_price(candle.low) %></div>
                </div>
                <div style="background:#0d1117; border-radius:4px; padding:6px 8px">
                  <div style="color:#8b949e; font-size:0.68em; margin-bottom:2px">CLOSE</div>
                  <% close_color = if candle.close >= candle.open, do: "#3fb950", else: "#f85149" %>
                  <div style={"color:#{close_color}; font-size:0.82em; font-family:monospace; font-weight:bold"}><%= format_price(candle.close) %></div>
                </div>
              </div>
            <% end %>

            <%!-- Candle chart --%>
            <div
              id={"market-chart-#{symbol}"}
              phx-hook="CandleChart"
              data-symbol={symbol}
              style="height:320px; background:#0d1117; border-radius:6px; overflow:hidden"
            ></div>

          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp all_symbols(strategies) do
    strategies
    |> Enum.flat_map(& &1.symbols)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp last_candle(candles_by_symbol, symbol) do
    case Map.get(candles_by_symbol, symbol, []) do
      [_ | _] = list -> List.last(list)
      _ -> nil
    end
  end

  defp base_currency(sym) do
    Enum.find_value(["USDC", "EUR", "USDT", "BTC", "ETH"], sym, fn quote ->
      if String.ends_with?(sym, quote), do: String.replace_suffix(sym, quote, ""), else: nil
    end)
  end

  defp format_price(v) when is_number(v) do
    rounded = Float.round(v * 1.0, 2)
    :erlang.float_to_binary(rounded, decimals: 2)
  end

  defp format_price(_), do: "—"

  defp load_db_candles(symbols) do
    Map.new(symbols, fn sym ->
      candles =
        CriptoTrader.CandleDB.recent(sym, "15m", days: 3)
        |> Enum.map(&candle_to_chart/1)

      {sym, candles}
    end)
  end

  defp candle_to_chart(%{open_time: t, open: o, high: h, low: l, close: c}) do
    %{
      time: div(t, 1000),
      open: Decimal.to_float(o),
      high: Decimal.to_float(h),
      low: Decimal.to_float(l),
      close: Decimal.to_float(c)
    }
  end

  defp merge_all(base, incoming) do
    all_keys = Map.keys(base) ++ Map.keys(incoming) |> Enum.uniq()

    Map.new(all_keys, fn sym ->
      merged =
        (Map.get(base, sym, []) ++ Map.get(incoming, sym, []))
        |> Enum.uniq_by(& &1.time)
        |> Enum.sort_by(& &1.time)

      {sym, merged}
    end)
  end
end
