defmodule CriptoTraderWeb.ExperimentsLive.Investigations do
  use Phoenix.LiveView

  alias CriptoTrader.Experiments.State

  @poll_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@poll_ms, self(), :refresh)

    {:ok,
     assign(socket,
       investigations: load_investigations(),
       confirming_discard: nil,
       discard_reason: ""
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, investigations: load_investigations())}
  end

  @impl true
  def handle_event("resume", %{"id" => id}, socket) do
    State.unfreeze_investigation(id)
    {:noreply, assign(socket, investigations: load_investigations())}
  end

  def handle_event("confirm-discard", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming_discard: id, discard_reason: "")}
  end

  def handle_event("cancel-discard", _params, socket) do
    {:noreply, assign(socket, confirming_discard: nil, discard_reason: "")}
  end

  def handle_event("update-reason", %{"reason" => reason} = _params, socket) do
    {:noreply, assign(socket, discard_reason: reason)}
  end

  def handle_event("submit-discard", %{"inv_id" => id}, socket) do
    reason = socket.assigns.discard_reason

    if String.trim(reason) == "" do
      {:noreply, socket}
    else
      State.discard_investigation(id, reason)
      {:noreply, assign(socket, investigations: load_investigations(), confirming_discard: nil, discard_reason: "")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Investigations</h1>
    <p style="color:#8b949e">Lines of micro-experimentation. Frozen investigations await your decision. Refreshes every 5s.</p>

    <%= if @investigations == [] do %>
      <p style="color:#8b949e">No investigations yet.</p>
    <% else %>
      <%= for {group_label, group} <- grouped_investigations(@investigations) do %>
        <%= if group != [] do %>
          <h2 style="font-size:1em; color:#8b949e; margin: 20px 0 8px; text-transform:uppercase; letter-spacing:0.05em"><%= group_label %></h2>
          <%= for inv <- group do %>
            <div class="finding" style={"border-color: #{border_color(inv["status"])}; margin-bottom:12px"}>

              <%!-- Header row --%>
              <div style="display:flex; align-items:center; gap:10px; flex-wrap:wrap">
                <span style={"color: #{status_color(inv["status"])}; font-weight:bold; font-size:0.9em"}>
                  <%= status_icon(inv["status"]) %> <%= String.upcase(inv["status"]) %>
                </span>
                <span style="color:#f0f6fc; font-weight:bold"><%= inv["name"] %></span>
                <%= if inv["in_flight"] do %>
                  <span style="color:#f0883e; font-size:0.8em; margin-left:auto">⟳ IN FLIGHT</span>
                <% end %>
              </div>

              <%!-- Concept --%>
              <div style="margin-top:5px; color:#8b949e; font-size:0.88em"><%= inv["concept"] %></div>

              <%!-- Stats row --%>
              <div style="margin-top:8px; display:flex; gap:16px; font-size:0.82em; color:#8b949e; flex-wrap:wrap">
                <span><%= length(inv["experiments"] || []) %> experiments</span>
                <%= if inv["streak"] > 0 do %>
                  <span style={"color: #{if inv["streak"] >= 3, do: "#f85149", else: "#8b949e"}"}>
                    no-improvement streak: <%= inv["streak"] %>
                  </span>
                <% end %>
                <%= if parent = inv["parent_experiment_id"] do %>
                  <span>parent: <%= parent %></span>
                <% end %>
              </div>

              <%!-- Experiment results --%>
              <%= if (inv["experiment_results"] || []) != [] do %>
                <div style="margin-top:10px; border-top:1px solid #21262d; padding-top:8px">
                  <%= for exp <- inv["experiment_results"] do %>
                    <div style="font-size:0.8em; color:#8b949e; font-family:monospace; margin-bottom:2px">
                      [<%= exp["id"] %>] <%= exp["status"] %>
                      | train: <%= format_pnl(exp["training_result"]) %>
                      | val: <%= format_pnl(exp["validation_result"]) %>
                      | <%= format_verdict(exp["verdict"]) %>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Frozen: discard confirmation form or action buttons --%>
              <%= if inv["status"] == "frozen" do %>
                <%= if @confirming_discard == inv["id"] do %>
                  <div style="margin-top:12px; border-top:1px solid #30363d; padding-top:12px">
                    <div style="color:#e3b341; font-size:0.88em; margin-bottom:8px; font-weight:bold">
                      Discard reason (required):
                    </div>
                    <form phx-change="update-reason" phx-submit="submit-discard">
                      <input type="hidden" name="inv_id" value={inv["id"]} />
                      <textarea
                        name="reason"
                        placeholder="Why is this investigation being abandoned?"
                        style="width:100%; background:#0d1117; color:#c9d1d9; border:1px solid #30363d; border-radius:4px; padding:8px; font-family:monospace; font-size:0.85em; min-height:60px; resize:vertical; box-sizing:border-box"
                      ><%= @discard_reason %></textarea>
                      <div style="margin-top:8px; display:flex; gap:8px">
                        <button
                          type="submit"
                          disabled={String.trim(@discard_reason) == ""}
                          style={"background:#b91c1c; color:#fff; border:none; border-radius:4px; padding:6px 14px; cursor:#{if String.trim(@discard_reason) == "", do: "not-allowed", else: "pointer"}; opacity:#{if String.trim(@discard_reason) == "", do: "0.5", else: "1"}; font-size:0.85em"}
                        >
                          Confirm Discard
                        </button>
                        <button
                          type="button"
                          phx-click="cancel-discard"
                          style="background:#21262d; color:#c9d1d9; border:1px solid #30363d; border-radius:4px; padding:6px 14px; cursor:pointer; font-size:0.85em"
                        >
                          Cancel
                        </button>
                      </div>
                    </form>
                  </div>
                <% else %>
                  <div style="margin-top:12px; border-top:1px solid #30363d; padding-top:12px; display:flex; gap:8px; align-items:center">
                    <span style="color:#e3b341; font-size:0.85em; margin-right:4px">⏸ Awaiting decision</span>
                    <button
                      phx-click="resume"
                      phx-value-id={inv["id"]}
                      style="background:#21262d; color:#3fb950; border:1px solid #3fb950; border-radius:4px; padding:5px 12px; cursor:pointer; font-size:0.82em"
                    >
                      Resume
                    </button>
                    <button
                      phx-click="confirm-discard"
                      phx-value-id={inv["id"]}
                      style="background:#21262d; color:#f85149; border:1px solid #f85149; border-radius:4px; padding:5px 12px; cursor:pointer; font-size:0.82em"
                    >
                      Discard
                    </button>
                  </div>
                <% end %>
              <% end %>

              <%!-- Discard reason for already-discarded --%>
              <%= if inv["status"] == "discarded" and inv["discard_reason"] do %>
                <div style="margin-top:8px; color:#8b949e; font-size:0.83em; font-style:italic; border-top:1px solid #21262d; padding-top:8px">
                  Reason: <%= inv["discard_reason"] %>
                </div>
              <% end %>

            </div>
          <% end %>
        <% end %>
      <% end %>
    <% end %>
    """
  end

  defp load_investigations do
    with {:ok, investigations} <- State.list_investigations(),
         {:ok, experiments} <- State.list_experiments() do
      Enum.map(investigations, fn inv ->
        inv_exp_ids = Map.get(inv, "experiments", [])

        inv_exps =
          experiments
          |> Enum.filter(fn e -> Map.get(e, "id") in inv_exp_ids end)
          |> Enum.sort_by(fn e -> Map.get(e, "queued_at", "") end)

        in_flight =
          Enum.any?(inv_exps, fn e -> Map.get(e, "status") in ["pending", "running"] end)

        streak = compute_no_improvement_streak(inv_exps)

        inv
        |> Map.put("in_flight", in_flight)
        |> Map.put("streak", streak)
        |> Map.put("experiment_results", inv_exps)
      end)
    else
      _ -> []
    end
  end

  defp grouped_investigations(investigations) do
    frozen = Enum.filter(investigations, &(&1["status"] == "frozen"))
    active = Enum.filter(investigations, &(&1["status"] == "active"))
    graduated = Enum.filter(investigations, &(&1["status"] == "graduated"))
    discarded = Enum.filter(investigations, &(&1["status"] == "discarded"))
    [{"Frozen — awaiting decision", frozen}, {"Active", active}, {"Graduated", graduated}, {"Discarded", discarded}]
  end

  defp compute_no_improvement_streak(exps) do
    finished =
      Enum.filter(exps, fn e ->
        Map.get(e, "status") in ["passed", "failed"] and
          get_in(e, ["training_result", "pnl_pct"]) != nil
      end)

    case finished do
      [] -> 0
      [_] -> 0
      _ ->
        pnl_series = Enum.map(finished, &(get_in(&1, ["training_result", "pnl_pct"]) || 0.0))

        pnl_series
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, curr] -> curr - prev end)
        |> Enum.reverse()
        |> Enum.take_while(fn delta -> delta < 0.5 end)
        |> length()
    end
  end

  defp border_color("frozen"), do: "#e3b341"
  defp border_color("active"), do: "#3fb950"
  defp border_color("graduated"), do: "#58a6ff"
  defp border_color(_), do: "#30363d"

  defp status_color("frozen"), do: "#e3b341"
  defp status_color("active"), do: "#3fb950"
  defp status_color("graduated"), do: "#58a6ff"
  defp status_color(_), do: "#8b949e"

  defp status_icon("active"), do: "●"
  defp status_icon("frozen"), do: "⏸"
  defp status_icon("graduated"), do: "✓"
  defp status_icon(_), do: "○"

  defp format_pnl(%{"pnl_pct" => pct}) when is_number(pct), do: "#{Float.round(pct * 1.0, 2)}%"
  defp format_pnl(_), do: "-"

  defp format_verdict(%{"verdict" => v}), do: String.upcase(v)
  defp format_verdict(_), do: "-"
end
