#!/bin/bash
# Integration test for turn-notify-hook.sh (the Stop-hook turn-completion push) and for the
# listener's env-arming of the confined ticket run.
#
# No framework, mirroring tests/approval-listener.test.sh: an isolated EA_AGENT_DIR, a stub
# notifier recorded via NOTIFY_BIN, payloads piped in on stdin, assertions on the recorded calls.
#
# Run: bash tests/turn-notify.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../scripts/turn-notify-hook.sh"
LISTENER="${SCRIPT_DIR}/../scripts/approval-listener.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

setup() {
  TMP="$(mktemp -d)"
  export EA_AGENT_DIR="$TMP/agent"
  export EA_CONFIG_FILE="$EA_AGENT_DIR/engineer.yaml"
  mkdir -p "$EA_AGENT_DIR/state"

  export NOTIFY_LOG="$TMP/notify.log"; : > "$NOTIFY_LOG"
  export NOTIFY_BIN="$TMP/fake-notify"
  # ONE line per call: a real message spans two lines (headline + excerpt), so a line count
  # would over-report the number of pushes. Newlines become "|" so the content stays greppable.
  cat > "$NOTIFY_BIN" <<'EOF'
#!/bin/bash
printf 'CALL %s\n' "$(printf '%s' "$*" | tr '\n' '|')" >> "$NOTIFY_LOG"
exit 0
EOF
  chmod +x "$NOTIFY_BIN"

  # Synchronous so the assertions can see the call; production detaches it.
  export EA_TURN_NOTIFY_SYNC=1
  export EA_TURN_NOTIFY_ENABLED=1
  unset EA_TURN_NOTIFY EA_TURN_NOTIFY_LABEL EA_TURN_NOTIFY_MAX 2>/dev/null
}
teardown() { rm -rf "$TMP"; unset EA_TURN_NOTIFY EA_TURN_NOTIFY_LABEL EA_TURN_NOTIFY_MAX; }

hook()  { printf '%s' "$2" | bash "$HOOK" "$1"; }
# NB: `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` fallback would print twice.
calls() { local c; c="$(grep -c '^CALL ' "$NOTIFY_LOG" 2>/dev/null)"; echo "${c:-0}"; }
markers() { ls "$EA_AGENT_DIR/state/turn-notify" 2>/dev/null | tr '\n' ' '; }

stop_payload()  { printf '{"session_id":"%s","cwd":"/home/t/Projects/my-api","hook_event_name":"Stop","last_assistant_message":"%s"}' "$1" "${2:-done}"; }

# --- Case 1: nothing armed -> completely silent (the path every other project takes) ---
test_negative_path_is_silent() {
  echo "test_negative_path_is_silent:"
  setup
  hook fire "$(stop_payload s1)"; local e=$?
  [ "$e" -eq 0 ] && ok "exit 0" || bad "exit $e"
  [ "$(calls)" = "0" ] && ok "no push when nothing is armed" || bad "pushed without being armed"
  teardown
}

# --- Case 2: arming, positive and negative ---
test_arming() {
  echo "test_arming:"
  setup
  hook arm-prompt '{"session_id":"s-slash","prompt":"/engineer-agent:implement-ticket ENG-412"}'
  hook arm-prompt '{"session_id":"s-space","prompt":"/engineer-agent implement-ticket ENG-9"}'
  hook arm-prompt '{"session_id":"s-talk","prompt":"how does implement-ticket pick the base branch?"}'
  hook arm-skill  '{"session_id":"s-skill","tool_name":"Skill","tool_input":{"skill":"engineer-agent:implement-ticket"}}'
  hook arm-skill  '{"session_id":"s-bare","tool_name":"Skill","tool_input":{"skill":"implement-ticket"}}'
  hook arm-skill  '{"session_id":"s-other","tool_name":"Skill","tool_input":{"skill":"engineer-agent:review-pr"}}'
  local m; m="$(markers)"
  case "$m" in *s-slash*) ok "slash command arms";;      *) bad "slash command did not arm ($m)";; esac
  case "$m" in *s-space*) ok "space form arms";;         *) bad "space form did not arm ($m)";; esac
  case "$m" in *s-skill*) ok "namespaced Skill call arms";; *) bad "namespaced Skill call did not arm ($m)";; esac
  case "$m" in *s-talk*)  bad "merely discussing implement-ticket armed ($m)";; *) ok "discussion does NOT arm";; esac
  case "$m" in *s-bare*)  bad "bare user-level skill armed ($m)";;              *) ok "bare user-level skill does NOT arm";; esac
  case "$m" in *s-other*) bad "an unrelated skill armed ($m)";;                 *) ok "unrelated skill does NOT arm";; esac
  teardown
}

# --- Case 3: the opt-in gate ---
test_disabled_by_default() {
  echo "test_disabled_by_default:"
  setup
  unset EA_TURN_NOTIFY_ENABLED             # fall through to config, which has no notify block
  printf 'agent:\n  branch_prefix: "x"\n' > "$EA_CONFIG_FILE"
  hook arm-prompt '{"session_id":"s1","prompt":"/engineer-agent:implement-ticket X"}'
  [ -z "$(markers)" ] && ok "no config key => not armed" || bad "armed with no config key"

  printf 'agent:\n  notify:\n    turn_completions: true\n    ntfy:\n      topic: "t"\n' > "$EA_CONFIG_FILE"
  hook arm-prompt '{"session_id":"s2","prompt":"/engineer-agent:implement-ticket X"}'
  case "$(markers)" in *s2*) ok "turn_completions: true => armed";; *) bad "config key true did not arm";; esac

  printf 'agent:\n  notify:\n    turn_completions: false\n' > "$EA_CONFIG_FILE"
  hook arm-prompt '{"session_id":"s3","prompt":"/engineer-agent:implement-ticket X"}'
  case "$(markers)" in *s3*) bad "turn_completions: false armed anyway";; *) ok "turn_completions: false => not armed";; esac
  teardown
}

# --- Case 4: interactive fire — counter, label, cwd basename ---
test_interactive_fire() {
  echo "test_interactive_fire:"
  setup
  hook arm-prompt '{"session_id":"s1","prompt":"/engineer-agent:implement-ticket ENG-412"}'
  hook fire "$(stop_payload s1 'first turn')"
  hook fire "$(stop_payload s1 'second turn')"
  [ "$(calls)" = "2" ] && ok "one push per turn" || bad "expected 2 pushes, got $(calls)"
  grep -q "Turn 1 complete" "$NOTIFY_LOG" && grep -q "Turn 2 complete" "$NOTIFY_LOG" \
    && ok "turn counter increments" || bad "turn counter wrong: $(cat "$NOTIFY_LOG")"
  grep -q "(my-api)" "$NOTIFY_LOG" \
    && ok "cwd basename from the payload, not \$PWD" || bad "cwd basename missing"
  grep -q -- "--priority normal" "$NOTIFY_LOG" && grep -q -- "--tags bell" "$NOTIFY_LOG" \
    && ok "Stop uses normal/bell" || bad "wrong priority/tags for Stop"
  grep -q -- "--fyi" "$NOTIFY_LOG" && ok "FYI: no Approve/Reject buttons" || bad "not sent as --fyi"
  grep -q -- "--source-url" "$NOTIFY_LOG" && bad "source-url would add a tappable Open button" \
    || ok "no --source-url: nothing tappable"
  teardown
}

# --- Case 5: invariant 3 — no live URL can reach the wire ---
test_urls_are_neutralized() {
  echo "test_urls_are_neutralized:"
  setup
  hook arm-prompt '{"session_id":"s1","prompt":"/engineer-agent:implement-ticket X"}'
  hook fire '{"session_id":"s1","cwd":"/r/api","hook_event_name":"Stop","last_assistant_message":"see https://evil.tld/a and www.evil.tld/b and mailto:x@evil.tld and ftp://evil.tld/c"}'
  grep -qE 'https?://|www\.|mailto:|ftp://' "$NOTIFY_LOG" \
    && bad "a live URL survived sanitizing: $(cat "$NOTIFY_LOG")" \
    || ok "http/www/mailto/ftp all neutralized"
  [ "$(grep -c '(link)' "$NOTIFY_LOG")" -ge 1 ] && ok "replaced with (link)" || bad "(link) placeholder missing"

  # A URL split across a newline must not be reassembled into a live one by whitespace collapsing.
  : > "$NOTIFY_LOG"
  hook fire '{"session_id":"s1","cwd":"/r/api","hook_event_name":"Stop","last_assistant_message":"https://evil.tld/\npath"}'
  grep -q "https://" "$NOTIFY_LOG" && bad "newline-split URL reassembled" || ok "newline-split URL stays dead"
  teardown
}

# --- Case 6: StopFailure is louder and carries the API error ---
test_stop_failure() {
  echo "test_stop_failure:"
  setup
  hook arm-prompt '{"session_id":"s1","prompt":"/engineer-agent:implement-ticket X"}'
  hook fire '{"session_id":"s1","cwd":"/r/api","hook_event_name":"StopFailure","error":"API Error: 529 overloaded"}'
  grep -q -- "--priority urgent" "$NOTIFY_LOG" \
    && ok "StopFailure is urgent" || bad "StopFailure not urgent: $(cat "$NOTIFY_LOG")"
  grep -q "529 overloaded" "$NOTIFY_LOG" && ok "error text included" || bad "error text missing"
  grep -q "failed" "$NOTIFY_LOG" && ok "message says failed" || bad "message does not say failed"
  teardown
}

# --- Case 7: marker lifecycle ---
test_disarm() {
  echo "test_disarm:"
  setup
  hook arm-prompt '{"session_id":"s1","prompt":"/engineer-agent:implement-ticket X"}'
  hook disarm '{"session_id":"s1","hook_event_name":"SessionEnd","reason":"other"}'
  [ -z "$(markers)" ] && ok "SessionEnd removes the marker" || bad "marker survived SessionEnd"
  : > "$NOTIFY_LOG"
  hook fire "$(stop_payload s1)"
  [ "$(calls)" = "0" ] && ok "silent after disarm" || bad "pushed after disarm"
  teardown
}

# --- Case 8: runaway guard ---
test_turn_cap() {
  echo "test_turn_cap:"
  setup
  export EA_TURN_NOTIFY_MAX=3
  hook arm-prompt '{"session_id":"s1","prompt":"/engineer-agent:implement-ticket X"}'
  local i; for i in 1 2 3 4 5 6; do hook fire "$(stop_payload s1 "t$i")"; done
  [ "$(calls)" = "4" ] && ok "3 turns + exactly one mute, then silence" \
    || bad "expected 4 pushes (3 + mute), got $(calls): $(cat "$NOTIFY_LOG")"
  grep -q "Muted after 3 turns" "$NOTIFY_LOG" && ok "mute push explains the silence" || bad "no mute push"
  teardown
}

# --- Case 9: invariant 1 — can never block a turn, can never speak into model context ---
test_never_blocks_or_speaks() {
  echo "test_never_blocks_or_speaks:"
  setup
  local m p e n out="$TMP/stdout"
  for m in arm-skill arm-prompt fire disarm bogus-mode; do
    for p in '' '{' 'not json at all' '{"session_id":"../../etc/passwd","hook_event_name":"Stop"}'; do
      # Capture the hook's OWN exit status — not a pipeline's — hence the redirect to a file.
      printf '%s' "$p" | bash "$HOOK" "$m" >"$out" 2>/dev/null
      e=$?
      n="$(wc -c < "$out" | tr -d ' ')"
      [ "$e" -eq 0 ] || bad "mode=$m payload='$p' exited $e"
      [ "$n" -eq 0 ] || bad "mode=$m payload='$p' wrote $n bytes to stdout"
    done
  done
  ok "exit 0 and zero stdout for every mode x malformed payload"
  [ -z "$(markers)" ] && ok "traversal session_id creates no marker" || bad "traversal marker created: $(markers)"

  printf '{"session_id":"s1","hook_event_name":"Stop"}' \
    | EA_TURN_NOTIFY=1 NOTIFY_BIN=/nonexistent/notify.sh bash "$HOOK" fire >/dev/null 2>&1
  [ $? -eq 0 ] && ok "exit 0 even when the notifier is missing" || bad "missing notifier changed the exit code"
  teardown
}

# --- Case 10: headless env-arming needs no marker and no config read ---
test_headless_env_arming() {
  echo "test_headless_env_arming:"
  setup
  unset EA_TURN_NOTIFY_ENABLED             # fire() must not consult the config at all
  rm -f "$EA_CONFIG_FILE"
  EA_TURN_NOTIFY=1 EA_TURN_NOTIFY_LABEL=20260716-000000-ticket-gh-1 \
    hook fire '{"session_id":"whatever","cwd":"/wt/x","hook_event_name":"Stop","last_assistant_message":"Opened draft PR."}'
  [ "$(calls)" = "1" ] && ok "env-armed run pushes with no marker and no config" \
    || bad "expected 1 push, got $(calls)"
  grep -q "20260716-000000-ticket-gh-1" "$NOTIFY_LOG" && ok "label is the queue item id" || bad "label missing"
  [ -z "$(markers)" ] && ok "no marker file created" || bad "headless path left a marker: $(markers)"
  teardown
}

# --- Case 11: the listener arms the confined ticket run (and only that run) ---
listener_setup() {
  TMP="$(mktemp -d)"
  export EA_AGENT_DIR="$TMP/agent"
  export EA_CONFIG_FILE="$EA_AGENT_DIR/engineer.yaml"
  mkdir -p "$EA_AGENT_DIR/queue/drafts" "$EA_AGENT_DIR/queue/completed" "$EA_AGENT_DIR/state" "$TMP/repo"
  export EA_NTFY_SERVER="https://example.invalid" EA_NTFY_TOPIC="t" EA_NTFY_COMMAND_TOPIC="c" EA_NTFY_AUTH_TOKEN=""
  export NOTIFY_LOG="$TMP/notify.log"; : > "$NOTIFY_LOG"
  export NOTIFY_BIN="$TMP/fake-notify"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$NOTIFY_LOG"\n' > "$NOTIFY_BIN"; chmod +x "$NOTIFY_BIN"

  # Fake claude that records the ENVIRONMENT it was handed, not just its args — the whole point
  # of this case is that EA_TURN_NOTIFY crosses the process boundary.
  export CLAUDE_ENV_LOG="$TMP/claude-env.log"; : > "$CLAUDE_ENV_LOG"
  export CLAUDE_BIN="$TMP/fake-claude"
  cat > "$CLAUDE_BIN" <<'EOF'
#!/bin/bash
kind=impl
printf '%s' "$*" | grep -q "Generate a QA test plan" && kind=qa
printf '%s EA_TURN_NOTIFY=%s LABEL=%s\n' "$kind" "${EA_TURN_NOTIFY:-<unset>}" "${EA_TURN_NOTIFY_LABEL:-<unset>}" >> "$CLAUDE_ENV_LOG"
[ "$kind" = "qa" ] && exit 0
mkdir -p "$EA_AGENT_DIR/queue/completed"
for f in "$EA_AGENT_DIR"/queue/drafts/*.md; do cp "$f" "$EA_AGENT_DIR/queue/completed/"; done
exit 0
EOF
  chmod +x "$CLAUDE_BIN"

  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/git" <<'EOF'
#!/bin/bash
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[i]}" in
    symbolic-ref) echo "origin/main"; exit 0;;
    worktree) if [ "${args[i+1]}" = "add" ]; then
                for ((j=i+2;j<${#args[@]};j++)); do [ "${args[j]}" = "--detach" ] && { mkdir -p "${args[j+1]}"; break; }; done
              fi; exit 0;;
  esac
done
exit 0
EOF
  chmod +x "$TMP/bin/git"; export PATH="$TMP/bin:$PATH"
}

write_listener_config() {   # $1 = turn_completions value or "" to omit; $2 = "with-qa" (optional)
  {
    printf 'agent:\n  branch_prefix: "x"\n'
    [ -n "$1" ] && printf '  notify:\n    turn_completions: %s\n    ntfy:\n      topic: "t"\n' "$1"
    printf 'projects:\n  wayfinder-api:\n    path: "%s"\n' "$TMP/repo"
    printf '    exec:\n      allowed_commands:\n        - "bundle"\n'
    [ "${2:-}" = "with-qa" ] && printf '    qa:\n      base_url: "http://localhost:3000"\n'
  } > "$EA_CONFIG_FILE"
}

test_listener_arms_ticket_run() {
  echo "test_listener_arms_ticket_run:"
  listener_setup
  write_listener_config true with-qa
  # shellcheck disable=SC1090
  source "$LISTENER"
  local item="20260716-000000-ticket-gh-1.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  handle_line '{"event":"message","id":"i1","time":1,"message":"approve|'"$item"'"}'

  grep -q "^impl EA_TURN_NOTIFY=1 LABEL=20260716-000000-ticket-gh-1$" "$CLAUDE_ENV_LOG" \
    && ok "implementation run armed, label = item id without .md" \
    || bad "implementation run not armed: $(cat "$CLAUDE_ENV_LOG")"
  grep -q "^qa EA_TURN_NOTIFY=1" "$CLAUDE_ENV_LOG" \
    && bad "the QA run inherited the arm (it must stay silent): $(cat "$CLAUDE_ENV_LOG")" \
    || ok "QA run is NOT armed"
  rm -rf "$TMP"
}

test_listener_does_not_arm_when_disabled() {
  echo "test_listener_does_not_arm_when_disabled:"
  listener_setup
  write_listener_config ""     # no notify block at all — the default for existing installs
  # shellcheck disable=SC1090
  source "$LISTENER"
  local item="20260716-000000-ticket-gh-2.md"
  printf 'type: ticket\nproject: wayfinder-api\n' > "$EA_AGENT_DIR/queue/drafts/$item"
  handle_line '{"event":"message","id":"i2","time":1,"message":"approve|'"$item"'"}'
  grep -q "^impl EA_TURN_NOTIFY=0 " "$CLAUDE_ENV_LOG" \
    && ok "no config key => EA_TURN_NOTIFY=0 (existing installs unchanged)" \
    || bad "expected EA_TURN_NOTIFY=0: $(cat "$CLAUDE_ENV_LOG")"
  rm -rf "$TMP"
}

# The listener cases source approval-listener.sh, which defines its own globals. Run them LAST so
# that leakage cannot reach the hook-only cases (they can't be subshelled — the PASS/FAIL counters
# would not survive).
test_negative_path_is_silent
test_arming
test_disabled_by_default
test_interactive_fire
test_urls_are_neutralized
test_stop_failure
test_disarm
test_turn_cap
test_never_blocks_or_speaks
test_headless_env_arming
test_listener_arms_ticket_run
test_listener_does_not_arm_when_disabled

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
