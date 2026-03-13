defmodule CriptoTraderWeb.LiveSimLive do
  use Phoenix.LiveView

  # {dropdown_label, module_string, default_params_map}
  @module_registry [
    {"IntradayMomentum", "CriptoTrader.Strategy.IntradayMomentum",
     %{quote_per_trade: 100.0, stop_loss_pct: 0.02, trail_pct: 0.003}},
    {"BbRsiReversion", "CriptoTrader.Strategy.BbRsiReversion",
     %{
       bb_period: 20,
       bb_mult: 2.0,
       rsi_period: 14,
       rsi_oversold: 30.0,
       rsi_overbought: 70.0,
       quote_per_trade: 100.0,
       stop_loss_mult: 3.0
     }},
    {"RegimeDetector", "CriptoTrader.Strategy.RegimeDetector",
     %{adx_period: 14, trend_threshold: 25.0, range_threshold: 20.0}},
    {"LateralRange", "CriptoTrader.Strategy.LateralRange",
     %{
       lookback: 30,
       max_range_pct: 0.02,
       quote_per_trade: 100.0,
       stop_loss_pct: 0.015,
       entry_buffer_pct: 0.0025,
       exit_buffer_pct: 0.0025,
       breakout_pct: 0.005
     }},
    {"AltcoinCycle", "CriptoTrader.Strategy.AltcoinCycle",
     %{trail_pct: 0.25, alt_trail_pct: 0.35, quote_per_trade: 1000.0, btc_symbol: "BTCUSDC"}},
    {"BuyAndHold", "CriptoTrader.Strategy.BuyAndHold",
     %{quote_per_trade: 100.0}},
    {"[Exp] PostShockReversal", "CriptoTrader.Strategy.Experiment.PostShockReversal20260313",
     %{drop_atr_multiple: 2.0, atr_period: 14, hold_candles: 8, quote_per_trade: 1000.0}},
    {"[Exp] DailyMaRegime", "CriptoTrader.Strategy.Experiment.DailyMaRegime20260313",
     %{quote_per_trade: 1500.0}}
  ]

  @default_params_json "{}"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CriptoTrader.PubSub, "live_sim:updates")
    end

    snap = CriptoTrader.LiveSim.Manager.snapshot()

    {:ok,
     assign(socket,
       strategies: snap.strategies,
       last_prices: snap.last_prices,
       form: blank_form(),
       add_error: nil,
       module_registry: @module_registry
     )}
  end

  @impl true
  def handle_info({:update, snap}, socket) do
    {:noreply, assign(socket, strategies: snap.strategies, last_prices: snap.last_prices)}
  end

  @impl true
  def handle_event("update_form", %{"strategy" => params}, socket) do
    current_module = socket.assigns.form["module"]
    new_module = Map.get(params, "module", current_module)

    # Auto-fill params when module selection changes
    updated_params =
      if new_module != current_module and new_module != "" do
        default_json = defaults_json_for(new_module)
        Map.put(params, "params", default_json)
      else
        params
      end

    {:noreply, assign(socket, form: Map.merge(socket.assigns.form, updated_params))}
  end

  def handle_event("add_strategy", %{"strategy" => params}, socket) do
    case CriptoTrader.LiveSim.Manager.add_strategy(params) do
      {:ok, _id} ->
        {:noreply, assign(socket, form: blank_form(), add_error: nil)}

      {:error, :bad_module} ->
        {:noreply,
         assign(socket,
           add_error: "Unknown module — make sure it's compiled and implements signal/2"
         )}
    end
  end

  def handle_event("remove_strategy", %{"id" => id}, socket) do
    CriptoTrader.LiveSim.Manager.remove_strategy(id)
    {:noreply, socket}
  end

  def handle_event("reset_strategy", %{"id" => id}, socket) do
    CriptoTrader.LiveSim.Manager.reset_strategy(id)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Live Strategy Simulation</h1>
    <p style="color:#8b949e; margin-top:-8px; margin-bottom:20px">
      Paper-trading on live 15m Binance candles. Orders filled via volume simulation.
    </p>

    <%= if @add_error do %>
      <div style="background:#3d1a1a; border:1px solid #f85149; border-radius:6px; padding:10px 14px; color:#f85149; margin-bottom:16px; font-size:0.88em"><%= @add_error %></div>
    <% end %>

    <%!-- Live prices bar --%>
    <%= if map_size(@last_prices) > 0 do %>
      <div style="display:flex; gap:20px; flex-wrap:wrap; background:#161b22; border:1px solid #30363d; border-radius:6px; padding:10px 16px; margin-bottom:20px">
        <%= for {symbol, price} <- Enum.sort(@last_prices) do %>
          <span style="font-size:0.9em">
            <span style="color:#8b949e"><%= symbol %></span>
            <span style="color:#f0f6fc; font-weight:bold; margin-left:6px"><%= format_price(price) %></span>
          </span>
        <% end %>
      </div>
    <% end %>

    <%!-- Strategy cards --%>
    <%= if @strategies == [] do %>
      <p style="color:#8b949e">No strategies yet. Add one below.</p>
    <% else %>
      <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(520px,1fr)); gap:16px; margin-bottom:32px">
        <%= for strat <- @strategies do %>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:16px">

            <%!-- Card header --%>
            <div style="display:flex; align-items:flex-start; justify-content:space-between; margin-bottom:12px">
              <div>
                <div style="font-weight:bold; color:#f0f6fc; font-size:1em"><%= strat.label %></div>
                <div style="color:#8b949e; font-size:0.78em; margin-top:2px"><%= strat.module %></div>
                <div style="color:#8b949e; font-size:0.78em"><%= Enum.join(strat.symbols, ", ") %></div>
              </div>
              <div style="display:flex; gap:6px; flex-shrink:0">
                <button
                  phx-click="reset_strategy"
                  phx-value-id={strat.id}
                  style="background:#21262d; color:#e3b341; border:1px solid #e3b341; border-radius:4px; padding:4px 10px; font-size:0.78em; cursor:pointer"
                >Reset</button>
                <button
                  phx-click="remove_strategy"
                  phx-value-id={strat.id}
                  style="background:#21262d; color:#f85149; border:1px solid #f85149; border-radius:4px; padding:4px 10px; font-size:0.78em; cursor:pointer"
                >Remove</button>
              </div>
            </div>

            <%!-- Stats row --%>
            <div style="display:grid; grid-template-columns:repeat(3,1fr); gap:8px; margin-bottom:14px">
              <div style="background:#0d1117; border-radius:4px; padding:8px 10px">
                <div style="color:#8b949e; font-size:0.72em; margin-bottom:2px">EQUITY</div>
                <div style={pnl_style(strat.equity_return_pct)}>
                  <%= format_price(strat.equity) %> (<%= format_pct(strat.equity_return_pct) %>)
                </div>
              </div>
              <div style="background:#0d1117; border-radius:4px; padding:8px 10px">
                <div style="color:#8b949e; font-size:0.72em; margin-bottom:2px">REALIZED P&L</div>
                <div style={pnl_style(strat.realized_pnl)}><%= format_pnl(strat.realized_pnl) %></div>
              </div>
              <div style="background:#0d1117; border-radius:4px; padding:8px 10px">
                <div style="color:#8b949e; font-size:0.72em; margin-bottom:2px">UNREALIZED P&L</div>
                <div style={pnl_style(strat.unrealized_pnl)}><%= format_pnl(strat.unrealized_pnl) %></div>
              </div>
            </div>
            <div style="color:#8b949e; font-size:0.78em; margin-bottom:12px">
              Cash: <%= format_price(strat.balance) %> / Initial: <%= format_price(strat.initial_balance) %>
            </div>

            <%!-- Open positions --%>
            <%= if map_size(strat.positions) > 0 do %>
              <div style="margin-bottom:12px">
                <div style="color:#8b949e; font-size:0.75em; font-weight:bold; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.05em">Open Positions</div>
                <%= for {symbol, pos} <- strat.positions do %>
                  <% last_price = Map.get(@last_prices, symbol, pos.entry_price) %>
                  <% unr = (last_price - pos.entry_price) * pos.qty %>
                  <div style="display:flex; justify-content:space-between; font-size:0.82em; padding:3px 0; border-bottom:1px solid #21262d">
                    <span style="color:#f0f6fc"><%= symbol %></span>
                    <span style="color:#8b949e"><%= Float.round(pos.qty * 1.0, 6) %> @ <%= format_price(pos.entry_price) %></span>
                    <span style={pnl_style(unr)}><%= format_pnl(unr) %></span>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- Pending orders --%>
            <%= if strat.pending_orders != [] do %>
              <div style="margin-bottom:12px">
                <div style="color:#8b949e; font-size:0.75em; font-weight:bold; margin-bottom:4px; text-transform:uppercase; letter-spacing:0.05em">
                  Pending Orders (<%= length(strat.pending_orders) %>)
                </div>
                <%= for order <- Enum.take(strat.pending_orders, 5) do %>
                  <div style="font-size:0.78em; font-family:monospace; color:#d29922; padding:2px 0">
                    <%= Map.get(order, :side, "?") %> <%= Map.get(order, :symbol, "?") %>
                    <%= if Map.get(order, :type) == "LIMIT", do: "@ #{format_price(Map.get(order, :price, 0))}" %>
                    qty=<%= Float.round(parse_float_display(Map.get(order, :quantity)), 6) %>
                  </div>
                <% end %>
                <%= if length(strat.pending_orders) > 5 do %>
                  <div style="font-size:0.75em; color:#8b949e">+<%= length(strat.pending_orders) - 5 %> more</div>
                <% end %>
              </div>
            <% end %>

            <%!-- Recent fills --%>
            <%= if strat.filled_orders != [] do %>
              <div>
                <div style="color:#8b949e; font-size:0.75em; font-weight:bold; margin-bottom:4px; text-transform:uppercase; letter-spacing:0.05em">Recent Fills</div>
                <%= for fill <- Enum.take(strat.filled_orders, 5) do %>
                  <div style="font-size:0.78em; font-family:monospace; color:#8b949e; padding:2px 0">
                    <span style={if Map.get(fill, :side) == "BUY", do: "color:#3fb950", else: "color:#f85149"}>
                      <%= Map.get(fill, :side, "?") %>
                    </span>
                    <%= Map.get(fill, :symbol, "?") %> @ <%= format_price(Map.get(fill, :fill_price, 0)) %>
                    qty=<%= Float.round(parse_float_display(Map.get(fill, :quantity)), 6) %>
                  </div>
                <% end %>
              </div>
            <% end %>

          </div>
        <% end %>
      </div>
    <% end %>

    <%!-- Add strategy form --%>
    <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:20px; max-width:640px">
      <h2 style="font-size:1em; margin:0 0 16px; color:#f0f6fc">Add Strategy</h2>
      <form phx-submit="add_strategy" phx-change="update_form">

        <div style="display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-bottom:12px">
          <div>
            <label style="color:#8b949e; font-size:0.8em; display:block; margin-bottom:4px">Label</label>
            <input
              type="text"
              name="strategy[label]"
              value={@form["label"]}
              placeholder="My Strategy"
              style="width:100%; background:#0d1117; color:#c9d1d9; border:1px solid #30363d; padding:6px 10px; border-radius:4px; font-family:monospace; font-size:0.88em"
            />
          </div>
          <div>
            <label style="color:#8b949e; font-size:0.8em; display:block; margin-bottom:4px">Initial Balance (USDC)</label>
            <input
              type="text"
              name="strategy[initial_balance]"
              value={@form["initial_balance"]}
              placeholder="1000"
              style="width:100%; background:#0d1117; color:#c9d1d9; border:1px solid #30363d; padding:6px 10px; border-radius:4px; font-family:monospace; font-size:0.88em"
            />
          </div>
        </div>

        <div style="margin-bottom:12px">
          <label style="color:#8b949e; font-size:0.8em; display:block; margin-bottom:4px">Strategy Module</label>
          <select
            name="strategy[module]"
            style="width:100%; background:#0d1117; color:#c9d1d9; border:1px solid #30363d; padding:7px 10px; border-radius:4px; font-family:monospace; font-size:0.88em; cursor:pointer"
          >
            <option value="">— select a strategy —</option>
            <%= for {label, mod_str, _defaults} <- @module_registry do %>
              <option value={mod_str} selected={@form["module"] == mod_str}>
                <%= label %> — <%= mod_str %>
              </option>
            <% end %>
          </select>
        </div>

        <div style="margin-bottom:12px">
          <label style="color:#8b949e; font-size:0.8em; display:block; margin-bottom:4px">Symbols (comma-separated)</label>
          <input
            type="text"
            name="strategy[symbols]"
            value={@form["symbols"]}
            placeholder="BTCUSDC,ETHUSDC,SOLUSDC"
            style="width:100%; background:#0d1117; color:#c9d1d9; border:1px solid #30363d; padding:6px 10px; border-radius:4px; font-family:monospace; font-size:0.88em"
          />
        </div>

        <div style="margin-bottom:16px">
          <label style="color:#8b949e; font-size:0.8em; display:block; margin-bottom:4px">
            Params (JSON) — auto-filled from module defaults, edit as needed
          </label>
          <textarea
            name="strategy[params]"
            rows="5"
            style="width:100%; background:#0d1117; color:#c9d1d9; border:1px solid #30363d; padding:8px 10px; border-radius:4px; font-family:monospace; font-size:0.82em; resize:vertical"
          ><%= @form["params"] %></textarea>
        </div>

        <button
          type="submit"
          style="background:#238636; color:#fff; border:none; padding:8px 20px; border-radius:4px; cursor:pointer; font-family:monospace; font-size:0.9em"
        >
          Add Strategy
        </button>
      </form>
    </div>
    """
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp blank_form do
    %{
      "label" => "",
      "module" => "",
      "symbols" => "",
      "initial_balance" => "1000",
      "params" => @default_params_json
    }
  end

  defp defaults_json_for(module_str) do
    case Enum.find(@module_registry, fn {_label, mod, _defaults} -> mod == module_str end) do
      {_label, _mod, defaults} ->
        # Convert atom keys to string keys for JSON
        string_keyed = Map.new(defaults, fn {k, v} -> {Atom.to_string(k), v} end)
        Jason.encode!(string_keyed, pretty: true)

      nil ->
        @default_params_json
    end
  end

  # ── Formatters ────────────────────────────────────────────────────────────────

  defp format_price(v) when is_number(v) do
    rounded = Float.round(v * 1.0, 2)
    :erlang.float_to_binary(rounded, decimals: 2)
  end

  defp format_price(_), do: "0.00"

  defp format_pnl(v) when is_number(v) do
    prefix = if v >= 0, do: "+", else: ""
    "#{prefix}#{format_price(v)}"
  end

  defp format_pnl(_), do: "-"

  defp format_pct(v) when is_number(v) do
    prefix = if v >= 0, do: "+", else: ""
    "#{prefix}#{Float.round(v * 1.0, 2)}%"
  end

  defp format_pct(_), do: "-"

  defp pnl_style(v) when is_number(v) and v >= 0, do: "color:#3fb950; font-size:0.88em; font-weight:bold"
  defp pnl_style(v) when is_number(v) and v < 0, do: "color:#f85149; font-size:0.88em; font-weight:bold"
  defp pnl_style(_), do: "color:#8b949e; font-size:0.88em"

  defp parse_float_display(v) when is_float(v), do: v
  defp parse_float_display(v) when is_integer(v), do: v * 1.0

  defp parse_float_display(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float_display(_), do: 0.0
end
