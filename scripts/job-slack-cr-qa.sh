#!/bin/bash
# job-slack-cr-qa.sh — the slack / cr-qa scheduled job: pick the oldest trusted "CR/QA" request in
# the job's channel for one of the project's repos, review the PR, QA it against the ticket, and
# either stop with one comment or approve (Jira QA summary, approve reaction, transition).
#
# Usage: job-slack-cr-qa.sh --job <project>.<id> --errors <file> --items <file> [--budget <usd>]
# Exit: 0 ok (nothing eligible, a review/QA stop, or approved), 1 error, 3 Slack/Jira unavailable.
#
# Every external write is bash behind its own tier (slack-react, pr-comment, jira-comment,
# jira-transition, security-review), checked before the claim. The ledger
# (state/jobs/<key>.requests.tsv) is the dedup key: a request is handled at most once.
set -uo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"
. "${PLUGIN_ROOT}/scripts/lib-secret.sh"
. "${PLUGIN_ROOT}/scripts/lib-jira-api.sh"
. "${PLUGIN_ROOT}/scripts/lib-confined-run.sh"
. "${PLUGIN_ROOT}/scripts/lib-review.sh"
. "${PLUGIN_ROOT}/scripts/lib-cr-qa.sh"
JOB="" ERRORS="/dev/null" ITEMS="/dev/null" BUDGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --job) JOB="$2"; shift 2 ;;       --errors) ERRORS="$2"; shift 2 ;;
    --items) ITEMS="$2"; shift 2 ;;   --budget) BUDGET="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$JOB" ] || { echo "--job is required" >&2; exit 2; }
LOG_FILE="${EA_AGENT_DIR}/state/jobs.log"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "${HOME}/.local/bin/claude")}"
BUDGET="${BUDGET:-${EA_CRQA_BUDGET_USD:-3.00}}"
GH_TIMEOUT="${EA_POLL_CMD_TIMEOUT:-120}"
log() { printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOB" "$*" >> "$LOG_FILE"; }
err() { printf '%s\n' "$*" >> "$ERRORS"; log "ERROR: $*"; }
echo 0 > "$ITEMS"

jobs_cfg_load
IFS='|' read -r SLUG IDX _ <<< "$(jobs_enumerate | awk -F'|' -v k="$JOB" '($1 "." $3) == k { print; exit }')"
[ -n "${SLUG:-}" ] || { echo "no such job: $JOB" >&2; exit 2; }
P="projects.${SLUG}.job.${IDX}"
CHANNEL="$(_arc "$P.channel")"
PREFIX="$(_arc "$P.trigger_prefix")"; PREFIX="${PREFIX:-CR/QA}"
CLAIM="$(_arc "$P.reactions.claim")"; CLAIM="${CLAIM:-eyes}"
APPROVE="$(_arc "$P.reactions.approve")"; APPROVE="${APPROVE:-approve}"
TRANSITION="$(_arc "$P.transition")"
SEC_CMD="$(_arc "$P.security.command")"; SEC_CMD="${SEC_CMD/#\~/$HOME}"
SEC_TO="$(jobs_duration_seconds "$(_arc "$P.security.timeout")")"; SEC_TO="${SEC_TO:-1800}"
QA_TO="$(jobs_duration_seconds "$(_arc "$P.qa.timeout")")"; QA_TO="${QA_TO:-1800}"
TRUSTED="$(_arcl "$P.trusted_authors")"
LEDGER="$(job_path "$JOB" requests.tsv)"
PROJECT_PATH="$(yaml_project_scalar "$SLUG" path)"; PROJECT_PATH="${PROJECT_PATH/#\~/$HOME}"
ALLOWED="$(yaml_project_list "$SLUG" exec allowed_commands | grep -E '^[A-Za-z0-9._/-]+$')"

# --- guards and tiers (before anything is claimed) ------------------------------------------------
cap="$(_jcfg "$P.daily_cap")"; cap="${cap:-10}"
n="$(job_picks_today "$JOB")"
[ "$n" -lt "$cap" ] || { log "skipped: daily_cap ${cap} reached (${n} today)"; exit 0; }
missing=""
for t in slack-react pr-comment jira-comment jira-transition security-review; do
  jobs_autonomy_allows "$t" || missing="${missing}${missing:+, }${t}"
done
[ -z "$missing" ] || { err "cr-qa needs autonomy tier(s): ${missing}"; exit 1; }
[ -e "$PROJECT_PATH/.git" ] || { err "project path '${PROJECT_PATH}' is not a git checkout"; exit 1; }

# --- find -----------------------------------------------------------------------------------------
w="$(_arc "projects.${SLUG}.slack.workspace")"; [ -n "$w" ] || w="$(_arc agent.slack.workspace)"
ea_slack_bin "$(_arc agent.slack.method)" "$(_arc agent.slack.bin)" "$w"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/crqa.XXXXXX")"
WT="" REF=""
cleanup() {
  [ -z "$WT" ] || git -C "$PROJECT_PATH" worktree remove --force "$WT" >/dev/null 2>&1
  [ -z "$REF" ] || git -C "$PROJECT_PATH" update-ref -d "$REF" >/dev/null 2>&1
  rm -rf "$TMPD"
}
trap cleanup EXIT
jobs_kill_tree_children() { local c; for c in $(pgrep -P $$ 2>/dev/null); do jobs_kill_tree "$c"; done; }
with_timeout "$GH_TIMEOUT" "$SLACK_BIN" read "$CHANNEL" 100 --json ${SLACK_WS[@]+"${SLACK_WS[@]}"} > "$TMPD/msgs.json" 2>>"$LOG_FILE" \
  || { err "Slack read of ${CHANNEL} failed"; exit 3; }
jq -e 'type == "array" and all(has("reactions"))' "$TMPD/msgs.json" >/dev/null 2>&1 \
  || { err "the Slack backend returned no reactions; cr-qa needs them to skip claimed requests"; exit 3; }
pick="$(crqa_pick "$TMPD/msgs.json" "$PREFIX" "$CLAIM" "$(_arcl "$P.trusted_slack_users")" "$(gr_project_repos "$SLUG")" "$LEDGER")" \
  || { log "nothing eligible"; exit 0; }
IFS="	" read -r TS PR_URL REPO PR KEY _ <<< "$pick"
log "picked ${PR_URL} (${KEY}) from ${TS}"
mkdir -p "$JOBS_STATE_DIR"

# --- ticket trust (before any reaction or model run) ------------------------------------------------
ar_jira_init || { err "Jira unavailable: ${AR_ERR}"; exit 3; }
jira_get_issue "$KEY" "$TMPD/issue.json" || { err "could not read ${KEY} (HTTP ${JIRA_HTTP})"; exit 3; }
reason="$(jira_untrusted_reason "$TMPD/issue.json" "$TRUSTED")"
if [ -n "$reason" ]; then
  crqa_ledger_set "$LEDGER" "$TS" "$PR_URL" "$KEY" untrusted
  printf 'CR/QA skipped: ticket text is not from a trusted author.\n' > "$TMPD/c.md"
  jira_add_comment "$KEY" "$TMPD/c.md" || err "Jira comment on ${KEY} failed (HTTP ${JIRA_HTTP})"
  log "untrusted ${KEY}: ${reason}"
  exit 0
fi

# --- claim ----------------------------------------------------------------------------------------
crqa_ledger_set "$LEDGER" "$TS" "$PR_URL" "$KEY" claimed
if ! with_timeout "$GH_TIMEOUT" "$SLACK_BIN" react "$CHANNEL" "$TS" "$CLAIM" --json ${SLACK_WS[@]+"${SLACK_WS[@]}"} >/dev/null 2>>"$LOG_FILE"; then
  crqa_ledger_set "$LEDGER" "$TS" "$PR_URL" "$KEY" error
  err "could not add :${CLAIM}: to ${TS}"; exit 1
fi
job_record_pick "$JOB" "$TS"
echo 1 > "$ITEMS"
# The job watchdog (jobs-tick.sh) TERMs a run that overstays: record it, so the request is not
# left `claimed` with nobody working on it.
trap 'err "interrupted while handling ${PR_URL}"; crqa_ledger_set "$LEDGER" "$TS" "$PR_URL" "$KEY" error; jobs_kill_tree_children; exit 1' TERM INT

finish() {  # finish <outcome> <rc>
  crqa_ledger_set "$LEDGER" "$TS" "$PR_URL" "$KEY" "$1"; log "${KEY}: $1"; exit "$2"
}
pr_comment() {
  with_timeout "$GH_TIMEOUT" gh pr comment "$PR" --repo "$REPO" --body-file "$1" >>"$LOG_FILE" 2>&1 \
    || err "PR comment on ${PR_URL} failed"
}
jira_comment() { jira_add_comment "$KEY" "$1" || err "Jira comment on ${KEY} failed (HTTP ${JIRA_HTTP})"; }

# --- checkout of the PR head -----------------------------------------------------------------------
view="$(with_timeout "$GH_TIMEOUT" gh pr view "$PR" --repo "$REPO" --json baseRefName,headRefOid 2>>"$LOG_FILE")"
BASE="$(printf '%s' "$view" | jq -r '.baseRefName // empty' 2>/dev/null)"
SHA="$(printf '%s' "$view" | jq -r '.headRefOid // empty' 2>/dev/null)"
[[ "$BASE" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { err "could not read ${PR_URL}"; finish error 1; }
REF="refs/cr-qa/${PR}"
with_timeout "$GH_TIMEOUT" git -C "$PROJECT_PATH" fetch --quiet origin "+refs/pull/${PR}/head:${REF}" "+refs/heads/${BASE}:refs/remotes/origin/${BASE}" >>"$LOG_FILE" 2>&1 \
  && [ "$(git -C "$PROJECT_PATH" rev-parse "$REF" 2>/dev/null)" = "$SHA" ] \
  || { err "could not fetch ${PR_URL} at ${SHA:0:7}"; finish error 1; }
WT="${EA_AGENT_DIR}/worktrees/cr-qa-${SLUG}-${PR}-$(date +%s)"
git -C "$PROJECT_PATH" worktree add --quiet --detach "$WT" "$SHA" >>"$LOG_FILE" 2>&1 || { WT=""; err "could not create a worktree for ${PR_URL}"; finish error 1; }

# --- QA inputs (trusted text and scripts only) ----------------------------------------------------------
W="$TMPD/work"; mkdir -p "$W/scripts"
crqa_qa_inputs "$TMPD/issue.json" "$TRUSTED" "$W"
while IFS="	" read -r id name; do
  [ -n "$name" ] || continue
  jira_download_attachment "$id" "$W/scripts/$name" || { err "could not download ${name} from ${KEY} (HTTP ${JIRA_HTTP})"; finish error 1; }
done < "$W/scripts.tsv"

# --- review ---------------------------------------------------------------------------------------
if ! crqa_review "$WT" "$W" "$REPO" "$PR" "$BASE" "$SEC_CMD" "$SEC_TO" "$BUDGET"; then
  printf 'CR/QA: review could not complete — %s\n' "$(cat "$W/review.err")" > "$TMPD/c.md"
  pr_comment "$TMPD/c.md"; err "review of ${PR_URL} could not complete: $(cat "$W/review.err")"
  finish error 1
fi
crqa_blocking "$W" > "$W/blocking.json" || { err "unreadable review findings"; finish error 1; }
if [ "$(jq length "$W/blocking.json")" -gt 0 ]; then
  crqa_review_comment "$W/blocking.json" "$TMPD/c.md"; pr_comment "$TMPD/c.md"
  finish review-stopped 0
fi

# --- QA -------------------------------------------------------------------------------------------
if ! crqa_qa "$WT" "$W" "$ALLOWED" "$QA_TO" "$BUDGET"; then
  crqa_qa_comment "$W" fail "$PR_URL" "$TMPD/c.md"; jira_comment "$TMPD/c.md"
  finish qa-stopped 0
fi

# --- approve --------------------------------------------------------------------------------------
now="$(with_timeout "$GH_TIMEOUT" gh pr view "$PR" --repo "$REPO" --json headRefOid 2>>"$LOG_FILE" | jq -r '.headRefOid // empty' 2>/dev/null)"
[ "$now" = "$SHA" ] || { err "${PR_URL} moved from ${SHA:0:7} during the review; not approving"; finish error 1; }
crqa_qa_comment "$W" pass "$PR_URL" "$TMPD/c.md"
printf '\nReviewed commit: %s\n' "$SHA" >> "$TMPD/c.md"
jira_add_comment "$KEY" "$TMPD/c.md" || { err "Jira QA summary on ${KEY} failed (HTTP ${JIRA_HTTP})"; finish error 1; }
with_timeout "$GH_TIMEOUT" "$SLACK_BIN" react "$CHANNEL" "$TS" "$APPROVE" --json ${SLACK_WS[@]+"${SLACK_WS[@]}"} >/dev/null 2>>"$LOG_FILE" \
  || { err "could not add :${APPROVE}: to ${TS}"; finish error 1; }
jira_transition_by_name "$KEY" "$TRANSITION"; rc=$?
case "$rc" in
  0) ;;
  4) err "no transition to '${TRANSITION}' from ${KEY}'s current status"; finish error 1 ;;
  *) err "transition of ${KEY} failed (HTTP ${JIRA_HTTP})"; finish error 1 ;;
esac
finish approved 0
