# Listener Acknowledgement Push-Back Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scripts/approval-listener.sh` push an ntfy acknowledgement back to the user — a receipt ack when a valid approve/reject tap lands, and an outcome ack reporting success or failure after the execute run.

**Architecture:** Reuse the existing `notify.sh --fyi` (button-less confirmation to the outbound `topic`). Add a `NOTIFY_BIN` override (mirroring the existing `CLAUDE_BIN` override) so the notifier is injectable, a best-effort `push_ack` helper, and two call sites inside `handle_line`. Guard the reconnect loop so the script can be `source`d by a test harness that stubs both external binaries and drives `handle_line` directly.

**Tech Stack:** Bash 5, `jq`, `curl` (via `notify.sh`). No test framework exists in this repo; the test is a self-contained `bash` script with binary stubs.

## Global Constraints

- Reference sibling scripts via computed `PLUGIN_ROOT`/`SCRIPT_DIR`, never bare relative paths (cron/systemd run from `$HOME`).
- Acks go to the outbound `topic` only, never `command_topic`. No new posting capability may be added — an ack is an outbound notification only.
- `push_ack` is best-effort: an ntfy/curl failure must never crash or stall the reconnect loop. The listener uses `set -uo pipefail` (no `set -e`).
- Engineer-agent priority vocabulary is `urgent | normal | low` (mapped to ntfy priorities inside `notify.sh`). Pass these words, not ntfy-native ones.
- No ack for invalid messages (bad decision, filename-allowlist failure) or already-seen dedup hits.
- `EA_AGENT_DIR`, `CLAUDE_BIN`, and the new `NOTIFY_BIN` all honor a pre-set env value (`${VAR:-default}`), which is what makes the test able to inject temp dirs and stubs.

---

### Task 1: Acknowledgement push-back in the listener

**Files:**
- Modify: `scripts/approval-listener.sh`
- Create: `tests/approval-listener.test.sh`

**Interfaces:**
- Produces (new globals / functions in `approval-listener.sh`):
  - `NOTIFY_BIN` — path to the notifier binary; `"${NOTIFY_BIN:-${PLUGIN_ROOT}/scripts/notify.sh}"`.
  - `push_ack <priority> <message>` — best-effort; calls `"$NOTIFY_BIN" --fyi --title engineer-agent --priority <priority> --message <message>`, never returns non-zero.
- Consumes (existing globals used by `push_ack` and the new call sites): `NOTIFY_BIN`, `LOG_FILE`, `AGENT_DIR`, `decision`, `item` (locals in `handle_line`).

---

- [ ] **Step 1: Add the `NOTIFY_BIN` override next to `CLAUDE_BIN`**

In `scripts/approval-listener.sh`, immediately after the existing `CLAUDE_BIN=...` line (currently line 25), add:

```bash
# NOTIFY_BIN can be overridden (e.g. by tests) to point at a stub notifier;
# otherwise use the plugin's notify.sh. Mirrors the CLAUDE_BIN override above.
NOTIFY_BIN="${NOTIFY_BIN:-${PLUGIN_ROOT}/scripts/notify.sh}"
```

(`PLUGIN_ROOT` is already computed above, at the top of the script.)

- [ ] **Step 2: Add the `push_ack` helper next to `log`**

In `scripts/approval-listener.sh`, immediately after the `log() { ... }` definition (currently line 34), add:

```bash
# push_ack — best-effort acknowledgement back to the user's outbound ntfy topic.
# Never fails the caller: an ntfy hiccup must not crash or stall the listen loop.
# priority is engineer-agent vocabulary (urgent|normal|low); notify.sh maps it.
push_ack() {
  local priority="$1" message="$2"
  "$NOTIFY_BIN" --fyi --title "engineer-agent" --priority "$priority" --message "$message" \
    </dev/null >>"$LOG_FILE" 2>&1 || true
}
```

- [ ] **Step 3: Fire the receipt ack before the execute run**

In `handle_line`, the block that currently reads (around lines 80–82):

```bash
  log "executing: ${decision} ${item} (msg ${id})"
  echo "- \"${id}\"" >> "$SEEN_FILE"           # record before acting: at-most-once
  [ -n "$mtime" ] && echo "$mtime" > "$SINCE_FILE"
```

becomes (append one line):

```bash
  log "executing: ${decision} ${item} (msg ${id})"
  echo "- \"${id}\"" >> "$SEEN_FILE"           # record before acting: at-most-once
  [ -n "$mtime" ] && echo "$mtime" > "$SINCE_FILE"
  push_ack low "📨 Received: ${decision} ${item} — working…"
```

- [ ] **Step 4: Fire the outcome ack in the drafts/ check**

In `handle_line`, the final block that currently reads (around lines 114–118):

```bash
  if [ ! -e "${AGENT_DIR}/queue/drafts/${item}" ]; then
    log "done: ${decision} ${item}"
  else
    log "WARN: ${decision} ${item} did not complete (still in drafts/); see log above. Re-run after fixing."
  fi
```

becomes:

```bash
  if [ ! -e "${AGENT_DIR}/queue/drafts/${item}" ]; then
    log "done: ${decision} ${item}"
    push_ack normal "✅ Done: ${decision} ${item}"
  else
    log "WARN: ${decision} ${item} did not complete (still in drafts/); see log above. Re-run after fixing."
    push_ack urgent "⚠️ Failed: ${decision} ${item} — still queued, re-run"
  fi
```

- [ ] **Step 5: Guard the reconnect loop so the script is sourceable**

At the bottom of `scripts/approval-listener.sh`, the reconnect loop currently reads:

```bash
# Reconnect loop with capped backoff. Dedup makes replays on reconnect harmless.
BACKOFF=2
while true; do
  SINCE="$(cat "$SINCE_FILE" 2>/dev/null || echo now)"
  STREAM_URL="${NTFY_SERVER}/${NTFY_COMMAND_TOPIC}/json?since=${SINCE}"
  while IFS= read -r line; do
    [ -n "$line" ] && handle_line "$line"
    BACKOFF=2   # reset backoff once we are receiving data
  done < <(curl -sN "${AUTH_ARGS[@]}" "$STREAM_URL" 2>>"$LOG_FILE")

  log "stream closed; reconnecting in ${BACKOFF}s"
  sleep "$BACKOFF"
  BACKOFF=$(( BACKOFF < 60 ? BACKOFF * 2 : 60 ))
done
```

Wrap the loop (only the loop, not the setup above it) in a "run only when executed, not sourced" guard:

```bash
# Reconnect loop with capped backoff. Dedup makes replays on reconnect harmless.
# Guarded so the script can be sourced by tests (which drive handle_line directly)
# without launching the stream.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  BACKOFF=2
  while true; do
    SINCE="$(cat "$SINCE_FILE" 2>/dev/null || echo now)"
    STREAM_URL="${NTFY_SERVER}/${NTFY_COMMAND_TOPIC}/json?since=${SINCE}"
    while IFS= read -r line; do
      [ -n "$line" ] && handle_line "$line"
      BACKOFF=2   # reset backoff once we are receiving data
    done < <(curl -sN "${AUTH_ARGS[@]}" "$STREAM_URL" 2>>"$LOG_FILE")

    log "stream closed; reconnecting in ${BACKOFF}s"
    sleep "$BACKOFF"
    BACKOFF=$(( BACKOFF < 60 ? BACKOFF * 2 : 60 ))
  done
fi
```

- [ ] **Step 6: Write the integration test**

Create `tests/approval-listener.test.sh` with exactly this content:

```bash
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
  FAKE_SUCCEED=1
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
  FAKE_SUCCEED=0
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
```

Make it executable:

```bash
chmod +x tests/approval-listener.test.sh
```

- [ ] **Step 7: Run the test — expect the ack cases to FAIL first**

Run: `bash tests/approval-listener.test.sh`
Expected before implementing Steps 1–5: `test_success` and `test_failure` FAIL (0 acks recorded), `test_invalid` passes; final line non-zero exit with `FAIL` > 0.

> NOTE for the implementer: Steps 1–5 edit the script and Step 6 writes the test. If you are following strict red-green, apply Step 6 first, run this step to observe red, then apply Steps 1–5 and re-run. If Steps 1–5 are already applied, this step will instead pass — that is fine; the point is to see the test exercise real behavior.

- [ ] **Step 8: Run the test — expect PASS after implementation**

Run: `bash tests/approval-listener.test.sh`
Expected: every `ok:` line prints, final line `PASS=8 FAIL=0`, exit status 0.

- [ ] **Step 9: Syntax-check the modified script**

Run: `bash -n scripts/approval-listener.sh && echo "syntax ok"`
Expected: `syntax ok`

- [ ] **Step 10: Commit**

```bash
git add scripts/approval-listener.sh tests/approval-listener.test.sh
git commit -m "feat: push ntfy receipt and outcome acks from approval listener"
```

---

### Task 2: Documentation

**Files:**
- Modify: `CLAUDE.md` (the "Notifications & Remote Approval" section)
- Modify: `README.md` (the corresponding notifications/remote-approval section)

**Interfaces:**
- Consumes: the behavior implemented in Task 1 (receipt ack on tap, outcome ack after run).

---

- [ ] **Step 1: Locate the sections to update**

Run: `grep -n "approval-listener" CLAUDE.md README.md`
This anchors the "Notifications & Remote Approval" prose in both files.

- [ ] **Step 2: Update `CLAUDE.md`**

In the "Notifications & Remote Approval" section, in the paragraph describing the **Inbound** flow (the `scripts/approval-listener.sh` sentence that ends "…runs `/engineer-agent execute <item-id> <decision>` headlessly."), append:

```markdown
After validating a command the listener also pushes two best-effort
acknowledgements back to the outbound `topic` via `notify.sh --fyi`: a **receipt**
ack (low priority, "📨 Received …") the moment the tap lands, and an **outcome**
ack after the run — "✅ Done …" (normal) when the item leaves `queue/drafts/`, or
"⚠️ Failed …" (urgent) when it did not. Invalid or already-seen commands are not
acknowledged (avoids noise and confirming a live listener to a prober). The ack
adds no posting capability — it is an outbound notification only, so the
"polling reads; only execute-item writes" invariant is untouched.
```

- [ ] **Step 3: Update `README.md`**

Find the equivalent remote-approval description in `README.md` and add a matching (user-facing, lighter) note that the listener now confirms each approve/reject tap with a receipt notification and a follow-up success/failure notification on your phone. Keep wording consistent with the `CLAUDE.md` change; do not introduce config keys (there are none).

- [ ] **Step 4: Verify the two docs agree**

Run: `grep -n "Received\|receipt ack\|outcome ack" CLAUDE.md README.md`
Expected: both files mention the receipt and outcome acknowledgements.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: note listener acknowledgement push-back in CLAUDE.md and README"
```

---

## Self-Review

**Spec coverage:**
- Receipt ack before run → Task 1 Step 3. ✓
- Outcome ack (success normal / failure urgent) → Task 1 Step 4. ✓
- Reuse `notify.sh --fyi`, no changes to notify.sh/lib-ntfy → Tasks touch only `approval-listener.sh` + tests + docs. ✓
- Best-effort / failure isolation → `push_ack` `|| true`, Task 1 Step 2. ✓
- No ack for invalid / already-seen → not wired into those branches; asserted by `test_invalid`. ✓
- No `Open` button → `push_ack` uses `--fyi` with no `--source-url`. ✓
- Security (outbound topic only, no new capability) → Global Constraints + docs. ✓
- Testing (happy / failure / invalid / unavailable) → `test_success`, `test_failure`, `test_invalid`; "ntfy unavailable" is covered structurally because the stub notifier and `|| true` guarantee the loop is never affected by publish outcome. ✓
- Docs update → Task 2. ✓

**Placeholder scan:** No TBD/TODO; all code and commands are literal.

**Type/name consistency:** `NOTIFY_BIN`, `push_ack <priority> <message>`, and the `low`/`normal`/`urgent` vocabulary are used identically in the script edits (Steps 1–4) and the test (Step 6).
