defmodule CriptoTraderWeb.ExperimentsLive.Findings do
  use Phoenix.LiveView

  alias CriptoTrader.Experiments.State

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CriptoTrader.PubSub, "experiments:updates")

    {:ok, assign(socket, findings: load_findings(), principles: load_principles())}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, assign(socket, findings: load_findings(), principles: load_principles())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Knowledge Base</h1>

    <h2 style="margin-top:2rem; color:#e3b341">Principles</h2>
    <p style="color:#8b949e; font-size:0.9em">Generalizable truths that persist across iterations and guide future research.</p>
    <%= if @principles == [] do %>
      <p style="color:#8b949e">No principles yet. Use <code>mix experiments.principles.add</code> to record one.</p>
    <% end %>
    <%= for p <- @principles do %>
      <div class="finding" style="border-left: 3px solid #e3b341; padding-left: 12px">
        <strong><%= Map.get(p, "principle", "?") %></strong>
        <br/>
        <%= for tag <- Map.get(p, "tags", []) do %>
          <span class="tag"><%= tag %></span>
        <% end %>
        <%= for ev <- Map.get(p, "evidence", []) do %>
          <span class="tag" style="background:#1f2937; color:#8b949e">evidence: <%= ev %></span>
        <% end %>
        <div style="color:#8b949e; font-size:0.85em; margin-top:6px">
          <%= short_time(Map.get(p, "added_at", "")) %>
        </div>
      </div>
    <% end %>

    <h2 style="margin-top:2rem">Findings</h2>
    <p style="color:#8b949e; font-size:0.9em">Per-experiment analysis records.</p>
    <%= if @findings == [] do %>
      <p style="color:#8b949e">No findings yet. Use <code>mix experiments.findings.add</code> to record one.</p>
    <% end %>
    <%= for finding <- @findings do %>
      <div class="finding">
        <strong><%= Map.get(finding, "title", "Untitled") %></strong>
        <span style="color:#8b949e; font-size:0.85em; margin-left:12px">
          exp: <%= Map.get(finding, "experiment_id", "?") %>
        </span>
        <br/>
        <%= for tag <- Map.get(finding, "tags", []) do %>
          <span class="tag"><%= tag %></span>
        <% end %>
        <%= if body = Map.get(finding, "body") do %>
          <pre style="margin-top:10px; font-size:0.82em; color:#c9d1d9; white-space:pre-wrap; background:#161b22; padding:10px; border-radius:4px"><%= body %></pre>
        <% end %>
        <div style="color:#8b949e; font-size:0.85em; margin-top:6px">
          <%= short_time(Map.get(finding, "added_at", "")) %>
        </div>
      </div>
    <% end %>
    """
  end

  defp load_findings do
    case State.list_findings() do
      {:ok, f} -> Enum.reverse(f)
      _ -> []
    end
  end

  defp load_principles do
    case State.list_principles() do
      {:ok, p} -> Enum.reverse(p)
      _ -> []
    end
  end

  defp short_time(iso) when is_binary(iso) and byte_size(iso) >= 16, do: String.slice(iso, 0, 16)
  defp short_time(_), do: "-"
end
