#!/usr/bin/env bash
# guard_project_boundary.sh
#
# PreToolUse hook — blocks any file write/edit/delete that targets a path
# outside the current project directory.
#
# Covered tools:
#   Write, Edit, NotebookEdit  → check file_path / notebook_path
#   Bash                       → scan command for out-of-project write patterns
#
# Always-allowed exceptions:
#   /tmp/*                                 temp analysis scripts
#   ~/.claude/projects/*/memory/*          Claude project memory files
#
# Returns JSON permissionDecision "deny" on violations; exits 0 otherwise.

set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT"       | jq -r '.cwd       // empty')
PROJECT_DIR="${CWD:-$(pwd)}"
PROJECT_DIR="${PROJECT_DIR%/}"   # strip trailing slash

# ── deny helper ───────────────────────────────────────────────────────────────

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName:             "PreToolUse",
      permissionDecision:        "deny",
      permissionDecisionReason:  $reason
    }
  }'
  exit 0
}

# ── path allowlist check ──────────────────────────────────────────────────────

is_allowed_path() {
  local path="$1"
  [[ -z "$path" ]]                                        && return 0
  path="${path/#\~/$HOME}"
  [[ "$path" == "$PROJECT_DIR"  || "$path" == "$PROJECT_DIR/"* ]] && return 0
  [[ "$path" == /tmp            || "$path" == /tmp/*            ]] && return 0
  [[ "$path" == /dev/null       || "$path" == /dev/stderr       ]] && return 0
  [[ "$path" == "$HOME"/.claude/projects/*/memory              ]] && return 0
  [[ "$path" == "$HOME"/.claude/projects/*/memory/*            ]] && return 0
  return 1
}

# ── Write / Edit ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
  if ! is_allowed_path "$FILE_PATH"; then
    deny "[$TOOL_NAME] Path outside project directory.
  Attempted : $FILE_PATH
  Allowed   : $PROJECT_DIR/**, /tmp/**, ~/.claude/projects/*/memory/**"
  fi
fi

# ── NotebookEdit ──────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "NotebookEdit" ]]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.notebook_path // .tool_input.file_path // empty')
  if ! is_allowed_path "$FILE_PATH"; then
    deny "[NotebookEdit] Path outside project directory.
  Attempted : $FILE_PATH
  Allowed   : $PROJECT_DIR/**, /tmp/**, ~/.claude/projects/*/memory/**"
  fi
fi

# ── Bash ──────────────────────────────────────────────────────────────────────

if [[ "$TOOL_NAME" == "Bash" ]]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

  # Python does the heavy lifting: reliable regex over raw bash string parsing.
  # CMD, PROJECT_DIR and HOME are passed via environment variables.
  RESULT=$(CMD="$CMD" PROJECT_DIR="$PROJECT_DIR" HOME_DIR="$HOME" python3 - <<'PYEOF'
import sys, re, os

project_dir = os.environ["PROJECT_DIR"].rstrip("/")
home_dir    = os.environ["HOME_DIR"].rstrip("/")
cmd         = os.environ["CMD"]

def is_allowed(path):
    if not path:
        return True
    path = path.replace("~/", home_dir + "/").replace("~", home_dir)
    if path.startswith("/"):
        path = os.path.normpath(path)
    for prefix in [
        project_dir, project_dir + "/",
        "/tmp",      "/tmp/",
        "/dev/null", "/dev/stderr",
        home_dir + "/.claude/projects/",
    ]:
        if path == prefix.rstrip("/") or path.startswith(prefix.rstrip("/") + "/"):
            return True
    return False

violations = []

# Shell redirections: > /path  or  >> /path
for m in re.finditer(r'(?<![<>])>>?\s*((?:/|~/)[^\s;|&\'">\n]+)', cmd):
    path = m.group(1)
    if not is_allowed(path):
        violations.append("redirect → " + path)

# tee [options] /path
for m in re.finditer(r'\btee\b(?:\s+-\S+)*\s+((?:/|~/)[^\s;|&\'">\n]+)', cmd):
    path = m.group(1)
    if not is_allowed(path):
        violations.append("tee → " + path)

# cp src /dest
for m in re.finditer(r'\bcp\b(?:\s+-\S+)*\s+\S+\s+((?:/|~/)[^\s;|&\'">\n]+)', cmd):
    dest = m.group(1)
    if not is_allowed(dest):
        violations.append("cp → " + dest)

# mv src /dest
for m in re.finditer(r'\bmv\b(?:\s+-\S+)*\s+\S+\s+((?:/|~/)[^\s;|&\'">\n]+)', cmd):
    dest = m.group(1)
    if not is_allowed(dest):
        violations.append("mv → " + dest)

# rm [options] /path
for m in re.finditer(r'\brm\b(?:\s+-\S+)*\s+((?:/|~/)[^\s;|&\'">\n]+)', cmd):
    path = m.group(1)
    if not is_allowed(path):
        violations.append("rm " + path)

# sed -i ... /path
for m in re.finditer(
    r'\bsed\b(?:\s+\S+)*\s+-i\S*\s+(?:\'[^\']*\'|"[^"]*"|\S+)\s+((?:/|~/)[^\s;|&\'">\n]+)',
    cmd
):
    path = m.group(1)
    if not is_allowed(path):
        violations.append("sed -i → " + path)

if violations:
    print("VIOLATIONS:" + " | ".join(violations))
    sys.exit(1)

sys.exit(0)
PYEOF
  ) || true

  if [[ "$RESULT" == VIOLATIONS:* ]]; then
    DETAIL="${RESULT#VIOLATIONS:}"
    CMD_PREVIEW=$(printf '%s' "$CMD" | head -3)
    deny "[Bash] Write operations outside project directory detected.
  Violations : $DETAIL
  Project    : $PROJECT_DIR
  Allowed    : $PROJECT_DIR/**, /tmp/**, ~/.claude/projects/*/memory/**
  Command    : $CMD_PREVIEW"
  fi
fi

# All checks passed
exit 0
