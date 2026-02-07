defmodule CriptoTrader.Improvement.RequirementsTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Improvement.Requirements

  test "extracts acceptance criteria as indexed ids" do
    path =
      Path.join(System.tmp_dir!(), "requirements_parser_#{System.unique_integer([:positive])}.md")

    File.write!(
      path,
      """
      # Header

      ## Acceptance Criteria
      - First thing
      - Second thing

      ## Next Section
      - Ignored item
      """
    )

    assert {:ok, criteria} = Requirements.acceptance_criteria(path)

    assert criteria == [
             %{"id" => "ac-1", "description" => "First thing"},
             %{"id" => "ac-2", "description" => "Second thing"}
           ]
  end
end
