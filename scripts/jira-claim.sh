#!/bin/bash
# jira-claim.sh — assign/transition a Jira ticket an implement-next job is about to work on, and
# undo exactly that on failure.
#
# Usage:
#   jira-claim.sh claim   --job <project>.<id> --rule <name> --key <ISSUE-KEY> --item <queue-file> --run-id <id> [--approved]
#   jira-claim.sh release --job <project>.<id> --rule <name> --key <ISSUE-KEY> --item <queue-file> --run-id <id>
#
# Exit codes:
#   0  claimed / released (a missing transition is a warning on stderr, not a failure)
#   1  Jira API error. After a failed claim the caller runs `release`; a failed release pushes an
#      urgent ntfy alert itself, so a ticket is never silently left claimed.
#   2  usage or config error
#   3  skip: race lost (before or after the claim), or release of a claim this run does not own.
#      Do NOT release after a lost race: the ticket is someone else's now.
#   4  refused: `jira-claim` is not in agent.autonomy.auto_execute and --approved was not given
#
# This is not a collector: it writes to Jira, so it runs only after selection, for one ticket, under
# the `jira-claim` tier or after a human Approve (--approved). It must never appear in a model
# run's --allowedTools. The key is validated and must equal the item's source_id; ticket text never
# chooses what is written. Credentials go to curl on stdin (lib-jira-api.sh).
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"
. "${PLUGIN_ROOT}/scripts/lib-time.sh"
. "${PLUGIN_ROOT}/scripts/lib-queue.sh"
. "${PLUGIN_ROOT}/scripts/lib-secret.sh"
. "${PLUGIN_ROOT}/scripts/lib-jira-api.sh"

NOTIFY="${EA_NOTIFY_BIN:-${PLUGIN_ROOT}/scripts/notify.sh}"
log()  { printf 'jira-claim: %s\n' "$*" >&2; }
die()  { log "$*"; exit 2; }

MODE="${1:-}"; shift || true
JOB="" RULE="" KEY="" ITEM="" RUN_ID="" APPROVED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --job) JOB="${2:-}"; shift 2 ;;
    --rule) RULE="${2:-}"; shift 2 ;;
    --key) KEY="${2:-}"; shift 2 ;;
    --item) ITEM="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --approved) APPROVED=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$MODE" in claim|release) ;; *) die "usage: jira-claim.sh claim|release --job --rule --key --item --run-id" ;; esac
[ -n "$JOB" ] && [ -n "$RULE" ] && [ -n "$ITEM" ] && [ -n "$RUN_ID" ] || die "--job, --rule, --item and --run-id are required"
[[ "$KEY" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]] || die "invalid issue key '${KEY}'"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid run id"
[ -f "$ITEM" ] || die "no such queue item: $ITEM"
[ "$(fm "$ITEM" source_id)" = "$KEY" ] || die "item source_id '$(fm "$ITEM" source_id)' does not match ${KEY}"

jobs_cfg_load
ROW="$(jobs_enumerate | awk -F'|' -v k="$JOB" '($1 "." $3) == k { print; exit }')"
[ -n "$ROW" ] || die "no such job: $JOB"
IFS='|' read -r SLUG IDX _ INTEG ACTION _ <<< "$ROW"
[ "${INTEG}:${ACTION}" = "jira:implement-next" ] || die "$JOB is not a jira:implement-next job"
reason="$(ar_validate "$SLUG" "$IDX")" || die "$JOB rules are invalid: $reason"
P="$(ar_rule_prefix_by_name "$SLUG" "$IDX" "$RULE")" || die "$JOB has no rule named '${RULE}'"

ar_jira_init || die "$AR_ERR"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
ME="$(ar_my_account_id)" || { log "could not resolve own Jira accountId (/myself)"; exit 1; }

# _state — prints "<assigneeAccountId>\t<status name>"; rc 1 on API error.
_state() {
  local code
  code="$(jira_api "$TMPD/issue.json" GET "/issue/${KEY}?fields=assignee,status")"
  [ "$code" = 200 ] || { log "GET ${KEY} failed (HTTP ${code})"; return 1; }
  jq -r '"\(.fields.assignee.accountId // "")\t\(.fields.status.name // "")"' "$TMPD/issue.json"
}

# _assign <accountId|""> — "" unassigns.
_assign() {
  local body code
  body="$(jq -nc --arg a "$1" '{accountId: (if $a == "" then null else $a end)}')"
  code="$(jira_api "$TMPD/assign.json" PUT "/issue/${KEY}/assignee" "$body")"
  [ "$code" = 204 ] || [ "$code" = 200 ] || { log "assign ${KEY} failed (HTTP ${code})"; return 1; }
}

# _transition <name> — rc 0 done, 4 no such transition, 1 API error (logged).
_transition() {
  local rc
  jira_transition_by_name "$KEY" "$1"; rc=$?
  [ "$rc" = 1 ] && log "transition ${KEY} to '$1' failed (HTTP ${JIRA_HTTP})"
  return "$rc"
}

_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

do_claim() {
  local st assignee status mode assign tr rc
  if [ "$APPROVED" != 1 ] && ! jobs_autonomy_allows jira-claim; then
    log "refused: jira-claim is not in agent.autonomy.auto_execute"; exit 4
  fi
  st="$(_state)" || exit 1
  assignee="${st%%	*}"; status="${st#*	}"
  mode="$(ar_assignee_mode "$P")"
  case "$mode" in
    empty) [ -z "$assignee" ] || { log "race lost: ${KEY} was assigned before the claim"; exit 3; } ;;
    me)    [ "$assignee" = "$ME" ] || { log "race lost: ${KEY} is no longer assigned to me"; exit 3; } ;;
  esac
  assign="$(_arc "$P.claim.assign")"; tr="$(_arc "$P.claim.transition")"

  # Intent is recorded BEFORE each write, so a crash between the write and the record cannot leave
  # a claim that release refuses to undo. release re-checks Jira, so over-recording is harmless.
  fm_set "$ITEM" claimed_by_run "$RUN_ID"
  fm_set "$ITEM" claim_from_status "$status"
  if [ "$assign" = self ] && [ "$assignee" != "$ME" ]; then
    fm_set "$ITEM" claimed_assign true
    _assign "$ME" || exit 1
  else
    fm_set "$ITEM" claimed_assign false
  fi
  if [ -n "$tr" ] && [ "$(_lower "$status")" != "$(_lower "$tr")" ]; then
    fm_set "$ITEM" claimed_transition "$tr"
    _transition "$tr"; rc=$?
    case "$rc" in
      0) ;;
      4) log "warning: no transition to '${tr}' from '${status}' on ${KEY}; claimed without it"
         fm_set "$ITEM" claimed_transition "" ;;
      *) exit 1 ;;
    esac
  fi

  if [ "$assign" = self ]; then
    st="$(_state)" || exit 1
    if [ "${st%%	*}" != "$ME" ]; then
      fm_set "$ITEM" claim_lost true
      log "race lost: ${KEY} was reassigned during the claim"
      exit 3
    fi
  fi
  log "claimed ${KEY} (rule ${RULE}, run ${RUN_ID})"
}

alert() {
  "$NOTIFY" --title "Jira claim not rolled back: ${KEY}" \
    --message "jira-claim release failed for ${KEY} (job ${JOB}): $1. Check its assignee and status by hand." \
    --priority urgent --tags warning --fyi >/dev/null 2>&1 || true
}

do_release() {
  local st assignee status unassign tr ctr rc errs=""
  [ "$(fm "$ITEM" claimed_by_run)" = "$RUN_ID" ] || { log "not releasing ${KEY}: not claimed by run ${RUN_ID}"; exit 3; }
  [ "$(fm "$ITEM" claim_lost)" = true ] && { log "not releasing ${KEY}: claim was lost to someone else"; exit 3; }
  st="$(_state)" || { alert "could not read the ticket"; exit 1; }
  assignee="${st%%	*}"; status="${st#*	}"
  unassign="$(_arc "$P.on_fail.unassign")"; tr="$(_arc "$P.on_fail.transition")"
  ctr="$(fm "$ITEM" claimed_transition)"

  # Touch only what this run changed and nobody has changed since.
  if [ "$unassign" = true ] && [ "$(fm "$ITEM" claimed_assign)" = true ]; then
    if [ "$assignee" = "$ME" ]; then
      _assign "" || errs="${errs}unassign failed; "
    else
      log "not unassigning ${KEY}: no longer assigned to me"
    fi
  fi
  if [ -n "$tr" ] && [ -n "$ctr" ]; then
    if [ "$(_lower "$status")" = "$(_lower "$ctr")" ] && { [ -z "$assignee" ] || [ "$assignee" = "$ME" ]; }; then
      _transition "$tr"; rc=$?
      case "$rc" in
        0) ;;
        4) log "warning: no transition to '${tr}' from '${status}' on ${KEY}" ;;
        *) errs="${errs}transition to '${tr}' failed; " ;;
      esac
    else
      log "not transitioning ${KEY} back: status or assignee changed since the claim"
    fi
  fi
  fm_set "$ITEM" released_by_run "$RUN_ID"
  if [ -n "$errs" ]; then alert "${errs%; }"; log "${errs%; }"; exit 1; fi
  log "released ${KEY} (run ${RUN_ID})"
}

case "$MODE" in
  claim) do_claim ;;
  release) do_release ;;
esac
