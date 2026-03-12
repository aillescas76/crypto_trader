defmodule CriptoTrader.Experiments.Metrics do
  @moduledoc false

  # Candles per year by interval
  @periods_per_year %{
    "15m" => 35_040,
    "1h" => 8_760,
    "4h" => 2_190,
    "1d" => 365
  }
  @default_periods_per_year 35_040

  @spec sharpe_ratio([map()], String.t()) :: float()
  def sharpe_ratio(equity_curve, interval) when is_list(equity_curve) and length(equity_curve) > 1 do
    returns = period_returns(equity_curve)

    if Enum.empty?(returns) do
      0.0
    else
      n = length(returns)
      mean = Enum.sum(returns) / n
      variance = Enum.sum(Enum.map(returns, fn r -> (r - mean) * (r - mean) end)) / n
      std_dev = :math.sqrt(variance)

      if std_dev < 1.0e-10 do
        0.0
      else
        periods = Map.get(@periods_per_year, interval, @default_periods_per_year)
        annualized_sharpe = mean / std_dev * :math.sqrt(periods)
        Float.round(annualized_sharpe, 6)
      end
    end
  end

  def sharpe_ratio(_equity_curve, _interval), do: 0.0

  @spec enrich_result(map(), [map()], String.t()) :: map()
  def enrich_result(runner_result, equity_curve, interval) do
    summary = Map.get(runner_result, :summary, %{})
    initial_balance = runner_result |> Map.get(:summary, %{}) |> Map.get(:initial_balance, 10_000.0)

    # runner summary has pnl (absolute), not pnl_pct — compute it
    pnl = Map.get(summary, :pnl, 0.0)
    pnl_pct = if initial_balance > 0, do: pnl / initial_balance * 100.0, else: 0.0

    sharpe = sharpe_ratio(equity_curve, interval)
    max_dd = Map.get(summary, :max_drawdown_pct, 0.0) * 100.0

    %{
      pnl_pct: Float.round(pnl_pct, 4),
      pnl: Float.round(pnl, 4),
      sharpe: sharpe,
      max_drawdown_pct: Float.round(max_dd, 4),
      win_rate: Float.round(Map.get(summary, :win_rate, 0.0) * 100.0, 4),
      trades: Map.get(summary, :trades, 0),
      closed_trades: Map.get(summary, :closed_trades, 0)
    }
  end

  defp period_returns(equity_curve) do
    equity_curve
    |> Enum.sort_by(& &1.open_time)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [prev, curr] ->
      if prev.equity > 0, do: (curr.equity - prev.equity) / prev.equity, else: 0.0
    end)
  end
end
