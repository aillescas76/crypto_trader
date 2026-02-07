defmodule CriptoTrader.Improvement.Requirements do
  @moduledoc false

  @acceptance_header "## Acceptance Criteria"

  @spec acceptance_criteria(String.t()) :: {:ok, list(map())} | {:error, term()}
  def acceptance_criteria(path \\ "docs/requirements.md") do
    with {:ok, content} <- File.read(path),
         {:ok, section} <- acceptance_section(content) do
      criteria =
        section
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "- "))
        |> Enum.map(&String.replace_prefix(&1, "- ", ""))
        |> Enum.with_index(1)
        |> Enum.map(fn {description, index} ->
          %{
            "id" => "ac-#{index}",
            "description" => description
          }
        end)

      {:ok, criteria}
    end
  end

  defp acceptance_section(content) do
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &(&1 == @acceptance_header)) do
      nil ->
        {:error, :missing_acceptance_criteria}

      start_index ->
        section_lines =
          lines
          |> Enum.drop(start_index + 1)
          |> Enum.take_while(fn line ->
            trimmed = String.trim(line)
            trimmed == "" or not String.starts_with?(trimmed, "## ")
          end)

        {:ok, Enum.join(section_lines, "\n")}
    end
  end
end
