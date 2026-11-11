#!/bin/bash
# slack-event.sh <event> <queue-item> — the side effects of a Slack queue item changing state.
#
#   reaction  (every event)  maps <event> through agent.slack.reactions, adds that emoji to the
#             item's message and removes the emoji of every earlier status. Requires `slack-react`
#             in agent.autonomy.auto_execute.
#   watch     (posted only)  records the item's thread in state/watched-threads.tsv, so a
#             `my-threads` watch job sees later replies.
#
# The target is never an argument: channel and ts come from the item's frontmatter, written by the
# collector, and <queue-item> is reduced to a basename looked up under queue/. A model that runs
# this can choose which of its own queue items to signal on, never which message or which emoji.
#
# Fail-open: always exits 0 except on usage errors (2). Outcomes go to state/slack-events.log.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib-paths.sh"
. "${SCRIPT_DIR}/lib-queue.sh"

EVENT="${1:-}"; ITEM="$(basename "${2:-}")"
case "$EVENT" in
  detected|drafted|posted|rejected|implementing|pr_opened) ;;
  *) echo "usage: slack-event.sh detected|drafted|posted|rejected|implementing|pr_opened <queue-item>" >&2; exit 2 ;;
esac
[[ "$ITEM" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "slack-event: invalid item '${ITEM}'" >&2; exit 2; }

LOG="${EA_AGENT_DIR}/state/slack-events.log"
mkdir -p "${EA_AGENT_DIR}/state"
log() { printf '%s %s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$ITEM" "$*" >> "$LOG"; }

FILE=""
for d in completed rejected drafts incoming; do
  [ -f "${EA_AGENT_DIR}/queue/${d}/${ITEM}" ] && { FILE="${EA_AGENT_DIR}/queue/${d}/${ITEM}"; break; }
done
[ -n "$FILE" ] || { log "no such queue item"; exit 0; }
[ "$(fm "$FILE" source)" = "slack" ] || { log "not a Slack item"; exit 0; }
CH="$(fm "$FILE" channel_id)"; TS="$(fm "$FILE" message_ts)"; PROJECT="$(fm "$FILE" project)"
THREAD="$(fm "$FILE" thread_ts)"; THREAD="${THREAD:-$TS}"
[[ "$CH" =~ ^[A-Z0-9]+$ ]] && [[ "$TS" =~ ^[0-9]+\.[0-9]+$ ]] && [[ "$THREAD" =~ ^[0-9]+\.[0-9]+$ ]] \
  || { log "item has no valid channel_id/message_ts"; exit 0; }

CFG="$("${SCRIPT_DIR}/ea-config.sh" dump 2>/dev/null)"
cfg() { printf '%s\n' "$CFG" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }

# --- thread watch ----------------------------------------------------------------------------------
# Upsert keyed on (channel, thread): re-answering in a watched thread refreshes its TTL. Entries
# older than EA_WATCHED_THREAD_MAX_DAYS are dropped here too, so the file stays bounded even when no
# my-threads job prunes it.
if [ "$EVENT" = posted ] && [[ "$PROJECT" =~ ^[a-z0-9_-]+$ ]]; then
  W="${EA_AGENT_DIR}/state/watched-threads.tsv"; touch "$W"
  now="${EA_NOW:-$(date +%s)}"
  awk -F'\t' -v OFS='\t' -v c="$CH" -v t="$THREAD" -v min="$(( now - ${EA_WATCHED_THREAD_MAX_DAYS:-30} * 86400 ))" \
    '!($1 == c && $2 == t) && $4 >= min' "$W" > "${W}.tmp"
  printf '%s\t%s\t%s.000000\t%s\t%s\n' "$CH" "$THREAD" "$now" "$now" "$PROJECT" >> "${W}.tmp"
  mv "${W}.tmp" "$W"
  log "watching thread ${CH} ${THREAD}"
fi

# --- reaction --------------------------------------------------------------------------------------
printf '%s\n' "$CFG" | grep -qxF 'agent.autonomy.auto_execute[]=slack-react' || exit 0
EMOJI_RE='^[a-z0-9_+-]+$'
emoji="$(cfg "agent.slack.reactions.${EVENT}")"
[ -n "$emoji" ] || exit 0
[[ "$emoji" =~ $EMOJI_RE ]] || { log "invalid emoji name '${emoji}' in agent.slack.reactions.${EVENT}"; exit 0; }

# Statuses replace the ones before them, so the message carries only the latest.
rank() { case "$1" in detected) echo 1 ;; drafted) echo 2 ;; implementing) echo 3 ;; pr_opened) echo 4 ;; *) echo 5 ;; esac; }
old=()
for e in detected drafted implementing pr_opened; do
  [ "$(rank "$e")" -lt "$(rank "$EVENT")" ] || continue
  o="$(cfg "agent.slack.reactions.${e}")"
  [ -n "$o" ] && [ "$o" != "$emoji" ] && [[ "$o" =~ $EMOJI_RE ]] && old+=("$o")
done

w="$(cfg "projects.${PROJECT}.slack.workspace")"; [ -z "$w" ] && w="$(cfg agent.slack.workspace)"
ea_slack_bin "$(cfg agent.slack.method)" "$(cfg agent.slack.bin)" "$w"
slack() { with_timeout "${EA_POLL_CMD_TIMEOUT:-120}" "$SLACK_BIN" "$@" --json ${SLACK_WS[@]+"${SLACK_WS[@]}"} >/dev/null 2>>"$LOG"; }

slack react "$CH" "$TS" "$emoji"; rc=$?
case "$rc" in
  0)  log "reacted :${emoji}: on ${CH} ${TS}" ;;
  64) log "react unsupported on this Slack backend" ;;
  *)  log "react :${emoji}: failed (exit ${rc})" ;;
esac
for o in ${old[@]+"${old[@]}"}; do
  slack unreact "$CH" "$TS" "$o"; rc=$?
  case "$rc" in
    0)  log "removed :${o}:" ;;
    64) log "unreact unsupported on this Slack backend; earlier status reactions stay"; break ;;
    *)  log "unreact :${o}: failed (exit ${rc})" ;;
  esac
done
exit 0
