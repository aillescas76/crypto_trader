defmodule CriptoTrader.Improvement.Config do
  @moduledoc false

  @default_storage_dir "priv/improvement"
  @default_tasks_file "tasks.json"
  @default_knowledge_base_file "knowledge_base.json"
  @default_loop_state_file "loop_state.json"
  @default_progress_report_file "progress_report.json"
  @default_agent_context_file "agent_context.json"
  @default_execution_budget_file "execution_budget.json"
  @default_adr_dir "docs/adr"
  @default_codex_cmd "codex"
  @default_codex_args [
    "exec",
    "--full-auto",
    "--sandbox",
    "workspace-write",
    "-C",
    ".",
    "-"
  ]
  @default_weekly_budget_seconds 18_000
  @default_codex_timeout_ms 3_600_000

  @spec storage_dir() :: String.t()
  def storage_dir do
    improvement_env()
    |> Keyword.get(:storage_dir, @default_storage_dir)
    |> to_string()
  end

  @spec tasks_file() :: String.t()
  def tasks_file do
    improvement_env()
    |> Keyword.get(:tasks_file, Path.join(storage_dir(), @default_tasks_file))
    |> to_string()
  end

  @spec knowledge_base_file() :: String.t()
  def knowledge_base_file do
    improvement_env()
    |> Keyword.get(:knowledge_base_file, Path.join(storage_dir(), @default_knowledge_base_file))
    |> to_string()
  end

  @spec loop_state_file() :: String.t()
  def loop_state_file do
    improvement_env()
    |> Keyword.get(:loop_state_file, Path.join(storage_dir(), @default_loop_state_file))
    |> to_string()
  end

  @spec progress_report_file() :: String.t()
  def progress_report_file do
    improvement_env()
    |> Keyword.get(:progress_report_file, Path.join(storage_dir(), @default_progress_report_file))
    |> to_string()
  end

  @spec agent_context_file() :: String.t()
  def agent_context_file do
    improvement_env()
    |> Keyword.get(:agent_context_file, Path.join(storage_dir(), @default_agent_context_file))
    |> to_string()
  end

  @spec execution_budget_file() :: String.t()
  def execution_budget_file do
    improvement_env()
    |> Keyword.get(
      :execution_budget_file,
      Path.join(storage_dir(), @default_execution_budget_file)
    )
    |> to_string()
  end

  @spec adr_dir() :: String.t()
  def adr_dir do
    improvement_env()
    |> Keyword.get(:adr_dir, @default_adr_dir)
    |> to_string()
  end

  @spec codex_cmd() :: String.t()
  def codex_cmd do
    improvement_env()
    |> Keyword.get(:codex_cmd, System.get_env("CODEX_CMD") || @default_codex_cmd)
    |> to_string()
  end

  @spec codex_args() :: [String.t()]
  def codex_args do
    case improvement_env() |> Keyword.get(:codex_args) do
      args when is_list(args) and args != [] ->
        Enum.map(args, &to_string/1)

      _ ->
        env_codex_args() || @default_codex_args
    end
  end

  @spec codex_timeout_ms() :: pos_integer()
  def codex_timeout_ms do
    improvement_env()
    |> Keyword.get(:codex_timeout_ms, @default_codex_timeout_ms)
    |> normalize_positive_integer(@default_codex_timeout_ms)
  end

  @spec weekly_budget_seconds() :: pos_integer()
  def weekly_budget_seconds do
    case improvement_env()
         |> Keyword.get(
           :weekly_budget_seconds,
           System.get_env("IMPROVEMENT_WEEKLY_BUDGET_SECONDS")
         ) do
      nil -> @default_weekly_budget_seconds
      value -> normalize_positive_integer(value, @default_weekly_budget_seconds)
    end
  end

  defp improvement_env do
    Application.get_env(:cripto_trader, :improvement, [])
  end

  defp env_codex_args do
    case System.get_env("CODEX_ARGS") do
      nil ->
        nil

      value ->
        parsed =
          value
          |> String.trim()
          |> OptionParser.split()

        if parsed == [], do: nil, else: parsed
    end
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default
end
