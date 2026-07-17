#!/bin/bash
# Integration test for approval-listener.sh acknowledgement push-back.
# No framework: sources the listener (loop guarded), stubs the claude and
# notify binaries via env overrides, drives handle_line, asserts on the
# recorded notify calls. Run: bash tests/approval-listener.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="${SCRIPT_DIR}/../scripts/approval-listener.sh"

PASS=0; FAIL=0
ok()   { echo "  ok: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Build an isolated sandbox: temp agent dir + stub binaries.
setup() {
  TMP="$(mktemp -d)"
  export EA_AGENT_DIR="$TMP/agent"
  mkdir -p "$EA_AGENT_DIR/queue/drafts" "$EA_AGENT_DIR/queue/completed" "$EA_AGENT_DIR/state"

  # ntfy settings via env so resolve_ntfy_settings is satisfied (no real network).
  export EA_NTFY_SERVER="https://example.invalid"
  export EA_NTFY_TOPIC="ack-topic"
  export EA_NTFY_COMMAND_TOPIC="cmd-topic"
  export EA_NTFY_AUTH_TOKEN=""

  # Stub notifier: record each invocation's args, one line per call.
  export NOTIFY_LOG="$TMP/notify.log"
  : > "$NOTIFY_LOG"
  export NOTIFY_BIN="$TMP/fake-notify"
  cat > "$NOTIFY_BIN" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$NOTIFY_LOG"
exit 0
EOF
  chmod +x "$NOTIFY_BIN"

  # Stub claude: record args (to assert the chosen --max-budget-usd), and on success
  # empty drafts/ (simulating execute-item), else no-op.
  export CLAUDE_ARGS_LOG="$TMP/claude-args.log"
  : > "$CLAUDE_ARGS_LOG"
  export CLAUDE_BIN="$TMP/fake-claude"
  cat > "$CLAUDE_BIN" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAUDE_ARGS_LOG"
# FAKE_TICKET_RECONCILE simulates the real confined-worktree behavior: the run writes the
# completed/ record but CANNOT delete the drafts/ original, leaving a stub for the listener
# to reconcile. FAKE_SUCCEED simulates a clean move (drafts emptied). Neither => no-op.
if [ "${FAKE_TICKET_RECONCILE:-0}" = "1" ]; then
  mkdir -p "$EA_AGENT_DIR/queue/completed"
  for f in "$EA_AGENT_DIR"/queue/drafts/*.md; do cp "$f" "$EA_AGENT_DIR/queue/completed/"; done
  exit 0   # drafts/ left in place on purpose
fi
[ "${FAKE_SUCCEED:-0}" = "1" ] && rm -f "$EA_AGENT_DIR"/queue/drafts/*
exit 0
EOF
  chmod +x "$CLAUDE_BIN"

  # Source the listener with the loop guarded; provides log/push_ack/handle_line.
  # shellcheck disable=SC1090
  source "$LISTENER"
}

teardown() { rm -rf "$TMP"; unset FAKE_SUCCEED; }

# jq helper: emit a one-line ntfy "message" event.
msg_event() { jq -nc --arg id "$1" --arg m "$2" '{event:"message",id:$id,time:1,message:$m}'; }

# --- Case 1: valid approve, execute succeeds -> receipt + Done acks ---
test_success() {
  echo "test_success:"
  setup
  local item="20260716-000000-pr-review-abc.md"
  touch "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1   # export so the claude child process sees it
  handle_line "$(msg_event id-success "approve|$item")"

  local n; n="$(wc -l < "$NOTIFY_LOG")"
  [ "$n" -eq 2 ] && ok "sent 2 acks" || bad "expected 2 acks, got $n"
  grep -q "Received" "$NOTIFY_LOG" && grep -q "low" "$NOTIFY_LOG" \
    && ok "receipt ack (low) present" || bad "missing low receipt ack"
  grep -q "Done" "$NOTIFY_LOG" && grep -q "normal" "$NOTIFY_LOG" \
    && ok "outcome ack (normal, Done) present" || bad "missing normal Done ack"
  teardown
}

# --- Case 2: valid approve, execute leaves item in drafts -> Failed ack ---
test_failure() {
  echo "test_failure:"
  setup
  local item="20260716-000000-pr-review-def.md"
  touch "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=0   # export so the claude child process sees it
  handle_line "$(msg_event id-failure "approve|$item")"

  grep -q "Received" "$NOTIFY_LOG" \
    && ok "receipt ack present" || bad "missing receipt ack"
  grep -q "Failed" "$NOTIFY_LOG" && grep -q "urgent" "$NOTIFY_LOG" \
    && ok "outcome ack (urgent, Failed) present" || bad "missing urgent Failed ack"
  teardown
}

# --- Case 3: invalid decision -> no ack at all ---
test_invalid() {
  echo "test_invalid:"
  setup
  handle_line "$(msg_event id-invalid "bogus|whatever.md")"

  local n; n="$(wc -l < "$NOTIFY_LOG")"
  [ "$n" -eq 0 ] && ok "no ack for invalid message" || bad "expected 0 acks, got $n"
  grep -qF '"id-invalid"' "$EA_AGENT_DIR/state/ntfy-seen.yaml" \
    && ok "invalid message recorded as seen" || bad "invalid message not deduped"
  teardown
}

# Ticket-path helpers: a project config with a checkout path + build allowlist, and a
# fake `git` on PATH so worktree add/remove touch nothing real (they just mkdir the
# worktree dir so the confined `claude` run has a cwd).
write_ticket_config() {
  # $1 = "with-allowlist" | "no-allowlist"
  mkdir -p "$TMP/repo"
  {
    printf 'agent:\n  branch_prefix: "x"\n'
    printf 'projects:\n  wayfinder-api:\n    path: "%s"\n' "$TMP/repo"
    if [ "$1" = "with-allowlist" ]; then
      # Inline comments + quotes on purpose: real configs have them, and the reader must
      # strip them (a prior version leaked `bin/rails"  # ...` and failed the charset check).
      printf '    exec:\n      allowed_commands:\n        - "bin/rails"   # migrations, db:migrate\n        - "bundle"      # gem exec\n'
    fi
    printf '    github:\n      owner: "futuresinc"\n'
  } > "$EA_CONFIG_FILE"
}
install_fake_git() {
  export GIT_LOG="$TMP/git.log"; : > "$GIT_LOG"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/git" <<'EOF'
#!/bin/bash
printf 'git %s\n' "$*" >> "$GIT_LOG"
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[i]}" in
    symbolic-ref) echo "origin/main"; exit 0;;
    fetch) exit 0;;
    worktree)
      if [ "${args[i+1]}" = "add" ]; then
        for ((j=i+2;j<${#args[@]};j++)); do
          [ "${args[j]}" = "--detach" ] && { mkdir -p "${args[j+1]}"; break; }
        done
      fi
      exit 0;;
  esac
done
exit 0
EOF
  chmod +x "$TMP/bin/git"
  export PATH="$TMP/bin:$PATH"
}

# --- Case 4: approved ticket runs the CONFINED path (worktree + narrow allowlist) ---
test_ticket_confined_run() {
  echo "test_ticket_confined_run:"
  setup
  write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-1.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-ticket "approve|$item")"

  grep -qF -- "--max-budget-usd $TICKET_BUDGET_USD" "$CLAUDE_ARGS_LOG" \
    && ok "ticket uses ticket budget ($TICKET_BUDGET_USD)" \
    || bad "ticket budget not applied (args: $(cat "$CLAUDE_ARGS_LOG"))"
  grep -qF -- "Bash(bin/rails *)" "$CLAUDE_ARGS_LOG" && grep -qF -- "Bash(bundle *)" "$CLAUDE_ARGS_LOG" \
    && ok "narrow build allowlist expanded from config" \
    || bad "build allowlist missing (args: $(cat "$CLAUDE_ARGS_LOG"))"
  grep -qF -- "Bash(git *)" "$CLAUDE_ARGS_LOG" \
    && ok "git allowed for the coding session" || bad "git not allowed"
  grep -qF -- "Bash(spy *)" "$CLAUDE_ARGS_LOG" \
    && bad "spy leaked into the confined ticket allowlist" || ok "confined allowlist excludes spy/slite (not the generic path)"
  grep -q "worktree add" "$GIT_LOG" && grep -q "worktree remove" "$GIT_LOG" \
    && ok "worktree created and torn down" || bad "worktree lifecycle missing (git log: $(cat "$GIT_LOG"))"
  grep -q "Done" "$NOTIFY_LOG" && ok "Done ack after successful implementation" || bad "missing Done ack"
  teardown
}

# --- Case 4a: reconciliation — confined run wrote completed/ but left the drafts/ stub ---
test_ticket_reconciles_stub() {
  echo "test_ticket_reconciles_stub:"
  setup
  write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-9.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_TICKET_RECONCILE=1   # completed/ written, drafts/ deliberately left behind
  handle_line "$(msg_event id-reconcile "approve|$item")"

  [ -e "$EA_AGENT_DIR/queue/completed/$item" ] \
    && ok "completed/ record present" || bad "completed/ record missing"
  [ ! -e "$EA_AGENT_DIR/queue/drafts/$item" ] \
    && ok "listener reconciled away the stale drafts/ stub" || bad "drafts/ stub not reconciled"
  grep -q "Done" "$NOTIFY_LOG" && ! grep -q "Failed" "$NOTIFY_LOG" \
    && ok "Done ack sent (not a false Failed)" || bad "wrong ack (log: $(cat "$NOTIFY_LOG"))"
  unset FAKE_TICKET_RECONCILE
  teardown
}

# --- Case 4b: deny-by-default — a ticket for a project with no exec.allowed_commands ---
test_ticket_refused_without_allowlist() {
  echo "test_ticket_refused_without_allowlist:"
  setup
  write_ticket_config no-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-2.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1   # even if claude were called it would "succeed"; it must NOT be called
  handle_line "$(msg_event id-refuse "approve|$item")"

  [ ! -s "$CLAUDE_ARGS_LOG" ] \
    && ok "claude never launched without a build allowlist" \
    || bad "claude ran despite deny-by-default (args: $(cat "$CLAUDE_ARGS_LOG"))"
  grep -q "worktree add" "$GIT_LOG" 2>/dev/null \
    && bad "worktree created before the allowlist check" || ok "no worktree created (refused before setup)"
  [ -e "$EA_AGENT_DIR/queue/drafts/$item" ] \
    && ok "item left in drafts/ for the human to fix config" || bad "item wrongly left drafts/"
  grep -q "Failed" "$NOTIFY_LOG" && grep -q "urgent" "$NOTIFY_LOG" \
    && ok "urgent Failed ack sent" || bad "missing Failed ack"
  teardown
}

# --- Case 5: unknown/missing type falls back to the default budget ---
test_default_budget() {
  echo "test_default_budget:"
  setup
  local item="20260716-000000-pr-review-ghi.md"
  touch "$EA_AGENT_DIR/queue/drafts/$item"   # empty file -> no type frontmatter
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-default "approve|$item")"

  grep -qF -- "--max-budget-usd $DEFAULT_BUDGET_USD" "$CLAUDE_ARGS_LOG" \
    && ok "unknown type uses default budget ($DEFAULT_BUDGET_USD)" \
    || bad "default budget not applied (args: $(cat "$CLAUDE_ARGS_LOG"))"
  teardown
}

test_success
test_failure
test_invalid
test_ticket_confined_run
test_ticket_reconciles_stub
test_ticket_refused_without_allowlist
test_default_budget

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
