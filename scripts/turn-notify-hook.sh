#!/bin/bash
# turn-notify-hook.sh — Claude Code hook: push an ntfy FYI at the end of every turn of an
# implement-ticket session, so a long walk-away implementation tells you when it finished,
# stalled, paused to ask something, or died.
#
# Registered by hooks/hooks.json for five events, dispatched by $1:
#   arm-skill    PreToolUse(Skill)   — the model invoked engineer-agent:implement-ticket
#   arm-prompt   UserPromptSubmit    — the human typed /engineer-agent:implement-ticket
#   fire         Stop, StopFailure   — a turn ended
#   disarm       SessionEnd          — drop this session's marker
#
# Interactive sessions are armed by a marker file at ${EA_AGENT_DIR}/state/turn-notify/<session_id>.
# The confined headless run in approval-listener.sh is armed instead by EA_TURN_NOTIFY=1, set
# inline on that one `claude -p` process — no file, no session correlation, nothing to clean up
# if it crashes, and the decision is made in plain bash before claude starts (the same posture
# the listener already takes for the worktree and the allowlist).
#
# ---------------------------------------------------------------------------------------------
# THREE INVARIANTS. All load-bearing: hooks/hooks.json registers unconditionally, so this script
# runs on EVERY turn of EVERY session of EVERY project for anyone with the plugin enabled.
#
#  1. ALWAYS EXIT 0, AND NEVER WRITE TO STDOUT.
#     A Stop hook exiting 2 BLOCKS the turn from ending and forces the model to keep going.
#     A PreToolUse hook exiting 2 DENIES the tool. A UserPromptSubmit hook exiting 2 BLOCKS the
#     prompt -- and on exit 0 its STDOUT IS INJECTED INTO THE MODEL'S CONTEXT. So: no `set -e`,
#     no stray echo, no unredirected command. Diagnostics go to state/turn-notify.log, and only
#     when EA_TURN_NOTIFY_DEBUG=1.
#
#  2. NO NEW HARD DEPENDENCY, AND A FREE NEGATIVE PATH.
#     cron-poll.sh makes "deliberately NOT jq" an explicit policy (only the separately-installed
#     approval-listener.sh may require it), and a plugin-wide hook is even more dependency-
#     sensitive than the cron. Every field needed to DECIDE WHETHER TO PUSH is escape-free by
#     construction (uuid / enum / skill slug / anchored raw-JSON prefix) and is read with sed.
#     jq is used for exactly one thing -- extracting the free-text last_assistant_message for the
#     excerpt -- so no jq means a label-only push, never a broken hook.
#     When nothing is armed the whole script costs: one `cat`, one source, one `test -d`, one
#     glob. No config read, no awk, no jq, no network.
#
#  3. NOTHING TAPPABLE REACHES THE PHONE.
#     No --source-url is passed, so the push carries no action buttons and no Open link. The
#     excerpt is model-authored text ultimately derived from UNTRUSTED ticket/PR/Slack bodies,
#     and ntfy's mobile clients autolink URLs in the message body -- so an injected line could
#     otherwise render a tappable link inside a notification arriving on the very topic the user
#     has been trained to trust for Approve/Reject, aimed at someone who is by construction away
#     from their desk. sanitize_text() strips every scheme:// URL, www. host, and mailto: before
#     anything hits the wire. RESIDUAL, ACCEPTED: a bare "evil.tld" with no scheme can still be
#     autolinked by some clients; neutralizing that would also destroy "notify.sh"/"SKILL.md" and
#     is not worth it, given the excerpt is the model's own summary rather than a quote.

set -uo pipefail   # NOT -e: no failure here may become a non-zero exit (invariant 1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
source "${SCRIPT_DIR}/lib-paths.sh"   # EA_AGENT_DIR + yaml_agent_notify

MODE="${1:-fire}"
MARKER_DIR="${EA_AGENT_DIR}/state/turn-notify"
DEBUG_LOG="${EA_AGENT_DIR}/state/turn-notify.log"
# Overridable so tests can point at a stub notifier. Mirrors approval-listener.sh's NOTIFY_BIN.
NOTIFY_BIN="${NOTIFY_BIN:-${SCRIPT_DIR}/notify.sh}"
MAX_TURNS="${EA_TURN_NOTIFY_MAX:-40}"

# Read the payload FIRST, before any early return: Claude Code writes it to our stdin, and a hook
# that exits without draining risks EPIPE on the writer. This is also ralph-loop's shipping
# pattern (the only other Stop hook installed here). It costs one fork either way, so the
# ordering is free.
HOOK_INPUT="$(cat)"

dbg() {
  [ "${EA_TURN_NOTIFY_DEBUG:-0}" = "1" ] || return 0
  mkdir -p "${EA_AGENT_DIR}/state" 2>/dev/null
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${MODE}: $*" >> "$DEBUG_LOG" 2>/dev/null
  return 0
}

# json_str <key> — pull a scalar out of the payload WITHOUT jq.
# Safe ONLY for escape-free values (session_id is a uuid, hook_event_name an enum, skill a slug).
# The [^"\\] class means a value containing any escape yields nothing: fail-closed on the value,
# never non-zero on the exit code. Note `.*` is greedy, so if free text elsewhere in the payload
# contains a literal `"session_id":"…"` we'd read that instead -- which then fails safe_session()
# or simply matches no marker, i.e. no push. Never use this on last_assistant_message.
json_str() {
  printf '%s' "$HOOK_INPUT" \
    | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' \
    | head -1
}

# A session id we are willing to turn into a filename. Anything else: no marker, no push.
safe_session() {
  case "${1:-}" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
  [ "${#1}" -le 64 ]
}

# sanitize_label — script-controlled values (the queue item id, already validated
# ^[A-Za-z0-9._-]+$ by the listener, or the literal "implement-ticket"). Belt and braces.
sanitize_label() {
  printf '%s' "${1:-}" | tr -d '\000-\037' | tr -c 'A-Za-z0-9._:#-' '_' | cut -c1-64
}

# sanitize_text — invariant 3. Order matters: kill links BEFORE flattening whitespace, so a URL
# broken across lines cannot be reassembled into a live one afterwards.
sanitize_text() {
  printf '%s' "${1:-}" \
    | sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*#(link)#g; s#\bwww\.[^[:space:]]*#(link)#g; s#\bmailto:[^[:space:]]*#(link)#g' \
    | tr '\n\r\t' '   ' \
    | tr -d '\000-\037' \
    | sed -E 's/  +/ /g; s/^ +//; s/ +$//' \
    | cut -c1-180
}

# The opt-in gate. Checked at ARM time only -- never in fire() -- so a session that was never
# armed costs no config read. Env override mirrors the EA_NTFY_* convention.
enabled() {
  case "${EA_TURN_NOTIFY_ENABLED:-$(yaml_agent_notify turn_completions)}" in
    true|yes|1|on) return 0;;
    *)             return 1;;
  esac
}

arm() {
  local label="$1" sid
  enabled || { dbg "not enabled; not arming"; return 0; }
  sid="$(json_str session_id)"
  safe_session "$sid" || { dbg "unusable session_id; not arming"; return 0; }
  mkdir -p "$MARKER_DIR" 2>/dev/null || return 0
  # Reap markers from sessions that crashed before SessionEnd. Only ever runs on the arm path
  # (rare), never on Stop -- the hot path must not fork find on every turn.
  find "$MARKER_DIR" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null
  if [ ! -f "${MARKER_DIR}/${sid}" ]; then
    printf '%s\n0\n' "$(sanitize_label "$label")" > "${MARKER_DIR}/${sid}" 2>/dev/null
    dbg "armed ${sid} (${label})"
  fi
  return 0
}

# send — best-effort, and DETACHED by default: notify.sh does network I/O and nothing may delay
# the end of a turn. setsid where available (survives the parent's process group being torn down
# when `claude -p` exits immediately after Stop), plain background otherwise. Tests set
# EA_TURN_NOTIFY_SYNC=1 to make it observable.
send() {
  local priority="$1" tags="$2" title="$3" message="$4"
  dbg "push priority=${priority} title=${title}"
  if [ "${EA_TURN_NOTIFY_SYNC:-0}" = "1" ]; then
    "$NOTIFY_BIN" --fyi --title "$title" --priority "$priority" --tags "$tags" \
      --message "$message" </dev/null >/dev/null 2>&1
  elif command -v setsid >/dev/null 2>&1; then
    setsid "$NOTIFY_BIN" --fyi --title "$title" --priority "$priority" --tags "$tags" \
      --message "$message" </dev/null >/dev/null 2>&1 &
  else
    ( "$NOTIFY_BIN" --fyi --title "$title" --priority "$priority" --tags "$tags" \
      --message "$message" </dev/null >/dev/null 2>&1 & )
  fi
  return 0
}

fire() {
  local label turn sid marker cwd cwdb evt excerpt err priority tags message

  if [ "${EA_TURN_NOTIFY:-0}" = "1" ]; then
    # Headless: armed by the listener's inline env. One turn per run, so no counter, no marker.
    label="$(sanitize_label "${EA_TURN_NOTIFY_LABEL:-implement-ticket}")"
    turn=""
  else
    # Interactive: the cheapest possible negative test first -- a test -d and one glob, no forks.
    [ -d "$MARKER_DIR" ] || return 0
    set -- "$MARKER_DIR"/*
    [ -e "$1" ] || return 0
    sid="$(json_str session_id)"
    safe_session "$sid" || return 0
    marker="${MARKER_DIR}/${sid}"
    [ -f "$marker" ] || return 0
    label="$(sed -n 1p "$marker")"
    turn=$(( $(sed -n 2p "$marker" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n%s\n' "$label" "$turn" > "$marker" 2>/dev/null
    # Runaway guard: a session that keeps re-invoking the skill can't buzz forever. One "muted"
    # push at the boundary so the silence afterwards is explained rather than mysterious.
    if [ "$turn" -gt "$MAX_TURNS" ]; then
      [ "$turn" -eq $(( MAX_TURNS + 1 )) ] || return 0
      send low mute "engineer-agent" "🔕 Muted after ${MAX_TURNS} turns: ${label}"
      return 0
    fi
  fi

  cwd="$(json_str cwd)"; cwdb="$(basename "${cwd:-$PWD}")"
  evt="$(json_str hook_event_name)"

  if [ "$evt" = "StopFailure" ]; then
    # `error` is the API/transport failure string, not model output -- but sanitize anyway.
    err="$(sanitize_text "$(json_str error)")"
    priority=urgent; tags=rotating_light
    message="🛑 Turn${turn:+ ${turn}} failed · ${label} (${cwdb}) — ${err:-unknown error}"
  else
    # The one field that needs real JSON decoding. No jq ⇒ no excerpt ⇒ label-only push.
    if command -v jq >/dev/null 2>&1; then
      excerpt="$(sanitize_text "$(printf '%s' "$HOOK_INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)")"
    else
      excerpt=""
    fi
    priority=normal; tags=bell
    message="🔔 Turn${turn:+ ${turn}} complete · ${label} (${cwdb})"
    [ -n "$excerpt" ] && message="${message}
${excerpt}"
  fi

  send "$priority" "$tags" "engineer-agent" "$message"
  return 0
}

case "$MODE" in
  arm-skill)
    # Raw-JSON match, no extraction. Only the plugin's namespaced skill arms: a DIFFERENT,
    # same-named user-level skill may exist at ~/.claude/skills/implement-ticket, and it is
    # deliberately out of scope. Because that collision forces disambiguation, the plugin's
    # skill is invoked by its namespaced name -- but if the user-level skill is ever removed,
    # the plugin's could be invoked bare and this matcher would stop firing. arm-prompt is the
    # independent backstop for exactly that case.
    printf '%s' "$HOOK_INPUT" \
      | grep -qE '"skill"[[:space:]]*:[[:space:]]*"engineer-agent:implement-ticket"' \
      && arm "implement-ticket"
    ;;
  arm-prompt)
    # ANCHORED on the prompt field's opening quote, so merely discussing implement-ticket
    # mid-conversation (a planning session, say) does not arm. The slash-command text contains
    # nothing JSON-escapable, so it survives encoding byte for byte.
    printf '%s' "$HOOK_INPUT" \
      | grep -qE '"prompt"[[:space:]]*:[[:space:]]*"/engineer-agent[: ]implement-ticket' \
      && arm "implement-ticket"
    ;;
  fire)
    fire
    ;;
  disarm)
    sid="$(json_str session_id)"
    if safe_session "${sid:-}"; then rm -f "${MARKER_DIR}/${sid}" 2>/dev/null; dbg "disarmed ${sid}"; fi
    ;;
  *)
    dbg "unknown mode"
    ;;
esac

exit 0
