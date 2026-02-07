defmodule CriptoTrader.Improvement.Codex do
  @moduledoc false

  alias CriptoTrader.Improvement.Config

  @max_output_chars 8_000

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term(), map()}
  def run(prompt, opts \\ []) when is_binary(prompt) do
    cmd = Keyword.get(opts, :cmd, Config.codex_cmd())
    args = Keyword.get(opts, :args, Config.codex_args())
    resolved_args = resolve_args(args, prompt)
    timeout = Keyword.get(opts, :timeout_ms, Config.codex_timeout_ms())
    cwd = Keyword.get(opts, :cd, File.cwd!())

    started_at = now_iso()
    started_mono = System.monotonic_time(:millisecond)

    case execute_with_timeout(cmd, resolved_args, cwd, timeout) do
      {:ok, {output, status}} ->
        finished_at = now_iso()

        result =
          %{
            invoked: true,
            command: cmd,
            args: resolved_args,
            started_at: started_at,
            finished_at: finished_at,
            duration_ms: System.monotonic_time(:millisecond) - started_mono,
            exit_status: status,
            output_tail: tail(output),
            output_size: byte_size(output)
          }

        if status == 0 do
          {:ok, result}
        else
          {:error, :codex_failed, result}
        end

      {:error, reason} ->
        result =
          %{
            invoked: true,
            command: cmd,
            args: resolved_args,
            started_at: started_at,
            finished_at: now_iso(),
            duration_ms: System.monotonic_time(:millisecond) - started_mono,
            exit_status: nil,
            output_tail: inspect(reason),
            output_size: 0
          }

        {:error, reason, result}
    end
  end

  defp tail(output) when is_binary(output) and byte_size(output) > @max_output_chars do
    binary_part(output, byte_size(output) - @max_output_chars, @max_output_chars)
  end

  defp tail(output), do: output

  defp execute_with_timeout(cmd, args, cwd, timeout) do
    task =
      Task.async(fn ->
        try do
          {:ok,
           System.cmd(cmd, args,
             cd: cwd,
             stderr_to_stdout: true,
             env: [{"NO_COLOR", "1"}]
           )}
        rescue
          error in ErlangError -> {:error, error.original}
        catch
          :exit, reason -> {:error, reason}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp resolve_args(args, prompt) do
    if Enum.any?(args, &(&1 == "-")) do
      Enum.map(args, fn
        "-" -> prompt
        arg -> arg
      end)
    else
      args ++ [prompt]
    end
  end

  defp now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
