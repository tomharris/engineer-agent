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

  # Stub claude: on success empty drafts/ (simulating execute-item), else no-op.
  export CLAUDE_BIN="$TMP/fake-claude"
  cat > "$CLAUDE_BIN" <<'EOF'
#!/bin/bash
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

test_success
test_failure
test_invalid

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
