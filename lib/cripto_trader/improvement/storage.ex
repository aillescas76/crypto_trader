defmodule CriptoTrader.Improvement.Storage do
  @moduledoc false

  @spec read_json(String.t(), term()) :: {:ok, term()} | {:error, term()}
  def read_json(path, default) do
    case File.read(path) do
      {:ok, contents} -> decode_json(contents)
      {:error, :enoent} -> {:ok, default}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_json(String.t(), term()) :: :ok | {:error, term()}
  def write_json(path, data) do
    with :ok <- ensure_parent(path),
         {:ok, encoded} <- Jason.encode(data, pretty: true),
         :ok <- File.write(path, encoded <> "\n") do
      :ok
    end
  end

  @spec ensure_parent(String.t()) :: :ok | {:error, term()}
  def ensure_parent(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp decode_json(contents) do
    case Jason.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, reason}
    end
  end
end
