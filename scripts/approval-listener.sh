#!/bin/bash
# approval-listener.sh — subscribe to the ntfy command topic and execute approvals.
#
# Streams the ntfy command_topic. Each "Approve"/"Reject" button tap on your phone
# arrives here as a message "approve|<item-id>" / "reject|<item-id>". For each new
# message this shells out to a headless `claude -p` running /engineer-agent execute.
#
# Run it under a process supervisor (see install-listener.sh) so it restarts on crash.
#
# SECURITY: on public ntfy.sh, anyone who knows command_topic can publish to it. The
# topic name is a secret — use a high-entropy name and/or an auth_token, or self-host.
# As defense in depth this script (a) accepts only `approve`/`reject` decisions,
# (b) accepts only item ids matching a strict queue-filename pattern, and (c) lets
# execute-item ignore anything no longer sitting in queue/drafts/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib-ntfy.sh
source "${SCRIPT_DIR}/lib-ntfy.sh"

# CLAUDE_BIN can be set in the environment to select a specific Claude Code binary
# (e.g. a version shim or non-standard install path); otherwise discover it on PATH.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "${HOME}/.local/bin/claude")}"

AGENT_DIR="${EA_AGENT_DIR}"
STATE_DIR="${AGENT_DIR}/state"
LOG_FILE="${STATE_DIR}/approval-listener.log"
SEEN_FILE="${STATE_DIR}/ntfy-seen.yaml"
SINCE_FILE="${STATE_DIR}/ntfy-listener.since"

mkdir -p "$STATE_DIR"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE" >&2; }

command -v jq >/dev/null 2>&1 || { log "FATAL: jq is required but not found on PATH"; exit 1; }
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { log "FATAL: claude CLI not found (CLAUDE_BIN='${CLAUDE_BIN}')"; exit 1; }

resolve_ntfy_settings
if [ -z "$NTFY_COMMAND_TOPIC" ]; then
  log "FATAL: agent.notify.ntfy.command_topic is not configured; nothing to listen to"
  exit 1
fi

# First run starts from "now" so we never replay historical approvals.
[ -f "$SINCE_FILE" ] || date +%s > "$SINCE_FILE"
touch "$SEEN_FILE"

AUTH_ARGS=()
[ -n "$NTFY_AUTH_TOKEN" ] && AUTH_ARGS=(-H "Authorization: Bearer ${NTFY_AUTH_TOKEN}")

log "listening on ${NTFY_SERVER}/${NTFY_COMMAND_TOPIC} (plugin: ${PLUGIN_ROOT})"

handle_line() {
  local line="$1" evt id mtime msg decision item
  evt="$(jq -r '.event // empty' <<<"$line" 2>/dev/null)" || return 0
  [ "$evt" = "message" ] || return 0

  id="$(jq -r '.id // empty' <<<"$line")"
  mtime="$(jq -r '.time // empty' <<<"$line")"
  msg="$(jq -r '.message // empty' <<<"$line")"
  [ -n "$id" ] && [ -n "$msg" ] || return 0

  # Idempotency: skip messages we have already acted on.
  if grep -qF "\"${id}\"" "$SEEN_FILE"; then return 0; fi

  decision="${msg%%|*}"
  item="${msg#*|}"

  # Validation / hardening: strict decision + filename allowlist.
  case "$decision" in
    approve|reject) ;;
    *) log "ignoring message ${id}: bad decision '${decision}'"; echo "- \"${id}\"" >> "$SEEN_FILE"; return 0;;
  esac
  if ! [[ "$item" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log "ignoring message ${id}: item '${item}' fails filename allowlist"
    echo "- \"${id}\"" >> "$SEEN_FILE"; return 0
  fi

  log "executing: ${decision} ${item} (msg ${id})"
  echo "- \"${id}\"" >> "$SEEN_FILE"           # record before acting: at-most-once
  [ -n "$mtime" ] && echo "$mtime" > "$SINCE_FILE"

  # Pin --permission-mode so this headless run never inherits the user's global
  # `permissions.defaultMode` (e.g. "plan"): in plan mode claude -p just prints a plan
  # and exits 0 without executing, silently leaving the item in drafts/.
  #
  # Use acceptEdits + a tight --allowedTools allowlist rather than bypassPermissions:
  # execute-item reads UNTRUSTED draft-body content (Slack/Jira/GitHub text), so a
  # prompt-injection payload must not be able to run arbitrary commands. The allowlist is
  # exactly what execute-item / execute.md legitimately need — gh, spy, mv, the plugin's
  # notify.sh, the file-editing tools, and the slite/atlassian MCP tools. Anything else is
  # denied; under acceptEdits a denied tool fails non-interactively, which the drafts/
  # check below surfaces as a WARN (no longer a silent no-op).
  # Redirect stdin from /dev/null so claude doesn't try to read the listener's curl stream.
  local allowed_tools=(
    "Bash(gh *)" "Bash(spy *)" "Bash(mv *)" "Bash(${PLUGIN_ROOT}/scripts/notify.sh *)"
    Read Edit Write Glob Grep
    "mcp__slite__append-blocks" "mcp__slite__create-note" "mcp__atlassian__createJiraIssue"
  )
  "$CLAUDE_BIN" -p \
    --plugin-dir "$PLUGIN_ROOT" \
    --model sonnet \
    --permission-mode acceptEdits \
    --allowedTools "${allowed_tools[@]}" \
    --max-budget-usd 0.50 \
    "Run the engineer-agent execute command (commands/execute.md) for queue item '${item}' with decision '${decision}'. Read config from ~/.claude/engineer-agent/engineer.yaml. Be concise." \
    </dev/null >> "$LOG_FILE" 2>&1

  # Trust the filesystem, not claude -p's exit code (which is 0 whenever the CLI ran,
  # regardless of whether execute-item actually performed the action). execute-item moves
  # the file out of drafts/ on success and leaves it on failure, so its location is the
  # authoritative done/failed signal.
  if [ ! -e "${AGENT_DIR}/queue/drafts/${item}" ]; then
    log "done: ${decision} ${item}"
  else
    log "WARN: ${decision} ${item} did not complete (still in drafts/); see log above. Re-run after fixing."
  fi
}

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
