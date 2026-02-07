defmodule Mix.Tasks.Improvement.Loop.Run do
  use Mix.Task

  alias CriptoTrader.Improvement.Loop

  @shortdoc "Run one improvement loop iteration"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, switches: [max: :integer])

    case Loop.run_once(max_tasks: Keyword.get(opts, :max, 5)) do
      {:ok, report} ->
        Mix.shell().info("Processed=#{report.processed_count} Errors=#{report.error_count}")

        Enum.each(report.processed, fn item ->
          Mix.shell().info(
            "task=#{item.task_id} type=#{item.task_type} status=#{item.status} finding=#{item.finding_id}"
          )
        end)

      {:error, reason} ->
        Mix.raise("Improvement loop failed: #{inspect(reason)}")
    end
  end
end
