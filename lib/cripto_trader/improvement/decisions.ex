defmodule CriptoTrader.Improvement.Decisions do
  @moduledoc false

  alias CriptoTrader.Improvement.Config

  @spec record(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def record(attrs) when is_list(attrs), do: record(Enum.into(attrs, %{}))

  def record(attrs) when is_map(attrs) do
    with :ok <- File.mkdir_p(Config.adr_dir()),
         {:ok, entry} <- create_entry(attrs),
         :ok <- File.write(entry.path, render_adr(entry)),
         :ok <- rebuild_index() do
      {:ok, %{id: entry.id, path: entry.path}}
    end
  end

  @spec rebuild_index() :: :ok | {:error, term()}
  def rebuild_index do
    with :ok <- File.mkdir_p(Config.adr_dir()),
         {:ok, entries} <- list_entries() do
      index_path = Path.join(Config.adr_dir(), "README.md")
      File.write(index_path, render_index(entries))
    end
  end

  @spec list_entries() :: {:ok, list(map())} | {:error, term()}
  def list_entries do
    pattern = Path.join(Config.adr_dir(), "[0-9][0-9][0-9][0-9]-*.md")

    entries =
      pattern
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&entry_from_path/1)

    {:ok, entries}
  end

  defp create_entry(attrs) do
    next_id = next_id()
    id = pad(next_id)

    title = required_string(attrs, "title", "Untitled Decision")
    slug = slugify(title)
    status = required_string(attrs, "status", "accepted")
    date = Date.utc_today() |> Date.to_iso8601()

    entry = %{
      id: id,
      title: title,
      status: status,
      date: date,
      context: optional_string(attrs, "context") || "TBD",
      decision: optional_string(attrs, "decision") || "TBD",
      consequences: optional_string(attrs, "consequences") || "TBD",
      filename: "#{id}-#{slug}.md",
      path: Path.join(Config.adr_dir(), "#{id}-#{slug}.md")
    }

    {:ok, entry}
  end

  defp next_id do
    case list_entries() do
      {:ok, []} ->
        1

      {:ok, entries} ->
        entries
        |> Enum.map(fn entry -> entry.id end)
        |> Enum.map(&String.to_integer/1)
        |> Enum.max()
        |> Kernel.+(1)
    end
  end

  defp entry_from_path(path) do
    filename = Path.basename(path)
    [id_part | slug_parts] = String.split(filename, "-", parts: 2)
    slug = slug_parts |> List.first("") |> String.replace_suffix(".md", "")

    {title, status} = parse_title_and_status(path)

    %{
      id: id_part,
      filename: filename,
      path: path,
      title: title || humanize_slug(slug),
      status: status || "unknown"
    }
  end

  defp parse_title_and_status(path) do
    case File.read(path) do
      {:ok, content} ->
        title =
          content
          |> String.split("\n")
          |> Enum.find_value(fn line ->
            if String.starts_with?(line, "# ADR "),
              do: String.replace_prefix(line, "# ADR ", ""),
              else: nil
          end)

        status =
          content
          |> String.split("\n")
          |> Enum.find_value(fn line ->
            if String.starts_with?(line, "Status: "),
              do: String.replace_prefix(line, "Status: ", ""),
              else: nil
          end)

        {title, status}

      {:error, _reason} ->
        {nil, nil}
    end
  end

  defp render_adr(entry) do
    """
    # ADR #{entry.title}

    Date: #{entry.date}
    Status: #{entry.status}
    ID: #{entry.id}

    ## Context
    #{entry.context}

    ## Decision
    #{entry.decision}

    ## Consequences
    #{entry.consequences}
    """
    |> String.trim_leading()
  end

  defp render_index(entries) do
    rows =
      entries
      |> Enum.map(fn entry ->
        "| #{entry.id} | #{entry.title} | #{entry.status} | #{entry.filename} |"
      end)
      |> Enum.join("\n")

    header =
      """
      # Architecture Decision Records

      | ID | Title | Status | File |
      | --- | --- | --- | --- |
      """
      |> String.trim_leading()

    [header, rows]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(4, "0")

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "decision"
      slug -> slug
    end
  end

  defp humanize_slug(slug) do
    slug
    |> String.split("-")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp required_string(attrs, key, default) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp optional_string(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) -> String.trim(value)
      nil -> nil
      value -> to_string(value)
    end
  end
end
