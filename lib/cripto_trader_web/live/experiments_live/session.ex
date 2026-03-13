defmodule CriptoTraderWeb.ExperimentsLive.Session do
  use Phoenix.LiveView

  alias CriptoTrader.Experiments.State

  @poll_ms 5_000

  @step_labels %{
    "1" => "Situational awareness",
    "4" => "Researching ideas",
    "5a" => "Mechanism analysis",
    "5b" => "Stress testing",
    "5c" => "Writing hypothesis",
    "6" => "Writing strategy",
    "7" => "Queueing experiment",
    "8" => "Running backtest",
    "9" => "Updating memory"
  }

  @research_steps ["4", "5a", "5b", "5c"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@poll_ms, self(), :refresh)

    {:ok,
     assign(socket,
       session: State.read_session(),
       step_data: load_step_data(),
       research_steps: @research_steps
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, session: State.read_session(), step_data: load_step_data(), research_steps: @research_steps)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Session</h1>
    <p style="color:#8b949e">Current experiment loop iteration state. Refreshes every 5s.</p>

    <div class={"session-panel session-#{status_class(@session)}"} style="margin-bottom:24px">
      <div class="session-header">
        <span class={"session-badge session-badge-#{status_class(@session)}"}><%= status_label(@session) %></span>
        <%= if Map.get(@session, "current_step") do %>
          <span class="session-step">
            Step <%= Map.get(@session, "current_step") %> — <%= step_label(Map.get(@session, "current_step")) %>
            <%= case elapsed_minutes(@session) do %>
              <% nil -> %><% %>
              <% 0 -> %> — just started<% %>
              <% m -> %> — <%= m %> min<% %>
            <% end %>
          </span>
        <% end %>
      </div>
      <%= for candidate <- hypothesis_candidates(@session) do %>
        <div class="session-hypothesis" style="margin-top:10px">
          <strong><%= Map.get(candidate, "name", "") %></strong>
          <%= if cat = Map.get(candidate, "category"), do: if(cat != "", do: " (#{cat})") %>
          <%= if inv_id = Map.get(candidate, "investigation_id") do %>
            <span style="color:#8b949e; font-size:0.8em; margin-left:4px">[<%= inv_id %>]</span>
          <% end %>
          <br/>
          <span style="color:#8b949e"><%= Map.get(candidate, "description", "") %></span>
        </div>
      <% end %>
    </div>

    <h2 style="font-size:1.1em; color:#f0f6fc; margin-bottom:12px">Research Steps</h2>
    <%= for step <- @research_steps do %>
      <% completed = step in Map.get(@session, "completed_steps", []) %>
      <% data = Map.get(@step_data, step) %>
      <div class="finding" style={"border-color: #{if completed, do: "#3fb950", else: "#30363d"}"}>
        <div style="display:flex; align-items:center; gap:12px">
          <span style={"color: #{if completed, do: "#3fb950", else: "#8b949e"}; font-weight:bold"}>
            <%= if completed, do: "●", else: "○" %> Step <%= step %>
          </span>
          <span style="color:#c9d1d9"><%= step_label(step) %></span>
          <%= if data do %>
            <span style="color:#8b949e; font-size:0.85em; margin-left:auto">
              <%= word_count(data) %> words
            </span>
          <% end %>
        </div>
        <%= if data do %>
          <div style="margin-top:8px; color:#8b949e; font-size:0.85em; white-space:pre-wrap; font-family:monospace; max-height:200px; overflow:auto; border-top:1px solid #21262d; padding-top:8px">
            <%= truncate(data, 800) %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp load_step_data do
    Map.new(State.list_session_data())
  end

  defp hypothesis_candidates(session) do
    case Map.get(session, "hypothesis_candidates") do
      list when is_list(list) and list != [] -> list
      _ ->
        case Map.get(session, "hypothesis_candidate") do
          nil -> []
          c -> [c]
        end
    end
  end

  defp status_class(%{"status" => "in_progress"}), do: "in_progress"
  defp status_class(%{"status" => "completed"}), do: "completed"
  defp status_class(_), do: "idle"

  defp status_label(%{"status" => "in_progress"}), do: "● IN PROGRESS"
  defp status_label(%{"status" => "completed"}), do: "✓ COMPLETED"
  defp status_label(_), do: "○ IDLE"

  defp step_label(step), do: Map.get(@step_labels, step, "")

  defp elapsed_minutes(%{"step_started_at" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, started, _} -> DateTime.diff(DateTime.utc_now(), started, :second) |> div(60)
      _ -> nil
    end
  end

  defp elapsed_minutes(_), do: nil

  defp word_count(text), do: text |> String.split() |> length()

  defp truncate(str, max) when byte_size(str) > max, do: String.slice(str, 0, max) <> "\n…"
  defp truncate(str, _), do: str
end
