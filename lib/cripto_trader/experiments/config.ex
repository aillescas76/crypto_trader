defmodule CriptoTrader.Experiments.Config do
  @moduledoc false

  @default_storage_dir "priv/experiments"
  @default_hypotheses_file "hypotheses.json"
  @default_experiments_file "experiments.json"
  @default_findings_file "findings.json"
  @default_principles_file "principles.json"
  @default_feedback_file "feedback.json"
  @default_investigations_file "investigations.json"
  @default_session_file "loop_session.json"
  @default_session_data_subdir "session_data"

  # 2025-01-01 00:00:00 UTC in milliseconds
  @default_training_cutoff_ms 1_735_689_600_000

  @default_symbols ["BTCUSDC", "ETHUSDC", "SOLUSDC", "BNBUSDC", "ADAUSDC", "XRPUSDC"]
  @default_interval "15m"
  @default_initial_balance 10_000.0

  # Full backtest range
  @default_start_time_ms 1_640_995_200_000
  # 2026-01-01 (approx present)
  @default_end_time_ms 1_767_225_600_000

  @spec storage_dir() :: String.t()
  def storage_dir do
    experiments_env()
    |> Keyword.get(:storage_dir, @default_storage_dir)
    |> to_string()
  end

  @spec hypotheses_file() :: String.t()
  def hypotheses_file do
    experiments_env()
    |> Keyword.get(:hypotheses_file, Path.join(storage_dir(), @default_hypotheses_file))
    |> to_string()
  end

  @spec experiments_file() :: String.t()
  def experiments_file do
    experiments_env()
    |> Keyword.get(:experiments_file, Path.join(storage_dir(), @default_experiments_file))
    |> to_string()
  end

  @spec findings_file() :: String.t()
  def findings_file do
    experiments_env()
    |> Keyword.get(:findings_file, Path.join(storage_dir(), @default_findings_file))
    |> to_string()
  end

  @spec principles_file() :: String.t()
  def principles_file do
    experiments_env()
    |> Keyword.get(:principles_file, Path.join(storage_dir(), @default_principles_file))
    |> to_string()
  end

  @spec session_data_dir() :: String.t()
  def session_data_dir do
    experiments_env()
    |> Keyword.get(:session_data_dir, Path.join(storage_dir(), @default_session_data_subdir))
    |> to_string()
  end

  @spec session_file() :: String.t()
  def session_file do
    experiments_env()
    |> Keyword.get(:session_file, Path.join(storage_dir(), @default_session_file))
    |> to_string()
  end

  @spec feedback_file() :: String.t()
  def feedback_file do
    experiments_env()
    |> Keyword.get(:feedback_file, Path.join(storage_dir(), @default_feedback_file))
    |> to_string()
  end

  @spec investigations_file() :: String.t()
  def investigations_file do
    experiments_env()
    |> Keyword.get(:investigations_file, Path.join(storage_dir(), @default_investigations_file))
    |> to_string()
  end

  @spec training_cutoff_ms() :: non_neg_integer()
  def training_cutoff_ms do
    experiments_env()
    |> Keyword.get(:training_cutoff_ms, @default_training_cutoff_ms)
    |> normalize_positive_integer(@default_training_cutoff_ms)
  end

  @spec default_symbols() :: [String.t()]
  def default_symbols do
    experiments_env()
    |> Keyword.get(:default_symbols, @default_symbols)
  end

  @spec default_interval() :: String.t()
  def default_interval do
    experiments_env()
    |> Keyword.get(:default_interval, @default_interval)
    |> to_string()
  end

  @spec default_initial_balance() :: float()
  def default_initial_balance do
    experiments_env()
    |> Keyword.get(:default_initial_balance, @default_initial_balance)
  end

  @spec default_start_time_ms() :: non_neg_integer()
  def default_start_time_ms do
    experiments_env()
    |> Keyword.get(:start_time_ms, @default_start_time_ms)
  end

  @spec default_end_time_ms() :: non_neg_integer()
  def default_end_time_ms do
    experiments_env()
    |> Keyword.get(:end_time_ms, @default_end_time_ms)
  end

  @spec cache_dir() :: String.t()
  def cache_dir do
    experiments_env()
    |> Keyword.get(
      :cache_dir,
      Path.join(System.user_home!(), ".cripto_trader/archive_cache")
    )
    |> to_string()
  end

  defp experiments_env do
    Application.get_env(:cripto_trader, :experiments, [])
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(_value, default), do: default
end
