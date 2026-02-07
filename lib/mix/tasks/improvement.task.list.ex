defmodule Mix.Tasks.Improvement.Task.List do
  use Mix.Task

  alias CriptoTrader.Improvement.Tasks

  @shortdoc "List improvement tasks"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, switches: [status: :string, type: :string])

    case Tasks.list(status: Keyword.get(opts, :status), type: Keyword.get(opts, :type)) do
      {:ok, tasks} ->
        Enum.each(tasks, fn task ->
          Mix.shell().info(
            "##{task["id"]} [#{task["status"]}] #{task["type"]} #{task["title"]} priority=#{task["priority"]}"
          )
        end)

      {:error, reason} ->
        Mix.raise("Failed to list tasks: #{inspect(reason)}")
    end
  end
end
