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

# The other stranding shape: a FINISHED draft parked in incoming/. Counted separately because the
# remedy differs (a move, not a re-draft) and because reporting them as one number hid a real
# outage — this count was the missing half, so `status` read `stranded: 0` for eight weeks while
# five verified audit findings sat unapprovable. cron-poll heals these, so a non-zero here means
# the heal declined (a name collision with drafts/) or the poll has not run since they appeared.
STRANDED_DRAFTED="$(poll_stranded_drafted | wc -l | tr -d ' ')"

# Duplicates that queue-dedup-check could not auto-heal. This is reported HERE, on demand, because
# the poll deliberately pushes about a given duplicate only once (see cron-poll.sh) — a warning
# re-sent every 15 minutes trains you to ignore the topic your Approve/Reject buttons arrive on.
# Pushed once, visible always: that trade only works if `status` actually shows it.
DUPES="$("${SCRIPT_DIR}/queue-dedup-check.sh" --keys 2>/dev/null | grep -c . || true)"
DUPES="${DUPES:-0}"

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

# --- Scheduled jobs: discovery coverage and health ----------------------------------------------
. "${SCRIPT_DIR}/lib-jobs.sh"
jobs_cfg_load
JOB_ROWS="$(jobs_enumerate)"
J_OK=0; J_PARTIAL=0; J_ERROR=0; J_PAUSED=0; J_INVALID=0; J_NEVER=0; UNCOVERED=0
DISCOVERY=""; JOB_PROBLEMS=""; JOB_STATES=""
nl='
'

job_first_error() {
  awk '/^errors:/ {f=1; next} f && /^  - / {sub(/^  - "?/, ""); sub(/"$/, ""); print; exit}' \
    "$(job_path "$1" receipt)" 2>/dev/null
}
# job_state <row> — invalid | paused | ok | partial | error | never
job_state() {
  local slug id rest key
  IFS='|' read -r slug _ id rest <<< "$1"
  key="$(job_key "$slug" "$id")"
  if ! jobs_validate "$1" "$JOB_ROWS" >/dev/null; then echo invalid
  elif job_is_paused "$key"; then echo paused
  else
    case "$(job_receipt_field "$key" status)" in
      ok|partial|error) job_receipt_field "$key" status ;;
      *) echo never ;;
    esac
  fi
}

while IFS= read -r row; do
  [ -n "$row" ] || continue
  IFS='|' read -r slug _ id _ <<< "$row"
  key="$(job_key "$slug" "$id")"
  st="$(job_state "$row")"
  JOB_STATES="${JOB_STATES}${key}=${st}${nl}"
  case "$st" in
    ok) J_OK=$((J_OK+1)) ;;
    partial) J_PARTIAL=$((J_PARTIAL+1)) ;;
    error) J_ERROR=$((J_ERROR+1)) ;;
    paused) J_PAUSED=$((J_PAUSED+1)) ;;
    invalid) J_INVALID=$((J_INVALID+1)) ;;
    never) J_NEVER=$((J_NEVER+1)) ;;
  esac
  case "$st" in
    ok|never) ;;
    invalid) JOB_PROBLEMS="${JOB_PROBLEMS}${key} invalid: $(jobs_validate "$row" "$JOB_ROWS")${nl}" ;;
    *) e="$(job_first_error "$key")"
       [ -n "$e" ] || e="$(cat "$(job_path "$key" paused)" 2>/dev/null)"
       JOB_PROBLEMS="${JOB_PROBLEMS}${key} ${st}: ${e:-no error recorded}${nl}" ;;
  esac
done <<< "$JOB_ROWS"

# Per configured project source: the newest last_checked across its watch jobs' state files and
# ok/partial receipts. A source with no valid, unpaused watch job is UNCOVERED: once the global poll
# is gone nothing else discovers it.
state_last_checked() {  # state_last_checked <key> <slug> <src>
  local f; f="$(job_path "$1" state.yaml)"
  [ -f "$f" ] || return 0
  YAML_SEP='|' yaml_dump "$f" | sed -n "s/^projects|$2|$3|last_checked=//p" | head -1 | sed 's/^"//; s/"$//'
}
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  for src in github github_issues jira slack slite; do
    case "$(_jcfg "projects.${slug}.source.${src}")" in
      configured|"skipped:owned by scheduled job "*) ;;
      *) continue ;;
    esac
    integ="$src"; [ "$src" = github_issues ] && integ=github-issues
    best=""; best_key=""; covered=0; notes=""
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      IFS='|' read -r rslug _ id rinteg action _ <<< "$row"
      [ "$rslug" = "$slug" ] && [ "$rinteg" = "$integ" ] && [ "$action" = watch ] || continue
      key="$(job_key "$slug" "$id")"
      case "$(printf '%s' "$JOB_STATES" | awk -F= -v k="$key" '$1==k {print $2; exit}')" in
        invalid) notes="${notes}, ${key} invalid" ;;
        paused)  notes="${notes}, ${key} paused" ;;
        *) covered=1 ;;
      esac
      for ts in "$(state_last_checked "$key" "$slug" "$src")" \
                "$(case "$(job_receipt_field "$key" status)" in ok|partial) job_receipt_field "$key" finished_at ;; esac)"; do
        [ -n "$ts" ] || continue
        if [ -z "$best" ] || [[ "$ts" > "$best" ]]; then best="$ts"; best_key="$key"; fi
      done
    done <<< "$JOB_ROWS"
    label="$(printf '%s / %s' "$slug" "$integ")"
    if [ "$covered" -eq 0 ]; then
      UNCOVERED=$((UNCOVERED+1))
      DISCOVERY="${DISCOVERY}$(printf '  %-30s UNCOVERED: no watch job%s' "$label" "${notes:+ runnable (${notes#, })}")${nl}"
    elif [ -n "$best" ]; then
      DISCOVERY="${DISCOVERY}$(printf '  %-30s %-10s via %s' "$label" "$(relative_age "$best")" "$best_key")${nl}"
    else
      DISCOVERY="${DISCOVERY}$(printf '  %-30s %-10s' "$label" "never")${nl}"
    fi
  done
done < <(printf '%s\n' "${EA_JOBS_CFG:-}" | awk 'index($0,"project[]=")==1 {print substr($0,11)}')

if [ "$JSON" -eq 1 ]; then
  printf '{"incoming":%d,"drafts":%d,"completed":%d,"rejected":%d,"unrouted":%d,"stranded":%d,"stranded_drafted":%d,"duplicates":%d,' \
    "$INCOMING" "$DRAFTS" "$COMPLETED" "$REJECTED" "$UNROUTED" "$STRANDED" "$STRANDED_DRAFTED" "$DUPES"
  printf '"jobs":{"ok":%d,"partial":%d,"error":%d,"paused":%d,"invalid":%d,"never":%d},"uncovered":%d,' \
    "$J_OK" "$J_PARTIAL" "$J_ERROR" "$J_PAUSED" "$J_INVALID" "$J_NEVER" "$UNCOVERED"
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
if [ "$STRANDED_DRAFTED" -gt 0 ]; then
  printf 'WARNING: %s item(s) sit in incoming/ with a FINISHED draft. That work is done and\n' "$STRANDED_DRAFTED"
  printf '         invisible — no approval path can see it. Run scripts/queue-heal-stranded.sh --heal\n'
  printf '         to move them to drafts/ (the poll also does this automatically).\n'
fi
if [ "$DUPES" -gt 0 ]; then
  printf 'WARNING: %s duplicate (type, source_id) group(s) need a decision. Auto-healing declined\n' "$DUPES"
  printf '         them (a completed copy, or two human-owned drafts), and the poll pushes about\n'
  printf '         each one only once. Run scripts/queue-dedup-check.sh for the detail.\n'
fi
echo

if [ -n "$JOB_ROWS" ] || [ -n "$DISCOVERY" ]; then
  echo "Discovery (per project / per source, from scheduled watch jobs)"
  if [ -n "$DISCOVERY" ]; then printf '%s' "$DISCOVERY"; else echo "  No configured sources."; fi
  [ "$UNCOVERED" -gt 0 ] && [ -f "$STATE" ] \
    && echo "  (the legacy global poll may still cover UNCOVERED sources until it is removed)"
  echo
  printf 'Job health: %d ok, %d partial, %d error, %d paused, %d invalid, %d never run\n' \
    "$J_OK" "$J_PARTIAL" "$J_ERROR" "$J_PAUSED" "$J_INVALID" "$J_NEVER"
  [ -n "$JOB_PROBLEMS" ] && printf '%s' "$JOB_PROBLEMS" | sed 's/^/  /'
  echo
fi

# Global poll (cron-poll.sh) state, read while it exists.
if [ -f "$STATE" ]; then
  echo "Global poll (legacy): last checked per project / per source"
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
  echo
fi

if [ -f "$RECEIPT" ]; then
  echo "Global poll (legacy): last receipt"
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
  echo
elif [ -z "$JOB_ROWS" ]; then
  echo "No receipt — nothing has run discovery yet (no global poll receipt, no scheduled jobs)."
  echo
fi

# Scheduled jobs (scripts/jobs-tick.sh). Printed only when some are configured, so installs that
# never add `jobs` see no change. A paused, invalid or failing job is otherwise silent — the tick
# skips it every minute without a push.
JOBS_OUT="$("${SCRIPT_DIR}/jobs-ctl.sh" list 2>/dev/null)"
if [ -n "$JOBS_OUT" ] && [ "$JOBS_OUT" != "No scheduled jobs configured." ]; then
  echo "Scheduled jobs"
  printf '%s\n' "$JOBS_OUT" | sed 's/^/  /'
fi
