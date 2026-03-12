#!/usr/bin/env bash
# Test suite for guard_project_boundary.sh
# Run as:  bash .claude/hooks/test_hook.sh

set -euo pipefail

PROJECT="/home/aic/code/cripto_trader"
HOOK="$PROJECT/.claude/hooks/guard_project_boundary.sh"
PASS=0; FAIL=0

run_test() {
  local desc="$1" input="$2"
  local out decision
  out=$(echo "$input" | bash "$HOOK" 2>/dev/null || true)
  decision=$(echo "$out" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); \
        print(d.get('hookSpecificOutput',{}).get('permissionDecision','allow'))" \
    2>/dev/null || echo "allow")
  local expected="${desc%% *}"
  if { [[ "$expected" == "ALLOW" && "$decision" != "deny" ]] \
    || [[ "$expected" == "BLOCK" && "$decision" == "deny"  ]]; }; then
    printf "  [PASS] %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  [FAIL] %s  (got: %s)\n" "$desc" "$decision"; FAIL=$((FAIL+1))
  fi
}

w()  { echo "{\"tool_name\":\"Write\",\"cwd\":\"$PROJECT\",\"tool_input\":{\"file_path\":\"$1\",\"content\":\"x\"}}"; }
e()  { echo "{\"tool_name\":\"Edit\", \"cwd\":\"$PROJECT\",\"tool_input\":{\"file_path\":\"$1\",\"old_string\":\"a\",\"new_string\":\"b\"}}"; }
b()  { echo "{\"tool_name\":\"Bash\", \"cwd\":\"$PROJECT\",\"tool_input\":{\"command\":\"$1\"}}"; }

ETC_PASSWD="/etc/passwd"
ETC_CRON="/etc/cron.d/job"
ETC_HOSTS="/etc/hosts"
USR_BIN="/usr/local/bin/evil"
OTHER_HOME="$HOME/other_project"
SECRET="$HOME/sec.txt"

echo "=== Write / Edit ==="
run_test "ALLOW write inside project"  "$(w "$PROJECT/lib/foo.ex")"
run_test "BLOCK write /etc/passwd"     "$(w "$ETC_PASSWD")"
run_test "BLOCK write ~/.bashrc"       "$(w "$HOME/.bashrc")"
run_test "ALLOW write /tmp"            "$(w "/tmp/analysis.py")"
run_test "ALLOW write /dev/null"       "$(w "/dev/null")"
run_test "ALLOW project memory"        "$(w "$HOME/.claude/projects/foo/memory/bar.md")"
run_test "ALLOW edit inside project"   "$(e "$PROJECT/CLAUDE.md")"
run_test "BLOCK edit outside project"  "$(e "$USR_BIN")"

echo ""
echo "=== Bash ==="
run_test "ALLOW mix compile"              "$(b "mix compile")"
run_test "ALLOW redirect inside project"  "$(b "echo x > $PROJECT/priv/test.txt")"
run_test "BLOCK redirect /etc"            "$(b "echo evil > $ETC_CRON")"
run_test "ALLOW redirect /tmp"            "$(b "echo x > /tmp/out.txt")"
run_test "ALLOW redirect /dev/null"       "$(b "mix test 2>/dev/null")"
run_test "BLOCK rm outside project"       "$(b "rm -rf $OTHER_HOME")"
run_test "ALLOW cp into project"          "$(b "cp foo.ex $PROJECT/lib/bar.ex")"
run_test "BLOCK cp outside project"       "$(b "cp sec.txt $SECRET")"
run_test "ALLOW mv relative paths"        "$(b "mv lib/foo.ex lib/bar.ex")"
run_test "BLOCK tee /etc"                 "$(b "cat x | tee $ETC_HOSTS")"
run_test "ALLOW tee inside project"       "$(b "tee $PROJECT/priv/out.json")"
run_test "ALLOW git and mix"              "$(b "git status && mix test")"
run_test "BLOCK sed -i /etc"              "$(b "sed -i s/foo/bar/ $ETC_HOSTS")"
run_test "ALLOW sed -i inside project"    "$(b "sed -i s/foo/bar/ $PROJECT/README.md")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
