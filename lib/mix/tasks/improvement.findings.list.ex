defmodule Mix.Tasks.Improvement.Findings.List do
  use Mix.Task

  alias CriptoTrader.Improvement.KnowledgeBase

  @shortdoc "List stored improvement findings"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, switches: [limit: :integer])

    case KnowledgeBase.list() do
      {:ok, findings} ->
        limit = Keyword.get(opts, :limit)

        findings
        |> maybe_take_last(limit)
        |> Enum.each(fn finding ->
          Mix.shell().info(
            "#{finding["id"]} task=#{finding["task_id"]} title=#{finding["title"]} tags=#{Enum.join(finding["tags"], ",")}"
          )
        end)

      {:error, reason} ->
        Mix.raise("Failed to read findings: #{inspect(reason)}")
    end
  end

  defp maybe_take_last(findings, nil), do: findings

  defp maybe_take_last(findings, limit) when is_integer(limit) and limit > 0 do
    findings
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  defp maybe_take_last(findings, _limit), do: findings
end
