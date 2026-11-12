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
  mkdir -p "$EA_AGENT_DIR/queue/incoming" "$EA_AGENT_DIR/queue/drafts" "$EA_AGENT_DIR/queue/completed" "$EA_AGENT_DIR/state"

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
[ -n "${ORDER_LOG:-}" ] && echo "claude:$PWD" >> "$ORDER_LOG"
# QA generation run: detected by its prompt marker. It must NOT touch the ticket's drafts/ or
# completed/ records — it only drops a new qa-test-plan draft (when FAKE_QA_DRAFT=1).
# Investigation run: detected by its prompt marker. Writes the archive (when
# FAKE_INVESTIGATE_ARCHIVE=1) and the completed/ record, leaving the drafts/ stub for the
# listener to reconcile — the same shape the real confined run has.
if printf '%s' "$*" | grep -q "Investigate the engineer-agent ticket"; then
  if [ "${FAKE_INVESTIGATE_ARCHIVE:-0}" = "1" ]; then
    mkdir -p "$EA_AGENT_DIR/investigations"
    printf '## Findings\n' > "$EA_AGENT_DIR/investigations/ENG-1-20260820-120000.md"
  fi
  if [ "${FAKE_INVESTIGATE_COMPLETE:-0}" = "1" ]; then
    mkdir -p "$EA_AGENT_DIR/queue/completed"
    for f in "$EA_AGENT_DIR"/queue/drafts/*.md; do cp "$f" "$EA_AGENT_DIR/queue/completed/"; done
  fi
  exit 0
fi
if printf '%s' "$*" | grep -q "Generate a QA test plan"; then
  if [ "${FAKE_QA_DRAFT:-0}" = "1" ]; then
    printf 'type: qa-test-plan\n' > "$EA_AGENT_DIR/queue/drafts/20260716-000000-qa-test-plan-fake.md"
  fi
  # The real confined run cannot delete outside its worktree, so the incoming/ original it
  # was told to `mv` survives alongside the drafts/ copy it wrote. See the WIRE-2194 duplicate.
  if [ "${FAKE_QA_INCOMING_LEFTOVER:-0}" = "1" ]; then
    mkdir -p "$EA_AGENT_DIR/queue/incoming"
    printf 'type: qa-test-plan\nstatus: drafted\n' > "$EA_AGENT_DIR/queue/incoming/20260716-000000-qa-test-plan-fake.md"
  fi
  exit 0
fi
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
  # $1 = "with-allowlist" | "no-allowlist"; $2 = "with-qa" (optional) adds qa.base_url
  mkdir -p "$TMP/repo"
  {
    printf 'agent:\n  branch_prefix: "x"\n'
    printf 'projects:\n  wayfinder-api:\n    path: "%s"\n' "$TMP/repo"
    if [ "$1" = "with-allowlist" ]; then
      # Inline comments + quotes on purpose: real configs have them, and the reader must
      # strip them (a prior version leaked `bin/rails"  # ...` and failed the charset check).
      printf '    exec:\n      allowed_commands:\n        - "bin/rails"   # migrations, db:migrate\n        - "bundle"      # gem exec\n'
      [ -n "${EXEC_EXTRA:-}" ] && printf '%s\n' "$EXEC_EXTRA"
    fi
    printf '    github:\n      owner: "futuresinc"\n'
    if [ "${2:-}" = "with-qa" ]; then
      printf '    qa:\n      base_url: "http://localhost:3000"   # enables headless QA gen\n'
    fi
  } > "$EA_CONFIG_FILE"
}
# An investigation project: a real checkout path but deliberately NO exec.allowed_commands, since
# an investigation runs no build commands and must NOT be refused for lacking a build list.
# $1 = "with-transition" (optional) adds investigation.on_complete_status.
write_investigation_config() {
  mkdir -p "$TMP/repo"
  {
    printf 'agent:\n  branch_prefix: "x"\n'
    printf 'projects:\n  wayfinder-api:\n    path: "%s"\n' "$TMP/repo"
    printf '    github:\n      owner: "futuresinc"\n'
    if [ "${1:-}" = "with-transition" ]; then
      printf '    investigation:\n      on_complete_status: "Done"   # transition after commenting\n'
    fi
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
    # FAKE_REMOTE_HEAD: the remote's default branch, as `ls-remote --symref origin HEAD` reports it.
    ls-remote) [ -n "${FAKE_REMOTE_HEAD:-}" ] && printf 'ref: refs/heads/%s\tHEAD\n' "$FAKE_REMOTE_HEAD"; exit 0;;
    # FAKE_GIT_FETCH_FAIL simulates github being unreachable (observed: SSH banner timeout).
    fetch) [ "${FAKE_GIT_FETCH_FAIL:-0}" = "1" ] && exit 1; exit 0;;
    rev-parse) echo "deadbee"; exit 0;;
    worktree)
      if [ "${args[i+1]}" = "add" ]; then
        for ((j=i+2;j<${#args[@]};j++)); do
          if [ "${args[j]}" = "--detach" ]; then
            # FAKE_MISSING_REF: a ref this repo does not have (worktree add fails).
            [ -n "${FAKE_MISSING_REF:-}" ] && [ "${args[j+2]:-}" = "$FAKE_MISSING_REF" ] && exit 128
            mkdir -p "${args[j+1]}"; break
          fi
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
  local r
  for r in "Bash(git commit:*)" "Bash(${PLUGIN_ROOT}/scripts/confined-push.sh:*)" \
           "Bash(git checkout -b:*)" "Bash(gh pr create:*)" "Bash(gh auth status:*)" "Bash(gh pr view:*)"; do
    grep -qF -- "$r" "$CLAUDE_ARGS_LOG" && ok "coding session allows $r" || bad "coding session lacks $r"
  done
  # Broad prefixes re-grant `git -C /elsewhere`, `git -c alias.x=!cmd`, `gh api -X POST`, `gh pr merge`.
  # Raw push takes any refspec (HEAD:main --force); branch/stash/checkout act on refs the worktree
  # shares with the user's own checkout.
  for r in "Bash(git *)" "Bash(gh *)" "Bash(gh api" "Bash(gh pr merge" "Bash(git -" \
           "Bash(git push" "Bash(git fetch" "Bash(git branch" "Bash(git stash" "Bash(git checkout:*)" "Bash(git switch:*)"; do
    grep -qF -- "$r" "$CLAUDE_ARGS_LOG" && bad "confined allowlist grants $r" || ok "confined allowlist omits $r"
  done
  grep -qF -- "Bash(spy *)" "$CLAUDE_ARGS_LOG" \
    && bad "spy leaked into the confined ticket allowlist" || ok "confined allowlist excludes spy/slite (not the generic path)"
  grep -q "worktree add" "$GIT_LOG" && grep -q "worktree remove" "$GIT_LOG" \
    && ok "worktree created and torn down" || bad "worktree lifecycle missing (git log: $(cat "$GIT_LOG"))"
  grep -q "Done" "$NOTIFY_LOG" && ok "Done ack after successful implementation" || bad "missing Done ack"
  teardown
}

# --- Case 4b: the confined ticket run DISPATCHES through execute-item ---
# The sandbox (worktree + build allowlist) is this listener's job; deciding what approving a
# ticket means is execute-item's. run_ticket_implementation used to point the prompt straight at
# implement-ticket, which meant the interactive approval path had no implementation step at all.
# Pin the dispatch so it cannot silently revert to that.
test_ticket_dispatches_via_execute_item() {
  echo "test_ticket_dispatches_via_execute_item:"
  setup
  write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-2.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-ticket-dispatch "approve|$item")"

  grep -qF -- "skills/execute-item/SKILL.md" "$CLAUDE_ARGS_LOG" \
    && ok "ticket prompt dispatches through execute-item" \
    || bad "ticket prompt does not name execute-item (args: $(cat "$CLAUDE_ARGS_LOG"))"
  # execute-item delegates to implement-ticket only when the branch is missing, so the prompt
  # may still mention it — but never as the entry point that replaces execute-item.
  grep -qF -- "Follow skills/implement-ticket/SKILL.md" "$CLAUDE_ARGS_LOG" \
    && bad "ticket prompt still bypasses execute-item for implement-ticket" \
    || ok "implement-ticket is not the dispatcher"
  # Dispatch changed; the sandbox must not have.
  grep -qF -- "Bash(bin/rails *)" "$CLAUDE_ARGS_LOG" \
    && ok "sandbox build allowlist still applied" || bad "sandbox allowlist lost"
  grep -qF -- "Skill" "$CLAUDE_ARGS_LOG" \
    && bad "Skill tool leaked into the confined allowlist" \
    || ok "confined allowlist still omits the Skill tool"
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

# --- Case 4c: qa configured — implemented ticket also drafts a qa-test-plan (best-effort) ---
test_ticket_generates_qa() {
  echo "test_ticket_generates_qa:"
  setup
  write_ticket_config with-allowlist with-qa
  install_fake_git
  local item="20260716-000000-ticket-gh-3.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_TICKET_RECONCILE=1   # realistic: writes completed/, leaves drafts/ stub
  export FAKE_QA_DRAFT=1           # the QA run drops a qa-test-plan draft
  handle_line "$(msg_event id-ticket-qa "approve|$item")"

  grep -q "Generate a QA test plan" "$CLAUDE_ARGS_LOG" \
    && ok "QA generation run launched after implementation" \
    || bad "QA run not launched (args: $(cat "$CLAUDE_ARGS_LOG"))"
  grep -qF -- "Bash(curl *)" "$CLAUDE_ARGS_LOG" \
    && ok "QA allowlist includes curl (Pass 3 execution)" || bad "QA allowlist missing curl"
  local qa_args r
  qa_args="$(grep "Generate a QA test plan" "$CLAUDE_ARGS_LOG")"
  for r in "Bash(git *)" "Bash(gh *)" "Bash(git commit" "Bash(git push" "Bash(gh pr create"; do
    printf '%s' "$qa_args" | grep -qF -- "$r" && bad "QA run grants $r" || ok "QA run omits $r"
  done
  compgen -G "$EA_AGENT_DIR/queue/drafts/*qa-test-plan*" >/dev/null \
    && ok "qa-test-plan draft created" || bad "qa-test-plan draft missing"
  [ ! -e "$EA_AGENT_DIR/queue/drafts/$item" ] \
    && ok "ticket stub reconciled away" || bad "ticket stub not reconciled"
  grep -q "QA test plan drafted" "$NOTIFY_LOG" \
    && ok "🧪 QA FYI ack sent" || bad "missing QA FYI ack (log: $(cat "$NOTIFY_LOG"))"
  grep -q "Done" "$NOTIFY_LOG" && ! grep -q "Failed" "$NOTIFY_LOG" \
    && ok "ticket still reports Done (QA is best-effort)" || bad "wrong ticket ack"
  unset FAKE_TICKET_RECONCILE FAKE_QA_DRAFT
  teardown
}

# --- Case 4e: the QA run leaves its incoming/ original behind -> listener reconciles it ---
# The confined QA run writes the drafted item into drafts/ but cannot delete the incoming/
# original: that path is outside the worktree cwd. Left alone it is a live duplicate of the
# drafts/ copy, and queue-dedup-check.sh reports the same (type, source_id) every poll forever.
test_ticket_qa_reconciles_incoming_stub() {
  echo "test_ticket_qa_reconciles_incoming_stub:"
  setup
  write_ticket_config with-allowlist with-qa
  install_fake_git
  local item="20260716-000000-ticket-gh-5.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_TICKET_RECONCILE=1
  export FAKE_QA_DRAFT=1
  export FAKE_QA_INCOMING_LEFTOVER=1   # realistic: sandbox blocked the mv, both copies survive
  handle_line "$(msg_event id-ticket-qa-leftover "approve|$item")"

  compgen -G "$EA_AGENT_DIR/queue/drafts/*qa-test-plan*" >/dev/null \
    && ok "qa-test-plan draft present in drafts/" || bad "qa-test-plan draft missing"
  compgen -G "$EA_AGENT_DIR/queue/incoming/*qa-test-plan*" >/dev/null \
    && bad "incoming/ QA original left behind — duplicate of the drafts/ copy" \
    || ok "incoming/ QA original reconciled away"
  unset FAKE_TICKET_RECONCILE FAKE_QA_DRAFT FAKE_QA_INCOMING_LEFTOVER
  teardown
}

# --- Case 4f: a stale QA draft from an earlier ticket must not read as this run's success ---
# drafts/ accumulates qa-test-plan items until a human reviews them, so "does the queue contain
# a qa-test-plan" is true in the steady state. The check has to be about THIS run.
test_ticket_qa_ignores_stale_draft() {
  echo "test_ticket_qa_ignores_stale_draft:"
  setup
  write_ticket_config with-allowlist with-qa
  install_fake_git
  # An unrelated QA plan left over from an earlier ticket, still awaiting review.
  printf 'type: qa-test-plan\nsource_id: "ENG-99"\n' \
    > "$EA_AGENT_DIR/queue/drafts/20260701-000000-qa-test-plan-ENG-99.md"
  local item="20260716-000000-ticket-gh-6.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_TICKET_RECONCILE=1
  export FAKE_QA_DRAFT=0   # the QA run produces nothing this time
  handle_line "$(msg_event id-ticket-qa-stale "approve|$item")"

  grep -q "Generate a QA test plan" "$CLAUDE_ARGS_LOG" \
    && ok "QA run launched" || bad "QA run not launched"
  grep -q "QA test plan drafted" "$NOTIFY_LOG" \
    && bad "stale QA draft reported as this run's success" \
    || ok "stale QA draft not counted as success"
  grep -q "produced no qa-test-plan draft" "$LOG_FILE" 2>/dev/null \
    && ok "WARN logged for the empty QA run" || bad "no WARN logged (log: $(cat "$LOG_FILE" 2>/dev/null))"
  [ -e "$EA_AGENT_DIR/queue/drafts/20260701-000000-qa-test-plan-ENG-99.md" ] \
    && ok "stale QA draft left untouched" || bad "stale QA draft removed"
  grep -q "Done" "$NOTIFY_LOG" && ! grep -q "Failed" "$NOTIFY_LOG" \
    && ok "ticket still reports Done (QA is best-effort)" || bad "wrong ticket ack"
  unset FAKE_TICKET_RECONCILE FAKE_QA_DRAFT
  teardown
}

# --- Case 4d: no qa config — QA generation is skipped, ticket still completes ---
test_ticket_qa_skipped_without_config() {
  echo "test_ticket_qa_skipped_without_config:"
  setup
  write_ticket_config with-allowlist    # no qa block
  install_fake_git
  local item="20260716-000000-ticket-gh-4.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_TICKET_RECONCILE=1
  export FAKE_QA_DRAFT=1   # would fire IF the QA run were launched — it must not be
  handle_line "$(msg_event id-ticket-noqa "approve|$item")"

  grep -q "Generate a QA test plan" "$CLAUDE_ARGS_LOG" \
    && bad "QA run launched despite no qa.base_url" || ok "QA generation skipped (no qa.base_url)"
  compgen -G "$EA_AGENT_DIR/queue/drafts/*qa-test-plan*" >/dev/null \
    && bad "qa-test-plan draft created without qa config" || ok "no qa-test-plan draft"
  grep -q "QA test plan drafted" "$NOTIFY_LOG" \
    && bad "QA FYI ack sent without qa config" || ok "no QA FYI ack"
  [ -e "$EA_AGENT_DIR/queue/completed/$item" ] && [ ! -e "$EA_AGENT_DIR/queue/drafts/$item" ] \
    && ok "ticket still completed" || bad "ticket not completed"
  grep -q "Done" "$NOTIFY_LOG" && ok "ticket reports Done" || bad "missing Done ack"
  unset FAKE_TICKET_RECONCILE FAKE_QA_DRAFT
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

# --- Case 6: approved ticket-investigation runs the CONFINED READ-ONLY path ---
test_investigation_confined_run() {
  echo "test_investigation_confined_run:"
  setup
  write_investigation_config
  install_fake_git
  local item="20260820-000000-ticket-investigation-ENG-1.md"
  printf 'type: ticket-investigation\nproject: wayfinder-api\nticket_key: "ENG-1"\n' \
    > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_INVESTIGATE_ARCHIVE=1 FAKE_INVESTIGATE_COMPLETE=1
  handle_line "$(msg_event id-inv "approve|$item")"

  grep -qF -- "--max-budget-usd $INVESTIGATE_BUDGET_USD" "$CLAUDE_ARGS_LOG" \
    && ok "investigation uses its own budget ($INVESTIGATE_BUDGET_USD)" \
    || bad "investigate budget not applied (args: $(cat "$CLAUDE_ARGS_LOG"))"
  grep -qF -- "mcp__atlassian__addCommentToJiraIssue" "$CLAUDE_ARGS_LOG" \
    && ok "comment verb allowlisted" || bad "addCommentToJiraIssue missing"
  grep -qF -- "Bash(gh issue comment:*)" "$CLAUDE_ARGS_LOG" \
    && ok "gh issue comment allowlisted" || bad "gh issue comment missing"
  grep -qF -- "Bash(gh auth status:*)" "$CLAUDE_ARGS_LOG" \
    && ok "read-only gh preflight allowlisted (denied preflight => model abandons the CLI)" \
    || bad "gh auth status preflight missing"
  grep -qF -- "--add-dir" "$CLAUDE_ARGS_LOG" \
    && ok "--add-dir passed (archive + completed/ are outside the worktree cwd)" \
    || bad "--add-dir missing — writes outside the worktree would be denied"
  grep -qF -- "TARGET: the ONLY issue you may comment on is exactly ENG-1" "$CLAUDE_ARGS_LOG" \
    && ok "comment target pinned in the prompt" || bad "target not pinned"
  # The broad prefixes must NOT be present: they would re-grant git push / gh pr create.
  grep -qF -- "Bash(git *)" "$CLAUDE_ARGS_LOG" \
    && bad "broad Bash(git *) leaked into the read-only allowlist" || ok "no broad Bash(git *)"
  grep -qF -- "Bash(gh *)" "$CLAUDE_ARGS_LOG" \
    && bad "broad Bash(gh *) leaked into the read-only allowlist" || ok "no broad Bash(gh *)"
  grep -qF -- "Bash(curl *)" "$CLAUDE_ARGS_LOG" \
    && bad "curl leaked into the investigation allowlist" || ok "no curl"
  grep -qF -- "Bash(bin/rails *)" "$CLAUDE_ARGS_LOG" \
    && bad "build rules leaked into the investigation allowlist" || ok "no build rules"
  grep -q "worktree add" "$GIT_LOG" && grep -q "worktree remove" "$GIT_LOG" \
    && ok "worktree created and torn down" || bad "worktree lifecycle missing"
  [ ! -e "$EA_AGENT_DIR/queue/drafts/$item" ] \
    && ok "drafts/ stub reconciled away" || bad "drafts/ stub not reconciled"
  grep -q "Done" "$NOTIFY_LOG" && ! grep -q "Failed" "$NOTIFY_LOG" \
    && ok "Done ack (not a false Failed)" || bad "wrong ack (log: $(cat "$NOTIFY_LOG"))"
  unset FAKE_INVESTIGATE_ARCHIVE FAKE_INVESTIGATE_COMPLETE
  teardown
}

# --- Case 6a: an investigation is NOT refused for having no exec.allowed_commands ---
# The inverse of test_ticket_refused_without_allowlist: deny-by-default there must not reach here,
# or every doc-only ticket on a project with no build list is refused — the bug this feature fixes.
test_investigation_runs_without_exec_allowlist() {
  echo "test_investigation_runs_without_exec_allowlist:"
  setup
  write_investigation_config      # deliberately no exec: block at all
  install_fake_git
  local item="20260820-000000-ticket-investigation-ENG-2.md"
  printf 'type: ticket-investigation\nproject: wayfinder-api\nticket_key: "ENG-2"\n' \
    > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_INVESTIGATE_COMPLETE=1
  handle_line "$(msg_event id-inv-noexec "approve|$item")"

  [ -s "$CLAUDE_ARGS_LOG" ] \
    && ok "investigation ran with no exec.allowed_commands configured" \
    || bad "investigation was refused for lacking a build allowlist"
  grep -q "worktree add" "$GIT_LOG" && ok "worktree still created" || bad "no worktree"
  unset FAKE_INVESTIGATE_COMPLETE
  teardown
}

# --- Case 6b: QA is suppressed STRUCTURALLY for an investigation (no diff to test) ---
test_investigation_suppresses_qa() {
  echo "test_investigation_suppresses_qa:"
  setup
  write_investigation_config
  install_fake_git
  # qa.base_url present, so QA *would* fire if the code path were reachable.
  printf '    qa:\n      base_url: "http://localhost:3000"\n' >> "$EA_CONFIG_FILE"
  local item="20260820-000000-ticket-investigation-ENG-3.md"
  printf 'type: ticket-investigation\nproject: wayfinder-api\nticket_key: "ENG-3"\n' \
    > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_INVESTIGATE_COMPLETE=1 FAKE_QA_DRAFT=1
  handle_line "$(msg_event id-inv-qa "approve|$item")"

  grep -q "Generate a QA test plan" "$CLAUDE_ARGS_LOG" \
    && bad "QA run launched for an investigation" || ok "QA suppressed (no diff to test)"
  compgen -G "$EA_AGENT_DIR/queue/drafts/*qa-test-plan*" >/dev/null \
    && bad "qa-test-plan draft created for an investigation" || ok "no qa-test-plan draft"
  unset FAKE_INVESTIGATE_COMPLETE FAKE_QA_DRAFT
  teardown
}

# --- Case 6c: idempotency — an existing archive means a comment may already be posted ---
# A ticket comment is APPEND-ONLY, and the listener invites a retry on failure ("still queued,
# re-run"). Without this guard, a run that posts and then dies gets re-approved and double-posts.
test_investigation_skips_when_already_posted() {
  echo "test_investigation_skips_when_already_posted:"
  setup
  write_investigation_config
  install_fake_git
  local item="20260820-000000-ticket-investigation-ENG-1.md"
  printf 'type: ticket-investigation\nproject: wayfinder-api\nticket_key: "ENG-1"\n' \
    > "$EA_AGENT_DIR/queue/drafts/$item"
  mkdir -p "$EA_AGENT_DIR/investigations"
  printf '## Findings\n' > "$EA_AGENT_DIR/investigations/ENG-1-20260101-000000.md"
  handle_line "$(msg_event id-inv-dup "approve|$item")"

  [ ! -s "$CLAUDE_ARGS_LOG" ] \
    && ok "no second investigation launched (archive present)" \
    || bad "re-ran the investigation despite an existing archive (would double-post)"
  grep -q "worktree add" "$GIT_LOG" 2>/dev/null \
    && bad "worktree created before the archive check" || ok "refused before worktree setup"
  [ ! -e "$EA_AGENT_DIR/queue/drafts/$item" ] \
    && ok "item reconciled out of drafts/ (idempotent success)" || bad "item left in drafts/"
  grep -q "Done" "$NOTIFY_LOG" && ok "Done ack" || bad "missing Done ack"
  teardown
}

# --- Case 6d: a malformed ticket_key refuses before anything runs (comment target is pinned) ---
test_investigation_refused_on_bad_ticket_key() {
  echo "test_investigation_refused_on_bad_ticket_key:"
  setup
  write_investigation_config
  install_fake_git
  local item="20260820-000000-ticket-investigation-bad.md"
  printf 'type: ticket-investigation\nproject: wayfinder-api\nticket_key: "../../etc/passwd"\n' \
    > "$EA_AGENT_DIR/queue/drafts/$item"
  handle_line "$(msg_event id-inv-bad "approve|$item")"

  [ ! -s "$CLAUDE_ARGS_LOG" ] \
    && ok "claude never launched with an unusable comment target" \
    || bad "ran despite a malformed ticket_key (args: $(cat "$CLAUDE_ARGS_LOG"))"
  grep -q "worktree add" "$GIT_LOG" 2>/dev/null \
    && bad "worktree created before validating the target" || ok "refused before worktree setup"
  [ -e "$EA_AGENT_DIR/queue/drafts/$item" ] \
    && ok "item left in drafts/ for the human" || bad "item wrongly left drafts/"
  grep -q "Failed" "$NOTIFY_LOG" && grep -q "urgent" "$NOTIFY_LOG" \
    && ok "urgent Failed ack sent" || bad "missing Failed ack"
  teardown
}

# --- Case 6e: transition verbs are gated on config, not always granted ---
test_investigation_transition_verbs_gated() {
  echo "test_investigation_transition_verbs_gated:"
  setup
  write_investigation_config            # no on_complete_status
  install_fake_git
  local item="20260820-000000-ticket-investigation-ENG-4.md"
  printf 'type: ticket-investigation\nproject: wayfinder-api\nticket_key: "ENG-4"\n' \
    > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_INVESTIGATE_COMPLETE=1
  handle_line "$(msg_event id-inv-notr "approve|$item")"
  grep -qF -- "mcp__atlassian__transitionJiraIssue" "$CLAUDE_ARGS_LOG" \
    && bad "transition verb granted without on_complete_status" \
    || ok "transition verbs absent when unconfigured (injected 'move to Done' cannot fire)"
  teardown

  setup
  write_investigation_config with-transition
  install_fake_git
  printf 'type: ticket-investigation\nproject: wayfinder-api\nticket_key: "ENG-5"\n' \
    > "$EA_AGENT_DIR/queue/drafts/20260820-000000-ticket-investigation-ENG-5.md"
  handle_line "$(msg_event id-inv-tr "approve|20260820-000000-ticket-investigation-ENG-5.md")"
  grep -qF -- "mcp__atlassian__transitionJiraIssue" "$CLAUDE_ARGS_LOG" \
    && grep -qF -- "mcp__atlassian__getTransitionsForJiraIssue" "$CLAUDE_ARGS_LOG" \
    && ok "both transition verbs granted when on_complete_status is set" \
    || bad "transition verbs missing despite config (a status name needs resolving to an id)"
  unset FAKE_INVESTIGATE_COMPLETE
  teardown
}

# --- Case 6f: a NEAR-MISS type still gets the default budget ---
# Regression guard against anyone "simplifying" the budget case into a `ticket*)` glob.
# --- Case 6g: a GitHub investigation's archive key is repo-scoped, not the bare issue number ---
# "#45" collides across repos: one repo's archive would overwrite another's AND trip the
# already-posted guard for an unrelated ticket.
test_investigation_github_archive_key() {
  echo "test_investigation_github_archive_key:"
  setup
  write_investigation_config
  install_fake_git
  local item="20260820-000000-ticket-investigation-gh-45.md"
  printf 'type: ticket-investigation\nproject: wayfinder-api\nticket_key: "#45"\nsource_id: "futuresinc/wayfinder-api#45"\n' \
    > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_INVESTIGATE_COMPLETE=1
  handle_line "$(msg_event id-inv-gh "approve|$item")"

  grep -qF -- "investigations/futuresinc-wayfinder-api-45-" "$CLAUDE_ARGS_LOG" \
    && ok "GitHub archive key is derived from source_id (repo-scoped)" \
    || bad "archive key not repo-scoped (args: $(cat "$CLAUDE_ARGS_LOG"))"
  unset FAKE_INVESTIGATE_COMPLETE
  teardown
}

test_near_miss_type_budget() {
  echo "test_near_miss_type_budget:"
  setup
  local item="20260820-000000-ticket-plan-xyz.md"
  printf 'type: ticket-plan\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-nearmiss "approve|$item")"
  grep -qF -- "--max-budget-usd $DEFAULT_BUDGET_USD" "$CLAUDE_ARGS_LOG" \
    && ok "ticket-plan gets the default budget (case globs are exact, not prefixes)" \
    || bad "near-miss type got a ticket budget (args: $(cat "$CLAUDE_ARGS_LOG"))"
  teardown
}

# --- macOS TCC preflight: warn once per new claude binary, never on first sight ---
#
# The failure this guards: macOS keys folder-access grants on the RESOLVED executable, and
# `claude` auto-updates into a new versions/<ver> file behind the ~/.local/bin/claude symlink.
# A post-update approval is then denied folder access and the user gets a bare "⚠️ Failed" with
# no hint that a privacy grant, not the item, was the problem.
#
# Both directions matter. No warning => the cause stays invisible. A warning on every dispatch
# => a push per approval on the topic the user taps Approve on, which trains them to ignore it.
test_tcc_preflight_reports_change() {
  echo "test_tcc_preflight_reports_change:"
  setup
  # Pre-seed the record with a DIFFERENT path: the state left by a run under the old binary.
  echo "$TMP/claude-old" > "$EA_AGENT_DIR/state/claude-bin.path"
  local item="20260716-000000-pr-review-tcc.md"
  touch "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-tcc-changed "approve|$item")"

  if [ "$(uname -s)" = "Darwin" ]; then
    grep -q "Full Disk Access" "$NOTIFY_LOG" \
      && ok "a changed binary warns about the stale grants" \
      || bad "no TCC warning (acks: $(cat "$NOTIFY_LOG"))"
    grep -qF "$CLAUDE_BIN" "$EA_AGENT_DIR/state/claude-bin.path" \
      && ok "the record advances to the new binary" || bad "record not advanced"
  else
    grep -q "Full Disk Access" "$NOTIFY_LOG" \
      && bad "warned on a non-Darwin host (no TCC there)" \
      || ok "non-Darwin does not warn (no TCC grants to go stale)"
  fi
  # The warning must not disturb the normal acks the approval already sends.
  grep -q "Done" "$NOTIFY_LOG" && ok "approval still reports Done" || bad "missing Done ack"
  teardown
}

test_tcc_preflight_silent_on_first_sight() {
  echo "test_tcc_preflight_silent_on_first_sight:"
  setup   # fresh sandbox => no state/claude-bin.path
  local item="20260716-000000-pr-review-tcc2.md"
  touch "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-tcc-first "approve|$item")"

  grep -q "Full Disk Access" "$NOTIFY_LOG" \
    && bad "warned on first sight (would fire on every fresh install)" \
    || ok "first sight records silently"
  local n; n="$(wc -l < "$NOTIFY_LOG")"
  [ "$n" -eq 2 ] && ok "still exactly 2 acks (receipt + outcome)" || bad "expected 2 acks, got $n"
  teardown
}

test_tcc_preflight_warns_once() {
  echo "test_tcc_preflight_warns_once:"
  setup
  echo "$TMP/claude-old" > "$EA_AGENT_DIR/state/claude-bin.path"
  export FAKE_SUCCEED=1
  local a="20260716-000000-pr-review-tcc3.md" b="20260716-000000-pr-review-tcc4.md"
  touch "$EA_AGENT_DIR/queue/drafts/$a" "$EA_AGENT_DIR/queue/drafts/$b"
  handle_line "$(msg_event id-tcc-once-1 "approve|$a")"
  handle_line "$(msg_event id-tcc-once-2 "approve|$b")"

  local w; w="$(grep -c "Full Disk Access" "$NOTIFY_LOG")"
  if [ "$(uname -s)" = "Darwin" ]; then
    [ "$w" -eq 1 ] && ok "warns once across two approvals, not per dispatch" \
      || bad "expected 1 TCC warning across 2 approvals, got $w"
  else
    [ "$w" -eq 0 ] && ok "non-Darwin never warns" || bad "non-Darwin warned $w times"
  fi
  teardown
}

# --- Case 7: a failed `git fetch` must be named, not swallowed ---
# The fetch is best-effort (`|| true` once), so a transient github outage silently dropped the
# run onto whatever the LOCAL origin/<base> ref said — observed as a worktree detached at a
# days-old release commit while the log still reported a reassuring "base main".
test_worktree_stale_base_reported() {
  echo "test_worktree_stale_base_reported:"
  setup
  write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-stale.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1 FAKE_GIT_FETCH_FAIL=1
  handle_line "$(msg_event id-stale "approve|$item")"

  grep -q "WARN: git fetch origin main failed" "$LOG_FILE" \
    && ok "fetch failure logged as a WARN" || bad "fetch failure swallowed (log: $(cat "$LOG_FILE"))"
  grep -q "implementing ticket .* base main @ deadbee (STALE" "$LOG_FILE" \
    && ok "base line names the sha and marks it stale" \
    || bad "base line does not report staleness (log: $(cat "$LOG_FILE"))"
  [ -s "$CLAUDE_ARGS_LOG" ] \
    && ok "run still proceeds (a network blip must not strand the item)" \
    || bad "run was refused on a transient fetch failure"
  unset FAKE_GIT_FETCH_FAIL
  teardown
}

# --- Case 7a: the happy path still reports the resolved sha, and never says STALE ---
test_worktree_fresh_base_reported() {
  echo "test_worktree_fresh_base_reported:"
  setup
  write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-fresh.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-fresh "approve|$item")"

  grep -q "implementing ticket .* base main @ deadbee)" "$LOG_FILE" \
    && ok "base line names the resolved sha" || bad "base sha missing (log: $(cat "$LOG_FILE"))"
  grep -q "STALE" "$LOG_FILE" && bad "clean fetch wrongly marked stale" || ok "clean fetch not marked stale"
  teardown
}

# --- Case 7c: the base is the REMOTE's default branch, not the local origin/HEAD ---
# A checkout's origin/HEAD is set at clone time. Observed: it still named a deleted `stage`, so two
# runs were built on a 22-month-old commit while master had moved on.
test_worktree_base_from_remote_head() {
  echo "test_worktree_base_from_remote_head:"
  setup
  write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-remotehead.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1 FAKE_REMOTE_HEAD=master
  handle_line "$(msg_event id-remotehead "approve|$item")"

  grep -q "worktree add --detach .* origin/master$" "$GIT_LOG" \
    && ok "worktree detached at origin/<remote default>" || bad "wrong base checked out (git log: $(cat "$GIT_LOG"))"
  grep -qF "base branch 'master'" "$CLAUDE_ARGS_LOG" \
    && ok "prompt names the resolved base" || bad "prompt does not name the base"
  unset FAKE_REMOTE_HEAD
  teardown
}

# --- Case 7d: no origin/<base> => refuse; never detach at a local branch of the same name ---
test_worktree_refuses_local_branch_fallback() {
  echo "test_worktree_refuses_local_branch_fallback:"
  setup
  write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-nobase.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1 FAKE_REMOTE_HEAD=stage FAKE_MISSING_REF=origin/stage
  handle_line "$(msg_event id-nobase "approve|$item")"

  grep -q "worktree add --detach .* stage$" "$GIT_LOG" \
    && bad "fell back to the local branch (git log: $(cat "$GIT_LOG"))" || ok "no local-branch fallback"
  [ -s "$CLAUDE_ARGS_LOG" ] && bad "run started without a base" || ok "run refused"
  grep -q "refusing to fall back to a local branch" "$LOG_FILE" \
    && ok "refusal logged" || bad "refusal not logged (log: $(cat "$LOG_FILE"))"
  unset FAKE_REMOTE_HEAD FAKE_MISSING_REF
  teardown
}

# --- Case 7e: exec.worktree_setup runs in the run worktree, before claude, with EA_PROJECT_PATH ---
test_worktree_setup_runs_before_claude() {
  echo "test_worktree_setup_runs_before_claude:"
  setup
  export ORDER_LOG="$TMP/order.log"; : > "$ORDER_LOG"
  EXEC_EXTRA="      worktree_setup: 'echo \"setup:\$PWD:\$EA_PROJECT_PATH\" >> $ORDER_LOG'" write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-setup.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-setup "approve|$item")"

  local first second
  first="$(sed -n 1p "$ORDER_LOG")"; second="$(sed -n 2p "$ORDER_LOG")"
  case "$first" in "setup:${EA_AGENT_DIR}/worktrees/"*":${TMP}/repo") ok "setup ran in the worktree with EA_PROJECT_PATH" ;;
    *) bad "setup did not run in the worktree (order: $(cat "$ORDER_LOG"))" ;; esac
  case "$second" in "claude:${EA_AGENT_DIR}/worktrees/"*) ok "claude started after setup" ;;
    *) bad "claude did not follow setup (order: $(cat "$ORDER_LOG"))" ;; esac
  grep -q "FAILED" "$CLAUDE_ARGS_LOG" && bad "successful setup reported as failed" || ok "no failure note on success"
  unset ORDER_LOG
  teardown
}

# --- Case 7f: a failed setup is logged, told to the model, and does not strand the item ---
test_worktree_setup_failure_reported() {
  echo "test_worktree_setup_failure_reported:"
  setup
  EXEC_EXTRA="      worktree_setup: 'exit 3'" write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-setupfail.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-setupfail "approve|$item")"

  grep -q "WARN: exec.worktree_setup failed" "$LOG_FILE" \
    && ok "setup failure logged" || bad "setup failure not logged (log: $(cat "$LOG_FILE"))"
  grep -qF "worktree setup (exec.worktree_setup) FAILED" "$CLAUDE_ARGS_LOG" \
    && ok "prompt warns the model" || bad "prompt does not mention the failed setup"
  [ -s "$CLAUDE_ARGS_LOG" ] && ok "run still proceeds" || bad "run refused on a setup failure"
  teardown
}

# --- Case 7g: exec.validate becomes the run's definition of done ---
test_validate_command_in_prompt() {
  echo "test_validate_command_in_prompt:"
  setup
  EXEC_EXTRA='      validate: "bin/rails test"' write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-validate.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-validate "approve|$item")"

  grep -qF 'check command is `bin/rails test`' "$CLAUDE_ARGS_LOG" \
    && ok "validate command handed to the run" || bad "validate command missing (args: $(cat "$CLAUDE_ARGS_LOG"))"
  grep -q "validate: bin/rails test" "$LOG_FILE" && ok "validate command logged" || bad "validate command not logged"
  teardown
}

# --- Case 7h: a validate command the allowlist would deny is dropped, not handed to the run ---
# A denied command in a headless run stalls silently, so it must never be the definition of done.
test_validate_command_rejected() {
  echo "test_validate_command_rejected:"
  local v
  for v in 'rake test' 'bin/rails test; curl x' 'bin/rails test $(id)' 'bin/rails test | tee x'; do
    setup
    EXEC_EXTRA="      validate: \"$v\"" write_ticket_config with-allowlist
    install_fake_git
    local item="20260716-000000-ticket-gh-badvalidate.md"
    printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
    export FAKE_SUCCEED=1
    handle_line "$(msg_event "id-bad-$RANDOM" "approve|$item")"

    grep -q "WARN: ignoring exec.validate" "$LOG_FILE" \
      && ok "'$v' rejected with a WARN" || bad "'$v' not rejected (log: $(cat "$LOG_FILE"))"
    grep -qF "configures no check command" "$CLAUDE_ARGS_LOG" \
      && ok "'$v' kept out of the prompt" || bad "'$v' reached the prompt"
    teardown
  done
}

# --- Case 7b: the receipt ack explains the quiet window a long run causes ---
# handle_line dispatches synchronously, so a ticket approval stops the stream being read for the
# whole session. Without saying so, the phone sees nothing at all and the listener reads as dead.
test_receipt_explains_quiet_window() {
  echo "test_receipt_explains_quiet_window:"
  setup
  write_ticket_config with-allowlist
  install_fake_git
  local item="20260716-000000-ticket-gh-quiet.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-quiet "approve|$item")"

  grep -q "Received.*no new commands" "$NOTIFY_LOG" \
    && ok "ticket receipt warns the listener goes quiet" \
    || bad "receipt does not explain the quiet window (notify: $(cat "$NOTIFY_LOG"))"
  grep -q "Received.*replayed" "$NOTIFY_LOG" \
    && ok "receipt says taps meanwhile are replayed, not lost" \
    || bad "receipt does not say taps are replayed"
  teardown
}

# --- Case 7c: a short item keeps the terse receipt ---
test_receipt_terse_for_short_item() {
  echo "test_receipt_terse_for_short_item:"
  setup
  local item="20260716-000000-pr-review-quiet.md"
  touch "$EA_AGENT_DIR/queue/drafts/$item"
  export FAKE_SUCCEED=1
  handle_line "$(msg_event id-terse "approve|$item")"

  grep -q "Received" "$NOTIFY_LOG" && ! grep -q "no new commands" "$NOTIFY_LOG" \
    && ok "short item receipt stays terse" \
    || bad "long-run note leaked onto a short item (notify: $(cat "$NOTIFY_LOG"))"
  teardown
}

test_success
test_failure
test_invalid
test_tcc_preflight_reports_change
test_tcc_preflight_silent_on_first_sight
test_tcc_preflight_warns_once
test_ticket_confined_run
test_ticket_dispatches_via_execute_item
test_ticket_reconciles_stub
test_ticket_generates_qa
test_ticket_qa_skipped_without_config
test_ticket_qa_reconciles_incoming_stub
test_ticket_qa_ignores_stale_draft
test_ticket_refused_without_allowlist
test_default_budget
test_investigation_confined_run
test_investigation_runs_without_exec_allowlist
test_investigation_suppresses_qa
test_investigation_skips_when_already_posted
test_investigation_refused_on_bad_ticket_key
test_investigation_transition_verbs_gated
test_investigation_github_archive_key
test_near_miss_type_budget
test_worktree_stale_base_reported
test_worktree_fresh_base_reported
test_worktree_base_from_remote_head
test_worktree_refuses_local_branch_fallback
test_worktree_setup_runs_before_claude
test_worktree_setup_failure_reported
test_validate_command_in_prompt
test_validate_command_rejected
test_receipt_explains_quiet_window
test_receipt_terse_for_short_item

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
