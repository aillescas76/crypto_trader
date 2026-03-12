defmodule CriptoTraderWeb.ExperimentsLive.Feed do
  use Phoenix.LiveView

  alias CriptoTrader.Experiments.State

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CriptoTrader.PubSub, "experiments:updates")
    end

    experiments =
      case State.list_experiments() do
        {:ok, exps} -> Enum.reverse(exps)
        _ -> []
      end

    {:ok, assign(socket, experiments: experiments)}
  end

  @impl true
  def handle_info({:experiment_update, updated_exp}, socket) do
    id = Map.get(updated_exp, "id")

    experiments =
      socket.assigns.experiments
      |> Enum.map(fn e -> if Map.get(e, "id") == id, do: updated_exp, else: e end)
      |> then(fn exps ->
        if Enum.any?(exps, fn e -> Map.get(e, "id") == id end) do
          exps
        else
          [updated_exp | exps]
        end
      end)

    {:noreply, assign(socket, experiments: experiments)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Experiment Feed</h1>
    <p style="color:#8b949e">Live updates via WebSocket. Total: <%= length(@experiments) %></p>
    <table>
      <thead>
        <tr>
          <th>ID</th>
          <th>Strategy</th>
          <th>Status</th>
          <th>Verdict</th>
          <th>Train PnL%</th>
          <th>Val PnL%</th>
          <th>Train Sharpe</th>
          <th>Queued</th>
        </tr>
      </thead>
      <tbody>
        <%= for exp <- @experiments do %>
          <tr>
            <td style="font-size:0.85em"><%= Map.get(exp, "id", "?") %></td>
            <td><%= short_module(Map.get(exp, "strategy_module", "")) %></td>
            <td class={"badge-#{Map.get(exp, "status", "pending")}"}><%= Map.get(exp, "status", "?") %></td>
            <td class={verdict_class(exp)}><%= format_verdict(exp) %></td>
            <td><%= format_pnl(Map.get(exp, "training_result")) %></td>
            <td><%= format_pnl(Map.get(exp, "validation_result")) %></td>
            <td><%= format_sharpe(Map.get(exp, "training_result")) %></td>
            <td style="font-size:0.85em"><%= short_time(Map.get(exp, "queued_at", "")) %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end

  defp short_module(mod) when is_binary(mod), do: mod |> String.split(".") |> List.last() || "?"
  defp short_module(_), do: "?"

  defp format_verdict(exp) do
    case Map.get(exp, "verdict") do
      %{"verdict" => v} -> String.upcase(v)
      %{verdict: v} -> v |> to_string() |> String.upcase()
      _ -> "-"
    end
  end

  defp verdict_class(exp) do
    case Map.get(exp, "verdict") do
      %{"verdict" => "pass"} -> "pass"
      %{"verdict" => "fail"} -> "fail"
      _ -> ""
    end
  end

  defp format_pnl(nil), do: "-"
  defp format_pnl(%{"pnl_pct" => pct}) when is_number(pct), do: "#{Float.round(pct * 1.0, 2)}%"
  defp format_pnl(_), do: "-"

  defp format_sharpe(nil), do: "-"
  defp format_sharpe(%{"sharpe" => s}) when is_number(s), do: Float.round(s * 1.0, 3) |> to_string()
  defp format_sharpe(_), do: "-"

  defp short_time(iso) when is_binary(iso) and byte_size(iso) >= 16, do: String.slice(iso, 0, 16)
  defp short_time(_), do: "-"
end
