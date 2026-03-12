defmodule CriptoTraderWeb.ExperimentsLive.Findings do
  use Phoenix.LiveView

  alias CriptoTrader.Experiments.State

  @impl true
  def mount(_params, _session, socket) do
    findings =
      case State.list_findings() do
        {:ok, f} -> Enum.reverse(f)
        _ -> []
      end

    {:ok, assign(socket, findings: findings)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Findings</h1>
    <p style="color:#8b949e">Accumulated learnings from completed experiments.</p>
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
        <div style="color:#8b949e; font-size:0.85em; margin-top:6px">
          <%= short_time(Map.get(finding, "added_at", "")) %>
        </div>
      </div>
    <% end %>
    """
  end

  defp short_time(iso) when is_binary(iso) and byte_size(iso) >= 16, do: String.slice(iso, 0, 16)
  defp short_time(_), do: "-"
end
