defmodule Mix.Tasks.Experiments.Context.Maintain do
  use Mix.Task

  alias CriptoTrader.Experiments.Config
  alias CriptoTrader.Improvement.Storage

  @shortdoc "Maintain experiment context budget (archive dead-end findings, report sizes)"

  @moduledoc """
  Keeps the knowledge base compact so it fits in Claude's context window.

  ## What it does

  1. **Budget report** — shows current sizes of all files loaded per /experiment-loop session
  2. **Archive dead-end findings** — moves findings for failed experiments with no active
     investigation from findings.json → findings_archive.json (atomic write)
  3. **Learnings file check** — detects if old-format iteration blocks have been appended
     to the compact learnings memory file and warns

  ## Usage

      mix experiments.context.maintain              # interactive (asks before writing)
      mix experiments.context.maintain --dry-run    # show plan, no writes
      mix experiments.context.maintain --yes        # skip confirmation

  ## Conflict safety

  Findings archival only removes entries for completed experiments with no active
  investigation — the running loop never writes findings for those experiments. All file
  writes use atomic rename (temp → dest on the same filesystem).
  """

  @memory_dir_suffix "memory"
  @learnings_file "experiment-loop-learnings.md"
  @findings_archive_file "findings_archive.json"

  # Investigations in these statuses are considered "active" — their findings are kept
  @active_statuses ["active"]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, switches: [dry_run: :boolean, yes: :boolean])

    dry_run? = Keyword.get(opts, :dry_run, false)
    yes? = Keyword.get(opts, :yes, false)

    Mix.Task.run("app.start", [])

    shell = Mix.shell()

    shell.info("")
    shell.info("=== Experiment Context Maintenance ===")
    shell.info("")

    # Load state
    {:ok, experiments} = Storage.read_json(Config.experiments_file(), [])
    {:ok, findings} = Storage.read_json(Config.findings_file(), [])
    {:ok, investigations} = Storage.read_json(Config.investigations_file(), [])
    {:ok, principles} = Storage.read_json(Config.principles_file(), [])
    {:ok, hypotheses} = Storage.read_json(Config.hypotheses_file(), [])

    active_inv_ids =
      investigations
      |> Enum.filter(&(Map.get(&1, "status") in @active_statuses))
      |> Enum.map(&Map.get(&1, "id"))
      |> MapSet.new()

    # ── 1. Budget report ──────────────────────────────────────────────────────
    print_budget_report(shell, findings, experiments, principles, hypotheses)

    # ── 2. Findings archival ──────────────────────────────────────────────────
    exp_map = Map.new(experiments, &{Map.get(&1, "id"), &1})

    {keep, to_archive} =
      Enum.split_with(findings, fn finding ->
        exp_id = Map.get(finding, "experiment_id", "")
        exp = Map.get(exp_map, exp_id, %{})
        inv_id = Map.get(exp, "investigation_id")
        verdict = get_in(exp, ["verdict", "verdict"])

        # Keep if: experiment is in an active investigation, or verdict is pass
        verdict == "pass" or (inv_id != nil and inv_id in active_inv_ids)
      end)

    print_findings_plan(shell, keep, to_archive)

    if to_archive != [] do
      if confirm?(shell, dry_run?, yes?, "Archive #{length(to_archive)} dead-end finding(s)?") do
        do_archive_findings(shell, Config.findings_file(), keep, to_archive, dry_run?)
      end
    end

    # ── 3. Learnings file check ────────────────────────────────────────────────
    print_learnings_check(shell)

    shell.info("")
    shell.info("Done.")
  end

  # ── Budget report ─────────────────────────────────────────────────────────────

  defp print_budget_report(shell, findings, experiments, principles, hypotheses) do
    shell.info("── Context budget ───────────────────────────────────────────")
    shell.info("")

    files = [
      {"findings.json", Config.findings_file()},
      {"experiments.json", Config.experiments_file()},
      {"principles.json", Config.principles_file()},
      {"hypotheses.json", Config.hypotheses_file()},
      {"investigations.json", Config.investigations_file()}
    ]

    total_json =
      Enum.reduce(files, 0, fn {label, path}, acc ->
        size = file_size_kb(path)
        shell.info("  #{String.pad_trailing(label, 22)} #{format_kb(size)}")
        acc + size
      end)

    learnings_path = learnings_file_path()
    learnings_kb = file_size_kb(learnings_path)
    memory_md_kb = file_size_kb(memory_md_path())

    shell.info("  #{String.pad_trailing("experiment-loop-learnings.md", 22)} #{format_kb(learnings_kb)}")
    shell.info("  #{String.pad_trailing("MEMORY.md", 22)} #{format_kb(memory_md_kb)}")
    shell.info("")

    total_kb = total_json + learnings_kb + memory_md_kb
    # Rough estimate: 200K tokens × 4 chars ≈ 800KB
    budget_kb = 800
    pct = Float.round(total_kb / budget_kb * 100, 1)

    shell.info(
      "  Total initial load: #{format_kb(total_kb)} / ~#{budget_kb}KB token budget (#{pct}%)"
    )

    shell.info("")
    shell.info("  Entries — experiments: #{length(experiments)} | findings: #{length(findings)} | principles: #{length(principles)} | hypotheses: #{length(hypotheses)}")
    shell.info("")
  end

  # ── Findings archival ─────────────────────────────────────────────────────────

  defp print_findings_plan(shell, keep, to_archive) do
    shell.info("── Findings ─────────────────────────────────────────────────")
    shell.info("")
    shell.info("  Keep:    #{length(keep)} (active investigations or passed)")
    shell.info("  Archive: #{length(to_archive)} (dead-end / no active investigation)")

    if to_archive != [] do
      shell.info("")
      Enum.each(to_archive, fn f ->
        shell.info("    - #{String.slice(Map.get(f, "title", ""), 0, 70)}")
      end)
    end

    shell.info("")
  end

  defp do_archive_findings(shell, findings_path, keep, to_archive, dry_run?) do
    archive_path = Path.join(Path.dirname(findings_path), @findings_archive_file)

    if dry_run? do
      shell.info("  [dry-run] Would write #{findings_path} (#{length(keep)} entries)")
      shell.info("  [dry-run] Would append #{length(to_archive)} entries to #{archive_path}")
    else
      # Load existing archive (don't lose prior archival runs)
      {:ok, existing_archive} = Storage.read_json(archive_path, [])
      new_archive = existing_archive ++ to_archive

      # Atomic write: temp file then rename (both on same filesystem)
      with :ok <- atomic_write_json(archive_path, new_archive),
           :ok <- atomic_write_json(findings_path, keep) do
        shell.info("  ✓ findings.json → #{length(keep)} entries")
        shell.info("  ✓ findings_archive.json → #{length(new_archive)} total entries")
      else
        {:error, reason} ->
          Mix.raise("Failed to archive findings: #{inspect(reason)}")
      end
    end

    shell.info("")
  end

  # ── Learnings file check ──────────────────────────────────────────────────────

  defp print_learnings_check(shell) do
    shell.info("── Learnings memory file ────────────────────────────────────")
    shell.info("")

    path = learnings_file_path()
    size_kb = file_size_kb(path)

    case File.read(path) do
      {:error, :enoent} ->
        shell.info("  File not found: #{path}")

      {:ok, content} ->
        iter_count =
          ~r/^## Iteration \d+/m
          |> Regex.scan(content)
          |> length()

        shell.info("  Size: #{format_kb(size_kb)}")

        cond do
          iter_count > 0 and size_kb > 15 ->
            shell.info("  ⚠  #{iter_count} iteration block(s) detected — file has grown past threshold")
            shell.info("     Trim manually: archive old blocks to memory/archive/ and rewrite")
            shell.info("     the compact summary. The experiment loop cannot do this automatically.")

          size_kb > 15 ->
            shell.info("  ⚠  File is #{format_kb(size_kb)} — above 15KB threshold")
            shell.info("     Consider reviewing for verbose content that can be condensed")

          true ->
            shell.info("  ✓ Within budget (#{iter_count} iteration block(s))")
        end
    end

    shell.info("")
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp atomic_write_json(path, data) do
    tmp = path <> ".tmp"

    with :ok <- Storage.ensure_parent(path),
         {:ok, encoded} <- Jason.encode(data, pretty: true),
         :ok <- File.write(tmp, encoded <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      err ->
        File.rm(tmp)
        err
    end
  end

  defp confirm?(shell, dry_run?, yes?, prompt) do
    cond do
      dry_run? -> false
      yes? -> true
      true -> shell.yes?(prompt)
    end
  end

  defp file_size_kb(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size / 1024
      _ -> 0.0
    end
  end

  defp format_kb(kb) when kb >= 10, do: "#{round(kb)}KB"
  defp format_kb(kb), do: "#{Float.round(kb * 1.0, 1)}KB"

  defp learnings_file_path do
    project_dir = File.cwd!()

    encoded =
      project_dir
      |> String.replace("/", "-")
      |> String.replace("_", "-")
      |> String.trim_leading("-")

    home = System.user_home!()

    Path.join([
      home,
      ".claude",
      "projects",
      "-#{encoded}",
      @memory_dir_suffix,
      @learnings_file
    ])
  end

  defp memory_md_path do
    Path.join(Path.dirname(learnings_file_path()), "MEMORY.md")
  end
end
