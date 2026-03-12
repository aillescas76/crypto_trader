defmodule Mix.Tasks.Experiments.Status do
  use Mix.Task

  alias CriptoTrader.Experiments.State

  @shortdoc "Show experiment status table"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start", [])

    case State.list_experiments() do
      {:ok, []} ->
        Mix.shell().info("No experiments found.")

      {:ok, experiments} ->
        print_table(experiments)

      {:error, reason} ->
        Mix.raise("Failed to load experiments: #{inspect(reason)}")
    end
  end

  defp print_table(experiments) do
    header = ["ID", "Strategy", "Status", "Verdict", "Train PnL%", "Val PnL%", "Queued"]

    rows =
      Enum.map(experiments, fn exp ->
        strategy = exp |> Map.get("strategy_module", "") |> short_module()
        status = Map.get(exp, "status", "?")
        verdict = format_verdict(Map.get(exp, "verdict"))
        train_pnl = format_pnl(Map.get(exp, "training_result"))
        val_pnl = format_pnl(Map.get(exp, "validation_result"))
        queued = Map.get(exp, "queued_at", "") |> short_time()

        [Map.get(exp, "id", "?"), strategy, status, verdict, train_pnl, val_pnl, queued]
      end)

    all_rows = [header | rows]
    col_widths = column_widths(all_rows)

    separator = Enum.map_join(col_widths, "-+-", fn w -> String.duplicate("-", w) end)

    Mix.shell().info(format_row(header, col_widths))
    Mix.shell().info(separator)

    Enum.each(rows, fn row ->
      Mix.shell().info(format_row(row, col_widths))
    end)
  end

  defp format_row(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map_join(" | ", fn {cell, w} -> String.pad_trailing(cell, w) end)
  end

  defp column_widths(rows) do
    rows
    |> Enum.zip_with(& &1)
    |> Enum.map(fn col -> col |> Enum.map(&String.length/1) |> Enum.max() end)
  end

  defp short_module(module_str) do
    module_str
    |> String.split(".")
    |> List.last()
    |> Kernel.||("?")
  end

  defp format_verdict(%{"verdict" => v}), do: verdict_badge(v)
  defp format_verdict(%{verdict: v}), do: verdict_badge(v)
  defp format_verdict(_), do: "-"

  defp verdict_badge("pass"), do: "PASS"
  defp verdict_badge(:pass), do: "PASS"
  defp verdict_badge("fail"), do: "FAIL"
  defp verdict_badge(:fail), do: "FAIL"
  defp verdict_badge(_), do: "-"

  defp format_pnl(nil), do: "-"
  defp format_pnl(%{"pnl_pct" => pct}) when is_number(pct), do: "#{Float.round(pct * 1.0, 2)}%"
  defp format_pnl(%{pnl_pct: pct}) when is_number(pct), do: "#{Float.round(pct * 1.0, 2)}%"
  defp format_pnl(_), do: "-"

  defp short_time(""), do: "-"
  defp short_time(iso) when is_binary(iso), do: String.slice(iso, 0, 16)
  defp short_time(_), do: "-"
end
