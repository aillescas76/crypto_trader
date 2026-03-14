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
    {"SharpeRankRotation", "CriptoTrader.Strategy.SharpeRankRotation",
     %{
       quote_per_position: 5000.0,
       hold_count: 2,
       ma_period_weeks: 20,
       momentum_lookback: 4,
       rebalance_weeks: 3,
       vol_floor: 0.02
     }},
    {"[Exp] AsymGate Rotation", "CriptoTrader.Strategy.Experiment.SharpeRankAsymmetricGate20260314",
     %{quote_per_position: 5000.0}},
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
       candles_by_symbol: Map.get(snap, :candles, %{}),
       form: blank_form(),
       add_error: nil,
       module_registry: @module_registry
     )}
  end

  @impl true
  def handle_info({:update, snap}, socket) do
    {:noreply,
     assign(socket,
       strategies: snap.strategies,
       last_prices: snap.last_prices,
       candles_by_symbol: Map.get(snap, :candles, %{})
     )}
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

    symbols_error = validate_symbols(Map.get(updated_params, "symbols", socket.assigns.form["symbols"]))
    merged = Map.merge(socket.assigns.form, updated_params) |> Map.put("symbols_error", symbols_error)
    {:noreply, assign(socket, form: merged)}
  end

  def handle_event("add_strategy", %{"strategy" => params}, socket) do
    case validate_symbols(Map.get(params, "symbols", "")) do
      nil ->
        case CriptoTrader.LiveSim.Manager.add_strategy(params) do
          {:ok, _id} ->
            {:noreply, assign(socket, form: blank_form(), add_error: nil)}

          {:error, :bad_module} ->
            {:noreply,
             assign(socket,
               add_error: "Unknown module — make sure it's compiled and implements signal/2"
             )}
        end

      error ->
        {:noreply,
         assign(socket, form: Map.put(socket.assigns.form, "symbols_error", error))}
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
      <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(600px,1fr)); gap:20px; margin-bottom:32px">
        <%= for strat <- @strategies do %>
          <% deployed = deployed_pct(strat.balance, strat.initial_balance) %>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:20px">

            <%!-- Header: label + symbols + buttons --%>
            <div style="display:flex; align-items:flex-start; justify-content:space-between; margin-bottom:14px">
              <div style="min-width:0">
                <div style="font-weight:bold; color:#f0f6fc; font-size:1.05em; margin-bottom:2px"><%= strat.label %></div>
                <div style="color:#8b949e; font-size:0.75em; margin-bottom:6px"><%= strat.module %></div>
                <div style="display:flex; flex-wrap:wrap; gap:5px">
                  <%= for sym <- strat.symbols do %>
                    <% sig = Map.get(strat.last_signals, sym, 0) %>
                    <% has_pos = Map.has_key?(strat.positions, sym) %>
                    <% border_color = cond do
                         has_pos -> "#3fb950"
                         sig > 0  -> "#388bfd"
                         true     -> "#30363d"
                       end %>
                    <span style={"display:inline-flex; flex-direction:column; align-items:flex-start; background:#21262d; border:1px solid #{border_color}; border-radius:4px; padding:3px 8px; gap:1px"}>
                      <span style="display:flex; align-items:center; gap:5px">
                        <span style="color:#f0f6fc; font-weight:bold; font-size:0.85em"><%= base_currency(sym) %></span>
                        <%= if has_pos do %>
                          <span style="color:#3fb950; font-size:0.7em">●LONG</span>
                        <% end %>
                        <%= if sig > 0 do %>
                          <span style="color:#388bfd; font-size:0.7em">↑<%= sig %></span>
                        <% end %>
                      </span>
                      <span style="display:flex; align-items:center; gap:6px">
                        <span style="color:#8b949e; font-size:0.7em"><%= sym %></span>
                        <%= if Map.has_key?(@last_prices, sym) do %>
                          <span style="color:#c9d1d9; font-size:0.75em"><%= format_price(Map.get(@last_prices, sym)) %></span>
                        <% end %>
                      </span>
                    </span>
                  <% end %>
                </div>
              </div>
              <div style="display:flex; gap:6px; flex-shrink:0; margin-left:12px">
                <button phx-click="reset_strategy" phx-value-id={strat.id}
                  style="background:#21262d; color:#e3b341; border:1px solid #e3b341; border-radius:4px; padding:4px 10px; font-size:0.78em; cursor:pointer">Reset</button>
                <button phx-click="remove_strategy" phx-value-id={strat.id}
                  style="background:#21262d; color:#f85149; border:1px solid #f85149; border-radius:4px; padding:4px 10px; font-size:0.78em; cursor:pointer">Remove</button>
              </div>
            </div>

            <%!-- Stats: 4 columns --%>
            <div style="display:grid; grid-template-columns:repeat(4,1fr); gap:8px; margin-bottom:10px">
              <div style="background:#0d1117; border-radius:4px; padding:8px 10px">
                <div style="color:#8b949e; font-size:0.7em; margin-bottom:3px">EQUITY</div>
                <div style={pnl_style(strat.equity_return_pct)} class="stat-val"><%= format_price(strat.equity) %></div>
                <div style={pnl_style(strat.equity_return_pct)} class="stat-sub"><%= format_pct(strat.equity_return_pct) %></div>
              </div>
              <div style="background:#0d1117; border-radius:4px; padding:8px 10px">
                <div style="color:#8b949e; font-size:0.7em; margin-bottom:3px">REALIZED P&L</div>
                <div style={pnl_style(strat.realized_pnl)} class="stat-val"><%= format_pnl(strat.realized_pnl) %></div>
              </div>
              <div style="background:#0d1117; border-radius:4px; padding:8px 10px">
                <div style="color:#8b949e; font-size:0.7em; margin-bottom:3px">UNREALIZED P&L</div>
                <div style={pnl_style(strat.unrealized_pnl)} class="stat-val"><%= format_pnl(strat.unrealized_pnl) %></div>
              </div>
              <div style="background:#0d1117; border-radius:4px; padding:8px 10px">
                <div style="color:#8b949e; font-size:0.7em; margin-bottom:3px">TRADES</div>
                <div style="color:#c9d1d9; font-size:0.88em; font-weight:bold" class="stat-val"><%= Map.get(strat, :trade_count, length(strat.filled_orders)) %></div>
              </div>
            </div>

            <%!-- Cash / deployment row --%>
            <div style="margin-bottom:12px">
              <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px; font-size:0.78em">
                <span style="color:#8b949e">Cash <span style="color:#c9d1d9"><%= format_price(strat.balance) %></span> / Initial <span style="color:#c9d1d9"><%= format_price(strat.initial_balance) %></span></span>
                <span style={"color:#{if deployed > 0, do: "#e3b341", else: "#8b949e"}; font-size:0.85em"}><%= Float.round(deployed, 1) %>% deployed</span>
              </div>
              <div style="height:3px; background:#21262d; border-radius:2px; overflow:hidden">
                <div style={"width:#{deployed}%; height:100%; background:#{if deployed > 80, do: "#f85149", else: "#238636"}; transition:width 0.3s"}></div>
              </div>
            </div>

            <%!-- Open positions --%>
            <div style="margin-bottom:12px">
              <div style="color:#8b949e; font-size:0.72em; font-weight:bold; text-transform:uppercase; letter-spacing:0.05em; margin-bottom:5px">
                Positions (<%= map_size(strat.positions) %>)
              </div>
              <%= if map_size(strat.positions) == 0 do %>
                <div style="color:#8b949e; font-size:0.8em; font-style:italic">No open positions</div>
              <% else %>
                <%= for {symbol, pos} <- strat.positions do %>
                  <% last_price = Map.get(@last_prices, symbol, pos.entry_price) %>
                  <% unr = (last_price - pos.entry_price) * pos.qty %>
                  <% pos_value = last_price * pos.qty %>
                  <div style="display:grid; grid-template-columns:1fr 1fr 1fr 1fr; font-size:0.8em; padding:4px 0; border-bottom:1px solid #21262d; gap:4px">
                    <span style="color:#f0f6fc; font-weight:bold"><%= symbol %></span>
                    <span style="color:#8b949e"><%= Float.round(pos.qty * 1.0, 6) %> @ <%= format_price(pos.entry_price) %></span>
                    <span style="color:#c9d1d9">≈<%= format_price(pos_value) %></span>
                    <span style={pnl_style(unr)}><%= format_pnl(unr) %></span>
                  </div>
                <% end %>
              <% end %>
            </div>

            <%!-- Pending orders --%>
            <%= if strat.pending_orders != [] do %>
              <div style="margin-bottom:12px">
                <div style="color:#8b949e; font-size:0.72em; font-weight:bold; text-transform:uppercase; letter-spacing:0.05em; margin-bottom:5px">
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

            <%!-- Fills table --%>
            <div>
              <div style="color:#8b949e; font-size:0.72em; font-weight:bold; text-transform:uppercase; letter-spacing:0.05em; margin-bottom:5px">
                Recent Fills
              </div>
              <%= if strat.filled_orders == [] do %>
                <div style="color:#8b949e; font-size:0.8em; font-style:italic">No fills yet</div>
              <% else %>
                <table style="width:100%; border-collapse:collapse; font-size:0.78em">
                  <thead>
                    <tr>
                      <th style="color:#8b949e; font-weight:normal; text-align:left; padding:2px 6px 4px 0">TIME</th>
                      <th style="color:#8b949e; font-weight:normal; text-align:left; padding:2px 6px 4px 0">SIDE</th>
                      <th style="color:#8b949e; font-weight:normal; text-align:left; padding:2px 6px 4px 0">SYMBOL</th>
                      <th style="color:#8b949e; font-weight:normal; text-align:right; padding:2px 0 4px 0">PRICE</th>
                      <th style="color:#8b949e; font-weight:normal; text-align:right; padding:2px 0 4px 6px">QTY</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for fill <- Enum.take(strat.filled_orders, 10) do %>
                      <% is_buy = Map.get(fill, :side) == "BUY" %>
                      <tr style="border-top:1px solid #21262d">
                        <td style="color:#8b949e; padding:3px 6px 3px 0; font-family:monospace"><%= short_fill_time(Map.get(fill, :filled_at, "")) %></td>
                        <td style={"padding:3px 6px 3px 0; font-weight:bold; #{if is_buy, do: "color:#3fb950", else: "color:#f85149"}"}><%= Map.get(fill, :side, "?") %></td>
                        <td style="color:#c9d1d9; padding:3px 6px 3px 0"><%= Map.get(fill, :symbol, "?") %></td>
                        <td style="color:#f0f6fc; text-align:right; padding:3px 0 3px 0; font-family:monospace"><%= format_price(Map.get(fill, :fill_price, 0)) %></td>
                        <td style="color:#8b949e; text-align:right; padding:3px 0 3px 6px; font-family:monospace"><%= Float.round(parse_float_display(Map.get(fill, :quantity)), 4) %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>

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
            style={"width:100%; background:#0d1117; color:#c9d1d9; border:1px solid #{if @form["symbols_error"], do: "#f85149", else: "#30363d"}; padding:6px 10px; border-radius:4px; font-family:monospace; font-size:0.88em"}
          />
          <%= if @form["symbols_error"] do %>
            <div style="color:#f85149; font-size:0.8em; margin-top:5px; line-height:1.4">
              ⚠ <%= @form["symbols_error"] %>
            </div>
          <% end %>
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
      "symbols_error" => nil,
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

  # ── Validation ────────────────────────────────────────────────────────────────

  defp validate_symbols(raw) when is_binary(raw) do
    symbols =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if symbols == [] do
      "Enter at least one symbol (e.g. BTCUSDC, ETHUSDC)."
    else
      bad = Enum.reject(symbols, &Regex.match?(~r/^[A-Z]{2,20}$/, &1))

      if bad == [] do
        nil
      else
        bad_str = Enum.join(bad, ", ")
        "Invalid: #{bad_str}. Symbols must be uppercase letters only, e.g. BTCUSDC, ETHUSDC, SOLUSDC. No spaces, numbers, or special characters."
      end
    end
  end

  defp validate_symbols(_), do: "Enter at least one symbol (e.g. BTCUSDC, ETHUSDC)."

  # ── Symbol helpers ────────────────────────────────────────────────────────────

  defp base_currency(sym) do
    Enum.find_value(["USDC", "EUR", "USDT", "BTC", "ETH"], sym, fn quote ->
      if String.ends_with?(sym, quote), do: String.replace_suffix(sym, quote, ""), else: nil
    end)
  end

  # ── Card helpers ──────────────────────────────────────────────────────────────

  defp deployed_pct(balance, initial) when is_number(balance) and is_number(initial) and initial > 0,
    do: max(0.0, min(100.0, (1.0 - balance / initial) * 100.0))

  defp deployed_pct(_, _), do: 0.0

  defp short_fill_time(iso) when is_binary(iso) and byte_size(iso) >= 16,
    do: String.slice(iso, 5, 11)

  defp short_fill_time(_), do: "-"

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
