defmodule CriptoTraderWeb.ExperimentsLive.Feedback do
  use Phoenix.LiveView

  alias CriptoTrader.Experiments.State

  @impl true
  def mount(_params, _session, socket) do
    feedback =
      case State.list_feedback() do
        {:ok, f} -> Enum.reverse(f)
        _ -> []
      end

    {:ok,
     assign(socket,
       feedback: feedback,
       note: "",
       tags: "",
       submitted: false
     )}
  end

  @impl true
  def handle_event("change", %{"note" => note, "tags" => tags}, socket) do
    {:noreply, assign(socket, note: note, tags: tags, submitted: false)}
  end

  @impl true
  def handle_event("submit", %{"note" => note, "tags" => tags}, socket) do
    if String.trim(note) == "" do
      {:noreply, socket}
    else
      tag_list =
        tags
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      entry = %{"note" => note, "tags" => tag_list}

      case State.add_feedback(entry) do
        {:ok, _id} ->
          feedback =
            case State.list_feedback() do
              {:ok, f} -> Enum.reverse(f)
              _ -> socket.assigns.feedback
            end

          {:noreply, assign(socket, feedback: feedback, note: "", tags: "", submitted: true)}

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Feedback</h1>
    <p style="color:#8b949e">Notes for Claude Code — incorporated on next loop iteration.</p>

    <form phx-change="change" phx-submit="submit" style="margin-bottom:24px">
      <div style="margin-bottom:12px">
        <label style="display:block; margin-bottom:4px; color:#8b949e">Note</label>
        <textarea name="note" rows="4" value={@note} phx-value-note={@note}><%= @note %></textarea>
      </div>
      <div style="margin-bottom:12px">
        <label style="display:block; margin-bottom:4px; color:#8b949e">Tags (comma-separated)</label>
        <input type="text" name="tags" value={@tags} placeholder="bearish, trend-filter, ..." style="width:100%" />
      </div>
      <button type="submit">Submit Feedback</button>
      <%= if @submitted do %>
        <span style="color:#3fb950; margin-left:12px">Saved!</span>
      <% end %>
    </form>

    <h2 style="font-size:1em; color:#8b949e">Recent Feedback</h2>
    <%= if @feedback == [] do %>
      <p style="color:#8b949e">No feedback yet.</p>
    <% end %>
    <%= for entry <- @feedback do %>
      <div class={"feedback-entry #{if Map.get(entry, "acknowledged"), do: "ack", else: ""}"}>
        <div><%= Map.get(entry, "note", "") %></div>
        <%= for tag <- Map.get(entry, "tags", []) do %>
          <span class="tag"><%= tag %></span>
        <% end %>
        <div style="color:#8b949e; font-size:0.85em; margin-top:6px">
          <%= short_time(Map.get(entry, "added_at", "")) %>
          <%= if Map.get(entry, "acknowledged") do %>
            <span style="color:#3fb950"> ✓ acknowledged</span>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp short_time(iso) when is_binary(iso) and byte_size(iso) >= 16, do: String.slice(iso, 0, 16)
  defp short_time(_), do: "-"
end
