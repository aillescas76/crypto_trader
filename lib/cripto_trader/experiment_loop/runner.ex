defmodule CriptoTrader.ExperimentLoop.Runner do
  @moduledoc """
  OTP GenServer replacement for scripts/run_experiment_loop.sh.

  Spawns `claude --dangerously-skip-permissions --print /experiment-loop` via Port,
  streams output to a log file, detects rate limits, enforces an inactivity timeout,
  and broadcasts status updates via PubSub.

  Config (config.exs):

      config :cripto_trader, CriptoTrader.ExperimentLoop.Runner,
        auto_start: false,         # start running on server boot
        sleep_ms: 300_000,         # delay between iterations (5 min)
        improve_every: 5,          # run /analyse-traces every N iterations (0 = off)
        timeout_ms: 5_400_000,     # kill stuck Claude after 90 minutes of inactivity
        iterations: 0,             # 0 = run forever
        budget_usd: nil            # nil = no cap; float = --max-budget-usd N
  """

  use GenServer
  require Logger

  @pubsub_topic "experiment_loop:status"
  @log_dir "priv/experiments/loop_logs"

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_loop, do: GenServer.call(__MODULE__, :start_loop)
  def stop_loop, do: GenServer.call(__MODULE__, :stop_loop)
  def status, do: GenServer.call(__MODULE__, :status)

  # ── Init ─────────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    cfg = build_config()
    File.mkdir_p!(@log_dir)

    state = %{
      status: :idle,
      iteration: 0,
      port: nil,
      log_fd: nil,
      log_file: nil,
      timer_ref: nil,
      buf: "",
      config: cfg
    }

    if cfg.auto_start do
      send(self(), :next_iteration)
    end

    {:ok, state}
  end

  # ── Call handlers ────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:start_loop, _from, %{status: :idle} = state) do
    send(self(), :next_iteration)
    {:reply, :ok, state}
  end

  def handle_call(:start_loop, _from, state) do
    {:reply, {:error, state.status}, state}
  end

  def handle_call(:stop_loop, _from, state) do
    state = kill_port(state)
    state = cancel_timer(state)
    state = %{state | status: :stopped}
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{status: state.status, iteration: state.iteration}, state}
  end

  # ── Iteration scheduling ─────────────────────────────────────────────────────

  @impl true
  def handle_info(:next_iteration, %{status: :stopped} = state), do: {:noreply, state}

  def handle_info(:next_iteration, state) do
    cfg = state.config

    # Check iteration cap
    if cfg.iterations > 0 and state.iteration >= cfg.iterations do
      Logger.info("[ExperimentLoop] Reached #{cfg.iterations} iteration(s). Stopping.")
      state = %{state | status: :idle}
      broadcast(state)
      {:noreply, state}
    else
      state = launch_claude(state)
      {:noreply, state}
    end
  end

  # ── Port data ────────────────────────────────────────────────────────────────

  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    # Write to log file
    if state.log_fd, do: IO.write(state.log_fd, chunk)

    buf = state.buf <> chunk

    # Reset inactivity timeout
    state = reset_timer(state)
    state = %{state | buf: buf}

    # Check for rate limit in buffered output
    if rate_limited?(buf) do
      state = kill_port(state)
      state = cancel_timer(state)
      wait_ms = parse_wait_ms(buf)
      Logger.warning("[ExperimentLoop] Rate limit detected. Sleeping #{div(wait_ms, 1000)}s.")
      state = %{state | status: :rate_limited, buf: ""}
      broadcast(state)
      Process.send_after(self(), :next_iteration, wait_ms)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:data, _chunk}}, state) when port != state.port, do: {:noreply, state}

  # ── Port exit ────────────────────────────────────────────────────────────────

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = cancel_timer(state)
    close_log(state)

    if code != 0 do
      Logger.warning("[ExperimentLoop] Iteration #{state.iteration} exited #{code}. Log: #{state.log_file}")
    else
      Logger.info("[ExperimentLoop] Iteration #{state.iteration} done. Log: #{state.log_file}")
    end

    state = %{state | port: nil, log_fd: nil, buf: "", status: :idle}

    # Periodic improve run
    cfg = state.config

    state =
      if cfg.improve_every > 0 and rem(state.iteration, cfg.improve_every) == 0 do
        run_analyse_traces(state)
      else
        state
      end

    broadcast(state)

    # Schedule next unless stopped or capped
    if state.status != :stopped do
      if cfg.iterations > 0 and state.iteration >= cfg.iterations do
        Logger.info("[ExperimentLoop] Reached #{cfg.iterations} iteration(s). Done.")
        state
      else
        Logger.info("[ExperimentLoop] Sleeping #{div(cfg.sleep_ms, 1000)}s before next iteration...")
        Process.send_after(self(), :next_iteration, cfg.sleep_ms)
        state
      end
    else
      state
    end
    |> then(&{:noreply, &1})
  end

  def handle_info({port, {:exit_status, _}}, state) when port != state.port, do: {:noreply, state}

  # ── Inactivity timeout ────────────────────────────────────────────────────────

  def handle_info(:timeout, state) do
    Logger.warning("[ExperimentLoop] Iteration #{state.iteration} timed out (no output for #{div(state.config.timeout_ms, 60_000)} min). Killing.")
    close_log(state)
    state = kill_port(state)
    state = %{state | status: :idle, buf: ""}
    broadcast(state)
    Process.send_after(self(), :next_iteration, state.config.sleep_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp build_config do
    cfg = Application.get_env(:cripto_trader, __MODULE__, [])

    %{
      auto_start: Keyword.get(cfg, :auto_start, false),
      sleep_ms: Keyword.get(cfg, :sleep_ms, 300_000),
      improve_every: Keyword.get(cfg, :improve_every, 5),
      timeout_ms: Keyword.get(cfg, :timeout_ms, 5_400_000),
      iterations: Keyword.get(cfg, :iterations, 0),
      budget_usd: Keyword.get(cfg, :budget_usd, nil)
    }
  end

  defp launch_claude(state) do
    iteration = state.iteration + 1
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d_%H-%M-%S")
    log_file = Path.join(@log_dir, "#{timestamp}_iter#{iteration}.log")
    log_fd = File.open!(log_file, [:write, :utf8])

    args = base_claude_args(state.config) ++ ["/experiment-loop"]

    claude_bin = System.find_executable("claude") || raise "claude not found in PATH"

    port =
      Port.open({:spawn_executable, claude_bin}, [
        :binary,
        :exit_status,
        {:args, args}
      ])

    Logger.info("[ExperimentLoop] Iteration #{iteration} started. Log: #{log_file}")

    state = cancel_timer(state)
    timer_ref = Process.send_after(self(), :timeout, state.config.timeout_ms)

    state = %{
      state
      | status: :running,
        iteration: iteration,
        port: port,
        log_fd: log_fd,
        log_file: log_file,
        timer_ref: timer_ref,
        buf: ""
    }

    broadcast(state)
    state
  end

  defp run_analyse_traces(state) do
    n = state.config.improve_every
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d_%H-%M-%S")
    log_file = Path.join(@log_dir, "#{timestamp}_analyse_traces.log")
    Logger.info("[ExperimentLoop] Running /analyse-traces --last #{n}")

    claude_bin = System.find_executable("claude") || raise "claude not found in PATH"
    args = ["--dangerously-skip-permissions", "--print", "/analyse-traces --last #{n}"]

    case System.cmd(claude_bin, args, stderr_to_stdout: true) do
      {output, 0} ->
        File.write!(log_file, output)
        Logger.info("[ExperimentLoop] analyse-traces done. Log: #{log_file}")

      {output, code} ->
        File.write!(log_file, output)

        if rate_limited?(output) do
          Logger.warning("[ExperimentLoop] Rate limit during analyse-traces. Skipping.")
        else
          Logger.warning("[ExperimentLoop] analyse-traces exited #{code}. Log: #{log_file}")
        end
    end

    state
  end

  defp base_claude_args(cfg) do
    args = ["--dangerously-skip-permissions", "--print"]

    if cfg.budget_usd do
      args ++ ["--max-budget-usd", to_string(cfg.budget_usd)]
    else
      args
    end
  end

  defp kill_port(%{port: nil} = state), do: state

  defp kill_port(%{port: port} = state) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    %{state | port: nil}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp reset_timer(state) do
    state = cancel_timer(state)
    ref = Process.send_after(self(), :timeout, state.config.timeout_ms)
    %{state | timer_ref: ref}
  end

  defp close_log(%{log_fd: nil}), do: :ok
  defp close_log(%{log_fd: fd}), do: File.close(fd)

  @rate_limit_re ~r/usage limit|rate limit|hit your limit|quota exceeded|too many requests|resets \d/i

  defp rate_limited?(text), do: Regex.match?(@rate_limit_re, text)

  # Parse how long to wait from rate-limit message; fallback to 5h10m
  defp parse_wait_ms(text) do
    cond do
      m = Regex.run(~r/retry.after:?\s*(\d+)/i, text) ->
        String.to_integer(Enum.at(m, 1)) * 1000

      m = Regex.run(~r/resets in (\d+) (hour|minute)/i, text) ->
        n = String.to_integer(Enum.at(m, 1))
        if String.starts_with?(Enum.at(m, 2), "h"), do: n * 3_600_000, else: n * 60_000

      true ->
        # Default: 5h10m rolling window
        18_600_000
    end
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      CriptoTrader.PubSub,
      @pubsub_topic,
      {:loop_status, %{status: state.status, iteration: state.iteration}}
    )
  end
end
