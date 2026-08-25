#!/bin/bash
# queue-status.sh — the data behind `/engineer-agent status`, computed rather than read out.
#
# WHY: commands/status.md currently has the MODEL do all of this by hand — count files in four
# directories, read state/last-poll.yaml, diff every ISO timestamp against now to render "2h ago",
# re-read the receipt and restate it as prose, then format three markdown tables. Every step is
# `ls | wc -l`, arithmetic, and string formatting. It costs a model turn per invocation and can be
# wrong in ways nothing checks (a mis-added column, a relative time computed against the wrong
# clock, a receipt summarized more optimistically than it reads).
#
# The receipt interpretation rules are the part most worth making executable, because they are
# stated in prose and are easy to get subtly wrong:
#   - status: ok with items_queued: 0 is HEALTHY, not idle-and-suspicious
#   - a non-empty `skipped:` list is NORMAL and must never be reported as a problem
#   - only `partial` / `error`, a non-empty `errors:`, or a stale receipt are worth flagging
#
# Usage: queue-status.sh [--json]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib-paths.sh"
. "${SCRIPT_DIR}/lib-yaml.sh"
. "${SCRIPT_DIR}/lib-time.sh"
. "${SCRIPT_DIR}/lib-queue.sh"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

QUEUE="${EA_AGENT_DIR}/queue"
RECEIPT="${EA_AGENT_DIR}/state/last-poll-receipt.yaml"
STATE="${EA_AGENT_DIR}/state/last-poll.yaml"

count_dir() { [ -d "$QUEUE/$1" ] && queue_items "$1" | wc -l | tr -d ' ' || echo 0; }
INCOMING="$(count_dir incoming)"; DRAFTS="$(count_dir drafts)"
COMPLETED="$(count_dir completed)"; REJECTED="$(count_dir rejected)"

# Items needing attention: everything in drafts/, plus _unrouted items parked in incoming/ (which
# review-queue also surfaces, because a human is the last tier of the routing ladder).
UNROUTED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "$(fm "$f" project)" = "_unrouted" ] && UNROUTED=$((UNROUTED+1))
done < <(queue_items incoming)

# STRANDED is not in commands/status.md today because it could not happen before: items reached
# incoming/ and drafts/ in the same model turn. With a scripted collector a drafting phase can die
# between the two, and such an item is invisible to BOTH approval paths — so surface it here rather
# than let it sit silently.
STRANDED="$(poll_resume_candidates | wc -l | tr -d ' ')"

r_field() { [ -f "$RECEIPT" ] && sed -n "s/^$1: *//p" "$RECEIPT" | head -1 | sed 's/^"//; s/"$//'; }
R_STATUS="$(r_field status)"; R_ITEMS="$(r_field items_queued)"; R_WHEN="$(r_field finished_at)"

# Count the entries of a YAML block list ("errors:" / "skipped:"), handling the inline-empty form
# ("errors: []") too.
#
# NOTE the `done` flag. In awk `exit` still runs the END block, so an END that also prints emits the
# count TWICE — which then reaches printf %d as "12\n12" and errors out. Guard it explicitly.
count_block() {
  local key="$1"
  [ -f "$RECEIPT" ] || { echo 0; return 0; }
  awk -v key="$key" '
    $0 ~ "^" key ":" {
      if ($0 ~ /\[\]/) { print 0; done=1; exit }
      g = 1; n = 0; next
    }
    g && /^[a-z_]+:/ { print n; done=1; exit }
    g && /^[[:space:]]*-/ { n++ }
    END { if (!done) print (g ? n : 0) + 0 }
  ' "$RECEIPT"
}
R_ERRS="$(count_block errors)";   R_ERRS="${R_ERRS:-0}"
R_SKIPPED="$(count_block skipped)"; R_SKIPPED="${R_SKIPPED:-0}"

if [ "$JSON" -eq 1 ]; then
  printf '{"incoming":%d,"drafts":%d,"completed":%d,"rejected":%d,"unrouted":%d,"stranded":%d,' \
    "$INCOMING" "$DRAFTS" "$COMPLETED" "$REJECTED" "$UNROUTED" "$STRANDED"
  printf '"receipt":{"status":"%s","items_queued":"%s","finished_at":"%s","errors":%d,"skipped":%d}}\n' \
    "${R_STATUS:-unknown}" "${R_ITEMS:-0}" "${R_WHEN:-}" "$R_ERRS" "$R_SKIPPED"
  exit 0
fi

echo "Queue"
echo "| Directory | Items |"
echo "|---|---|"
printf '| incoming | %s |\n| drafts | %s |\n| completed | %s |\n| rejected | %s |\n' \
  "$INCOMING" "$DRAFTS" "$COMPLETED" "$REJECTED"
echo
printf 'Awaiting review: %s draft(s)' "$DRAFTS"
[ "$UNROUTED" -gt 0 ] && printf ' + %s unrouted item(s) needing a project' "$UNROUTED"
printf '\n'
if [ "$STRANDED" -gt 0 ]; then
  printf 'WARNING: %s item(s) sit in incoming/ with no draft. They are invisible to every approval\n' "$STRANDED"
  printf '         path until drafted; the next poll re-emits them automatically.\n'
fi
echo

echo "Last poll (per project / per source)"
if [ ! -f "$STATE" ]; then
  echo "  No polls have run yet."
else
  YAML_SEP='|' YAML_DUMP_CACHE="$(YAML_SEP='|' yaml_dump "$STATE")"
  export YAML_DUMP_CACHE
  printf '%s\n' "$YAML_DUMP_CACHE" \
    | grep -E '\|last_checked(_ts)?=' \
    | while IFS= read -r line; do
        key="${line%%=*}"; val="${line#*=}"
        label="$(printf '%s' "$key" | sed -E 's/\|last_checked(_ts)?$//; s/^projects\|//; s/^github_repos\|/repo /; s/^jira_projects\|/jira /; s/\|/ \//')"
        case "$key" in
          *last_checked_ts) printf '  %-46s slack ts %s\n' "$label" "$val" ;;
          *)                printf '  %-46s %s\n' "$label" "$(relative_age "$val")" ;;
        esac
      done
  unset YAML_DUMP_CACHE
fi
echo

echo "Last poll receipt"
if [ ! -f "$RECEIPT" ]; then
  echo "  No receipt — the poll has never recorded a completed run."
else
  printf '  finished %s (%s), status=%s, items_queued=%s\n' \
    "${R_WHEN:-?}" "$(relative_age "${R_WHEN:-}")" "${R_STATUS:-unknown}" "${R_ITEMS:-0}"
  # A non-empty skipped: list is a NORMAL result — a source that is not configured was never
  # going to be polled — so it is reported as information and never as a problem.
  printf '  %s source(s) skipped (not configured — normal)\n' "$R_SKIPPED"
  if [ "$R_ERRS" -gt 0 ]; then
    printf '  PROBLEM: %s configured source(s) failed:\n' "$R_ERRS"
    awk '/^errors:/{g=1;next} g && /^[a-z_]+:/{exit} g && /^[[:space:]]*-/{print "    " $0}' "$RECEIPT"
  fi
  case "${R_STATUS:-}" in
    ok) : ;;
    partial|error) printf '  PROBLEM: poll status is %s\n' "$R_STATUS" ;;
    *) printf '  PROBLEM: receipt has no recognisable status\n' ;;
  esac
fi
