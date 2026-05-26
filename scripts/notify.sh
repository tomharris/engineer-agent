#!/bin/bash
# notify.sh — publish an engineer-agent notification to ntfy.
#
# Reads ntfy settings from ~/.claude/engineer-agent/engineer.yaml under
# agent.notify.ntfy (server, topic, command_topic, auth_token), or from
# EA_NTFY_* env vars which take precedence. If no topic can be resolved it
# logs a warning and exits 0 — so installs without ntfy configured keep working.
#
# Usage:
#   notify.sh --title T --message M [--priority urgent|normal|low] [--tags t1,t2]
#             [--item-id ID --source-url URL]   # adds Approve/Reject/Open buttons
#             [--fyi]                            # no action buttons (confirmations)
#
# With --item-id + --source-url and without --fyi, the notification carries
# three action buttons. Approve/Reject are ntfy `http` actions that POST a
# command ("approve|ID" / "reject|ID") to the command_topic; approval-listener.sh
# picks those up. Open is a `view` action linking to the source URL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-ntfy.sh
source "${SCRIPT_DIR}/lib-ntfy.sh"

AGENT_DIR="${EA_AGENT_DIR}"
LOG_FILE="${AGENT_DIR}/state/notify.log"

log() { mkdir -p "${AGENT_DIR}/state"; echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"; }

# --- Resolve ntfy connection settings (env overrides config) ---
resolve_ntfy_settings
SERVER="$NTFY_SERVER"
TOPIC="$NTFY_TOPIC"
COMMAND_TOPIC="$NTFY_COMMAND_TOPIC"
AUTH_TOKEN="$NTFY_AUTH_TOKEN"

# --- Parse args ---
TITLE=""; MESSAGE=""; PRIORITY="normal"; TAGS=""; ITEM_ID=""; SOURCE_URL=""; FYI=0
while [ $# -gt 0 ]; do
  case "$1" in
    --title)      TITLE="$2"; shift 2;;
    --message)    MESSAGE="$2"; shift 2;;
    --priority)   PRIORITY="$2"; shift 2;;
    --tags)       TAGS="$2"; shift 2;;
    --item-id)    ITEM_ID="$2"; shift 2;;
    --source-url) SOURCE_URL="$2"; shift 2;;
    --fyi)        FYI=1; shift;;
    *) echo "notify.sh: unknown arg: $1" >&2; exit 2;;
  esac
done

if [ -z "$TOPIC" ]; then
  log "WARN: agent.notify.ntfy.topic not configured; skipping notification (title=${TITLE})"
  exit 0
fi

# Map engineer-agent priority -> ntfy priority (max,high,default,low,min).
case "$PRIORITY" in
  urgent) NTFY_PRIORITY="high";;
  low)    NTFY_PRIORITY="low";;
  *)      NTFY_PRIORITY="default";;
esac

# --- Build curl args ---
ARGS=(-s -X POST)
[ -n "$AUTH_TOKEN" ] && ARGS+=(-H "Authorization: Bearer ${AUTH_TOKEN}")
[ -n "$TITLE" ]      && ARGS+=(-H "Title: ${TITLE}")
ARGS+=(-H "Priority: ${NTFY_PRIORITY}")
[ -n "$TAGS" ]       && ARGS+=(-H "Tags: ${TAGS}")

# Action buttons: only for actionable items (have an id + command topic + not FYI).
if [ "$FYI" -eq 0 ] && [ -n "$ITEM_ID" ] && [ -n "$COMMAND_TOPIC" ]; then
  CMD_URL="${SERVER%/}/${COMMAND_TOPIC}"
  HDR=""
  [ -n "$AUTH_TOKEN" ] && HDR=", headers.Authorization=Bearer ${AUTH_TOKEN}"
  ACTIONS="http, Approve, ${CMD_URL}, method=POST, body=approve|${ITEM_ID}${HDR}, clear=true"
  ACTIONS="${ACTIONS}; http, Reject, ${CMD_URL}, method=POST, body=reject|${ITEM_ID}${HDR}, clear=true"
  [ -n "$SOURCE_URL" ] && ACTIONS="${ACTIONS}; view, Open, ${SOURCE_URL}, clear=false"
  ARGS+=(-H "Actions: ${ACTIONS}")
elif [ -n "$SOURCE_URL" ]; then
  # FYI / confirmation: a single Open button is still handy, no command actions.
  ARGS+=(-H "Actions: view, Open, ${SOURCE_URL}, clear=false")
fi

ARGS+=(-d "${MESSAGE}")
ARGS+=("${SERVER%/}/${TOPIC}")

if curl "${ARGS[@]}" >/dev/null 2>>"$LOG_FILE"; then
  log "sent: title='${TITLE}' priority=${NTFY_PRIORITY} item=${ITEM_ID:-none}"
else
  log "ERROR: ntfy publish failed (title=${TITLE})"
  exit 0   # never let a notification failure break the calling workflow
fi
