#!/bin/bash
# gh-claim.sh — assign a GitHub issue a github-issues implement-next job is about to work on, move
# it on the job's Projects (v2) board, and undo exactly that on failure.
#
# Usage:
#   gh-claim.sh claim   --job <project>.<id> --rule <name> --key <owner/repo#N> --item <queue-file> --run-id <id> [--approved]
#   gh-claim.sh release --job <project>.<id> --rule <name> --key <owner/repo#N> --item <queue-file> --run-id <id>
#
# Exit codes (same contract as jira-claim.sh):
#   0  claimed / released (a status the board lacks is a warning on stderr, not a failure)
#   1  GitHub API error. After a failed claim the caller runs `release`; a failed release pushes an
#      urgent ntfy alert itself, so an issue is never silently left claimed.
#   2  usage or config error
#   3  skip: race lost (before or after the claim), issue closed, or release of a claim this run
#      does not own. Do NOT release after a lost race: the issue is someone else's now.
#   4  refused: `github-claim` is not in agent.autonomy.auto_execute and --approved was not given
#
# Not a collector: it writes to GitHub, so it runs only after selection, for one issue, under the
# `github-claim` tier or after a human Approve. It must never appear in a model run's
# --allowedTools. The key must equal the item's source_id and name one of the project's repos.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"
. "${PLUGIN_ROOT}/scripts/lib-time.sh"
. "${PLUGIN_ROOT}/scripts/lib-queue.sh"

NOTIFY="${EA_NOTIFY_BIN:-${PLUGIN_ROOT}/scripts/notify.sh}"
log()  { printf 'gh-claim: %s\n' "$*" >&2; }
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
case "$MODE" in claim|release) ;; *) die "usage: gh-claim.sh claim|release --job --rule --key --item --run-id" ;; esac
[ -n "$JOB" ] && [ -n "$RULE" ] && [ -n "$ITEM" ] && [ -n "$RUN_ID" ] || die "--job, --rule, --item and --run-id are required"
[[ "$KEY" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+#[0-9]+$ ]] || die "invalid issue key '${KEY}'"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid run id"
[ -f "$ITEM" ] || die "no such queue item: $ITEM"
[ "$(fm "$ITEM" source_id)" = "$KEY" ] || die "item source_id '$(fm "$ITEM" source_id)' does not match ${KEY}"
REPO="${KEY%#*}"; NUM="${KEY##*#}"

jobs_cfg_load
ROW="$(jobs_enumerate | awk -F'|' -v k="$JOB" '($1 "." $3) == k { print; exit }')"
[ -n "$ROW" ] || die "no such job: $JOB"
IFS='|' read -r SLUG IDX _ INTEG ACTION _ <<< "$ROW"
[ "${INTEG}:${ACTION}" = "github-issues:implement-next" ] || die "$JOB is not a github-issues:implement-next job"
reason="$(gr_validate "$SLUG" "$IDX")" || die "$JOB rules are invalid: $reason"
P="$(ar_rule_prefix_by_name "$SLUG" "$IDX" "$RULE")" || die "$JOB has no rule named '${RULE}'"
_ar_member "$(_gr_lower "$REPO")" "$(gr_project_repos "$SLUG")" 0 || die "${REPO} is not one of ${SLUG}'s github.repos"

gr_init || die "$GR_ERR"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
ME="$(gr_my_login)" || { log "could not resolve own GitHub login (gh api user)"; exit 1; }
ME_LC="$(_gr_lower "$ME")"

_gh() { with_timeout "$GR_GH_TIMEOUT" gh api "$@" 2>>"$TMPD/gh.err"; }

# _state — prints "<state>\t<node id>\t<assignee logins, lowercased, comma-separated>"; rc 1 on error.
_state() {
  _gh "repos/${REPO}/issues/${NUM}" > "$TMPD/issue.json" || { log "GET ${KEY} failed"; return 1; }
  jq -r '"\(.state // "")\t\(.node_id // "")\t\([.assignees[]?.login | ascii_downcase] | join(","))"' "$TMPD/issue.json"
}
_has_me()   { case ",$1," in *",${ME_LC},"*) return 0 ;; *) return 1 ;; esac; }
_others()   { printf '%s' "$1" | tr ',' '\n' | grep -vxF -e "$ME_LC" -e '' | head -1; }
_assign()   { _gh -X POST   "repos/${REPO}/issues/${NUM}/assignees" -f "assignees[]=${ME}" >/dev/null || { log "assign ${KEY} failed"; return 1; }; }
_unassign() { _gh -X DELETE "repos/${REPO}/issues/${NUM}/assignees" -f "assignees[]=${ME}" >/dev/null || { log "unassign ${KEY} failed"; return 1; }; }

# --- Projects (v2) board ---------------------------------------------------------------------
BOARD_PID="" BOARD_FID=""
_board_init() {
  local bo bn bf
  [ -n "$BOARD_PID" ] && return 0
  IFS="	" read -r bo bn bf <<< "$(gr_board "$SLUG" "$IDX")"
  gr_graphql "$TMPD/board.json" 'query($o: String!, $n: Int!, $f: String!) { repositoryOwner(login: $o) { ... on ProjectV2Owner {
      projectV2(number: $n) { id field(name: $f) { ... on ProjectV2SingleSelectField { id options { id name } } } } } } }' \
    -f "o=$bo" -F "n=$bn" -f "f=$bf" \
    || { log "board ${bo}#${bn}: $(gr_graphql_error "$TMPD/board.json")"; return 1; }
  BOARD_PID="$(jq -r '.data.repositoryOwner.projectV2.id // empty' "$TMPD/board.json")"
  BOARD_FID="$(jq -r '.data.repositoryOwner.projectV2.field.id // empty' "$TMPD/board.json")"
  [ -n "$BOARD_PID" ] || { log "board ${bo}#${bn} not found"; return 1; }
  [ -n "$BOARD_FID" ] || { log "board ${bo}#${bn} has no single-select field '${bf}'"; return 1; }
}

# _board_item <issue node id> — "<item id>\t<status>" on the job's board, or nothing if not on it.
_board_item() {
  gr_graphql "$TMPD/item.json" 'query($id: ID!, $f: String!) { node(id: $id) { ... on Issue {
      projectItems(first: 50) { nodes { id project { id } status: fieldValueByName(name: $f) { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } }' \
    -f "id=$1" -f "f=$(gr_board "$SLUG" "$IDX" | cut -f3)" \
    || { log "board item for ${KEY}: $(gr_graphql_error "$TMPD/item.json")"; return 1; }
  jq -r --arg p "$BOARD_PID" '.data.node.projectItems.nodes[]? | select(.project.id == $p) | "\(.id)\t\(.status.name // "")"' "$TMPD/item.json" | head -1
}

# _board_set <item id> <status name> — rc 0 set, 4 the field has no such option, 1 API error.
_board_set() {
  local opt
  opt="$(jq -r --arg n "$(_gr_lower "$2")" '[.data.repositoryOwner.projectV2.field.options[]? | select((.name | ascii_downcase) == $n) | .id] | first // empty' "$TMPD/board.json")"
  [ -n "$opt" ] || return 4
  gr_graphql "$TMPD/set.json" 'mutation($p: ID!, $i: ID!, $f: ID!, $o: String!) { updateProjectV2ItemFieldValue(input: {
      projectId: $p, itemId: $i, fieldId: $f, value: { singleSelectOptionId: $o } }) { projectV2Item { id } } }' \
    -f "p=$BOARD_PID" -f "i=$1" -f "f=$BOARD_FID" -f "o=$opt" \
    || { log "set ${KEY} board status to '$2': $(gr_graphql_error "$TMPD/set.json")"; return 1; }
}

_board_add() {
  gr_graphql "$TMPD/add.json" 'mutation($p: ID!, $c: ID!) { addProjectV2ItemById(input: { projectId: $p, contentId: $c }) { item { id } } }' \
    -f "p=$BOARD_PID" -f "c=$1" || { log "add ${KEY} to board: $(gr_graphql_error "$TMPD/add.json")"; return 1; }
  jq -r '.data.addProjectV2ItemById.item.id // empty' "$TMPD/add.json"
}

do_claim() {
  local st state node assignees mode assign ps row itemid status rc
  if [ "$APPROVED" != 1 ] && ! jobs_autonomy_allows github-claim; then
    log "refused: github-claim is not in agent.autonomy.auto_execute"; exit 4
  fi
  st="$(_state)" || exit 1
  IFS="	" read -r state node assignees <<< "$st"
  [ "$state" = open ] || { log "skip: ${KEY} is ${state:-unreadable}"; exit 3; }
  mode="$(gr_assignee_mode "$P")"
  case "$mode" in
    empty) [ -z "$assignees" ] || { log "race lost: ${KEY} was assigned before the claim"; exit 3; } ;;
    me)    _has_me "$assignees" || { log "race lost: ${KEY} is no longer assigned to me"; exit 3; } ;;
  esac
  assign="$(_arc "$P.claim.assign")"; ps="$(_arc "$P.claim.project_status")"

  # Intent is recorded BEFORE each write, so a crash between the write and the record cannot leave
  # a claim that release refuses to undo. release re-checks GitHub, so over-recording is harmless.
  fm_set "$ITEM" claimed_by_run "$RUN_ID"
  if [ "$assign" = self ] && ! _has_me "$assignees"; then
    fm_set "$ITEM" claimed_assign true
    _assign || exit 1
  else
    fm_set "$ITEM" claimed_assign false
  fi
  if [ -n "$ps" ]; then
    _board_init || exit 1
    row="$(_board_item "$node")" || exit 1
    itemid="${row%%	*}"; status="${row#*	}"
    [ -n "$row" ] || status=""
    fm_set "$ITEM" claim_from_project_status "$status"
    if [ "$(_gr_lower "$status")" != "$(_gr_lower "$ps")" ]; then
      fm_set "$ITEM" claimed_project_status "$ps"
      if [ -z "$row" ]; then
        fm_set "$ITEM" claimed_board_added true
        itemid="$(_board_add "$node")"
        [ -n "$itemid" ] || exit 1
      fi
      _board_set "$itemid" "$ps"; rc=$?
      case "$rc" in
        0) ;;
        4) log "warning: board has no status '${ps}'; claimed ${KEY} without it"
           fm_set "$ITEM" claimed_project_status "" ;;
        *) exit 1 ;;
      esac
    fi
  fi

  if [ "$assign" = self ]; then
    st="$(_state)" || exit 1
    IFS="	" read -r _ _ assignees <<< "$st"
    if ! _has_me "$assignees" || { [ "$mode" = empty ] && [ -n "$(_others "$assignees")" ]; }; then
      fm_set "$ITEM" claim_lost true
      # Only our own assignment is undone; the issue now belongs to whoever else holds it.
      _has_me "$assignees" && [ "$(fm "$ITEM" claimed_assign)" = true ] && _unassign
      log "race lost: ${KEY} was assigned to someone else during the claim"
      exit 3
    fi
  fi
  log "claimed ${KEY} (rule ${RULE}, run ${RUN_ID})"
}

alert() {
  "$NOTIFY" --title "GitHub claim not rolled back: ${KEY}" \
    --message "gh-claim release failed for ${KEY} (job ${JOB}): $1. Check its assignees and board status by hand." \
    --priority urgent --tags warning --fyi >/dev/null 2>&1 || true
}

do_release() {
  local st state node assignees unassign ps cps row status rc errs=""
  [ "$(fm "$ITEM" claimed_by_run)" = "$RUN_ID" ] || { log "not releasing ${KEY}: not claimed by run ${RUN_ID}"; exit 3; }
  [ "$(fm "$ITEM" claim_lost)" = true ] && { log "not releasing ${KEY}: claim was lost to someone else"; exit 3; }
  st="$(_state)" || { alert "could not read the issue"; exit 1; }
  IFS="	" read -r state node assignees <<< "$st"
  unassign="$(_arc "$P.on_fail.unassign")"; ps="$(_arc "$P.on_fail.project_status")"
  cps="$(fm "$ITEM" claimed_project_status)"

  # Touch only what this run changed and nobody has changed since.
  if [ "$unassign" = true ] && [ "$(fm "$ITEM" claimed_assign)" = true ]; then
    if _has_me "$assignees"; then
      _unassign || errs="${errs}unassign failed; "
    else
      log "not unassigning ${KEY}: no longer assigned to me"
    fi
  fi
  if [ -n "$ps" ] && [ -n "$cps" ]; then
    if _board_init && row="$(_board_item "$node")"; then
      status="${row#*	}"; [ -n "$row" ] || status=""
      if [ -n "$row" ] && [ "$(_gr_lower "$status")" = "$(_gr_lower "$cps")" ] && [ -z "$(_others "$assignees")" ]; then
        _board_set "${row%%	*}" "$ps"; rc=$?
        case "$rc" in
          0) ;;
          4) log "warning: board has no status '${ps}'" ;;
          *) errs="${errs}board status to '${ps}' failed; " ;;
        esac
      else
        log "not moving ${KEY} back: board status or assignees changed since the claim"
      fi
    else
      errs="${errs}could not read the board; "
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
