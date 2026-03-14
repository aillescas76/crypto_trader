defmodule CriptoTraderWeb.ExperimentsLive.Feed do
  use Phoenix.LiveView

  alias CriptoTrader.Experiments.State

  alias CriptoTrader.ExperimentLoop.Runner, as: LoopRunner

  @session_poll_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CriptoTrader.PubSub, "experiments:updates")
      Phoenix.PubSub.subscribe(CriptoTrader.PubSub, "experiment_loop:status")
      :timer.send_interval(@session_poll_ms, self(), :refresh_session)
      :timer.send_interval(@session_poll_ms, self(), :refresh_experiments)
    end

    experiments =
      case State.list_experiments() do
        {:ok, exps} -> Enum.reverse(exps)
        _ -> []
      end

    loop_status = LoopRunner.status()

    {:ok,
     assign(socket,
       experiments: experiments,
       loop_session: State.read_session(),
       loop_status: loop_status
     )}
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

  def handle_info({:loop_status, snap}, socket) do
    {:noreply, assign(socket, loop_status: snap)}
  end

  def handle_info(:refresh_session, socket) do
    {:noreply, assign(socket, loop_session: State.read_session())}
  end

  def handle_info(:refresh_experiments, socket) do
    experiments =
      case State.list_experiments() do
        {:ok, exps} -> Enum.reverse(exps)
        _ -> socket.assigns.experiments
      end

    {:noreply, assign(socket, experiments: experiments)}
  end

  @impl true
  def handle_event("loop_start", _params, socket) do
    LoopRunner.start_loop()
    {:noreply, assign(socket, loop_status: LoopRunner.status())}
  end

  def handle_event("loop_stop", _params, socket) do
    LoopRunner.stop_loop()
    {:noreply, assign(socket, loop_status: LoopRunner.status())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Experiment Feed</h1>

    <%!-- Loop runner controls --%>
    <div style="display:flex; align-items:center; gap:12px; margin-bottom:16px; background:#161b22; border:1px solid #30363d; border-radius:8px; padding:10px 16px">
      <span style={"color:#{loop_status_color(@loop_status)}; font-size:0.9em; font-weight:bold"}>
        <%= loop_status_label(@loop_status) %>
      </span>
      <%= if @loop_status.iteration > 0 do %>
        <span style="color:#8b949e; font-size:0.85em">iteration <%= @loop_status.iteration %></span>
      <% end %>
      <div style="margin-left:auto; display:flex; gap:8px">
        <%= if @loop_status.status in [:idle, :stopped] do %>
          <button phx-click="loop_start" style="background:#238636; color:#fff; border:none; border-radius:6px; padding:5px 14px; cursor:pointer; font-size:0.85em">
            ▶ Start loop
          </button>
        <% else %>
          <button phx-click="loop_stop" style="background:#da3633; color:#fff; border:none; border-radius:6px; padding:5px 14px; cursor:pointer; font-size:0.85em">
            ■ Stop loop
          </button>
        <% end %>
      </div>
    </div>

    <div class={"session-panel session-#{session_status(@loop_session)}"}>
      <div class="session-header">
        <span class={"session-badge session-badge-#{session_status(@loop_session)}"}><%= session_status_label(@loop_session) %></span>
        <%= if session_status(@loop_session) == "in_progress" do %>
          <span class="session-step">Step <%= Map.get(@loop_session, "current_step", "?") %> — <%= step_label(Map.get(@loop_session, "current_step")) %><%= case elapsed_minutes(@loop_session) do %>
            <% nil -> %><% %>
            <% 0 -> %> — just started<% %>
            <% mins -> %> — <%= mins %> min<% %>
          <% end %></span>
        <% end %>
        <span class="session-progress"><%= session_progress_dots(@loop_session) %></span>
      </div>
      <%= for candidate <- hypothesis_candidates(@loop_session) do %>
        <div class="session-hypothesis">
          <strong><%= Map.get(candidate, "name", "") %></strong>
          <%= if cat = Map.get(candidate, "category"), do: if(cat != "", do: " (#{cat})") %>
          <%= if inv_id = Map.get(candidate, "investigation_id") do %>
            <span style="color:#8b949e; font-size:0.8em"> [<%= inv_id %>]</span>
          <% end %>
          <br/>
          <span style="color:#8b949e"><%= truncate(Map.get(candidate, "description", ""), 200) %></span>
        </div>
      <% end %>
    </div>

    <p style="color:#8b949e">Live updates via WebSocket. Total: <%= length(@experiments) %></p>
    <table>
      <thead>
        <tr>
          <th>ID</th>
          <th>Strategy</th>
          <th>Status</th>
          <th>Verdict</th>
          <th><span title="Strategy P&L% on the TRAINING period (2021-12 → 2025-01) vs Buy-and-Hold baseline. Must beat BnH to count toward a PASS verdict." style="cursor:help; border-bottom:1px dotted #8b949e">Train PnL%</span></th>
          <th><span title="Strategy P&L% on the VALIDATION period (2025-01 → 2026-01, unseen data) vs Buy-and-Hold. Both training AND validation must beat BnH for a PASS verdict." style="cursor:help; border-bottom:1px dotted #8b949e">Val PnL%</span></th>
          <th><span title="Sharpe ratio on the training period: annualised return ÷ volatility. Measures risk-adjusted performance — higher is better. Used as a secondary pass criterion alongside PnL%." style="cursor:help; border-bottom:1px dotted #8b949e">Train Sharpe</span></th>
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

  # ── Session helpers ───────────────────────────────────────────────────────

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

  defp session_status(%{"status" => "in_progress"}), do: "in_progress"
  defp session_status(%{"status" => "completed"}), do: "completed"
  defp session_status(_), do: "idle"

  defp session_status_label(%{"status" => "in_progress"}), do: "● IN PROGRESS"
  defp session_status_label(%{"status" => "completed"}), do: "✓ COMPLETED"
  defp session_status_label(_), do: "○ IDLE"

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
  defp step_label(step), do: Map.get(@step_labels, step, "")

  defp elapsed_minutes(%{"step_started_at" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, started, _} -> DateTime.diff(DateTime.utc_now(), started, :second) |> div(60)
      _ -> nil
    end
  end
  defp elapsed_minutes(_), do: nil

  @step_order ["4", "5a", "5b", "5c"]

  defp session_progress_dots(session) when map_size(session) == 0, do: ""

  defp session_progress_dots(session) do
    completed = Map.get(session, "completed_steps", [])

    @step_order
    |> Enum.map(fn step ->
      if step in completed, do: "●#{step}", else: "○#{step}"
    end)
    |> Enum.join("  ")
  end

  defp truncate(str, max) when byte_size(str) > max, do: String.slice(str, 0, max) <> "…"
  defp truncate(str, _), do: str

  # ── Experiment helpers ─────────────────────────────────────────────────────

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

  # ── Loop runner helpers ────────────────────────────────────────────────────

  defp loop_status_label(%{status: :running}), do: "● RUNNING"
  defp loop_status_label(%{status: :rate_limited}), do: "⏸ RATE LIMITED"
  defp loop_status_label(%{status: :stopped}), do: "■ STOPPED"
  defp loop_status_label(_), do: "○ IDLE"

  defp loop_status_color(%{status: :running}), do: "#3fb950"
  defp loop_status_color(%{status: :rate_limited}), do: "#e3b341"
  defp loop_status_color(%{status: :stopped}), do: "#f85149"
  defp loop_status_color(_), do: "#8b949e"
end
