#!/bin/bash
# job-github-implement-next.sh — the github-issues / implement-next scheduled job: pick the next
# issue by the job's rules, queue it, and (only with both autonomy tiers) claim and implement it.
#
# Usage: job-github-implement-next.sh --job <project>.<id> --errors <file> --items <file> [--budget <usd>]
# Exit: 0 ok (including "guard skipped" and "nothing eligible"), 1 failed, 3 GitHub unavailable.
#
# Same sequence and trust model as job-jira-implement-next.sh. UNATTENDED needs `implement` AND
# `github-claim` in auto_execute AND trusted authorship: the issue's author and every editor of its
# title, body and labels must be in the job's trusted_authors (GitHub logins). The check and the
# queue item come from ONE fetch, and the unattended confined run has no GitHub text reads, so the
# model sees exactly the text that was checked. Anything short of it falls back to Approve.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"
. "${PLUGIN_ROOT}/scripts/lib-time.sh"
. "${PLUGIN_ROOT}/scripts/lib-queue.sh"
. "${PLUGIN_ROOT}/scripts/lib-queue-write.sh"
. "${PLUGIN_ROOT}/scripts/lib-ticket-kind.sh"
. "${PLUGIN_ROOT}/scripts/lib-confined-run.sh"

JOB="" ERRORS="/dev/null" ITEMS="/dev/null" BUDGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --job) JOB="$2"; shift 2 ;;       --errors) ERRORS="$2"; shift 2 ;;
    --items) ITEMS="$2"; shift 2 ;;   --budget) BUDGET="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$JOB" ] || { echo "--job is required" >&2; exit 2; }

AGENT_DIR="$EA_AGENT_DIR"
LOG_FILE="${EA_AGENT_DIR}/state/jobs.log"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "${HOME}/.local/bin/claude")}"
QA_BUDGET_USD="${EA_QA_BUDGET_USD:-2.00}"
BUDGET="${BUDGET:-${EA_TICKET_BUDGET_USD:-8.00}}"
NOTIFY="${EA_NOTIFY_BIN:-${PLUGIN_ROOT}/scripts/notify.sh}"

log() { printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOB" "$*" >> "$LOG_FILE"; }
push_ack() { "$NOTIFY" --fyi --title "engineer-agent" --priority "$1" --message "$2" </dev/null >>"$LOG_FILE" 2>&1 || true; }
err() { printf '%s\n' "$*" >> "$ERRORS"; log "ERROR: $*"; }
echo 0 > "$ITEMS"

jobs_cfg_load
IFS='|' read -r SLUG IDX _ <<< "$(jobs_enumerate | awk -F'|' -v k="$JOB" '($1 "." $3) == k { print; exit }')"
[ -n "${SLUG:-}" ] || { echo "no such job: $JOB" >&2; exit 2; }
P="projects.${SLUG}.job.${IDX}"

# A stopped PR pipeline resumes once its branch has new commits; before the guards, which only
# limit new picks.
pr_pipeline_resume_stopped "$JOB"

# --- 1. guards ------------------------------------------------------------------------------------
max="$(_jcfg "${P}.max_in_flight")"; max="${max:-1}"
cap="$(_jcfg "${P}.daily_cap")";     cap="${cap:-1}"
n="$(inflight_count "$SLUG")"
[ "$n" -lt "$max" ] || { log "skipped: ${n} implementation(s) in flight for ${SLUG} (max_in_flight ${max})"; exit 0; }
pending="$(autopilot_pending "$JOB" | head -1)"
[ -z "$pending" ] || { log "skipped: ${pending} is still awaiting a decision in drafts/"; exit 0; }
n="$(job_picks_today "$JOB")"
[ "$n" -lt "$cap" ] || { log "skipped: daily_cap ${cap} reached (${n} picked today)"; exit 0; }

# --- 2. select ------------------------------------------------------------------------------------
gr_init || { err "GitHub unavailable: ${GR_ERR}"; exit 3; }
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
pick="$(AR_TRACE=1 gr_select "$SLUG" "$IDX" 2>>"$LOG_FILE")"; rc=$?
case "$rc" in
  0) ;;
  1) log "nothing eligible"; exit 0 ;;
  *) err "selection failed: ${pick}"; exit 1 ;;
esac
IFS="	" read -r RULE KEY _ <<< "$pick"
REPO="${KEY%#*}"; NUM="${KEY##*#}"

# --- 3. queue item --------------------------------------------------------------------------------
gr_issue_fetch "$TMPD/issue.json" "$REPO" "$NUM" || { err "could not read ${KEY}: $(gr_graphql_error "$TMPD/issue.json")"; exit 1; }
I='.data.repository.issue'
# The key written to the queue is the API's, never one parsed from issue text.
[ "$(jq -r "\"\(${I}.repository.nameWithOwner // \"\")#\(${I}.number // \"\")\"" "$TMPD/issue.json")" = "$KEY" ] \
  || { err "issue response key mismatch for ${KEY}"; exit 1; }
jq -r "${I}.body // \"\""                 "$TMPD/issue.json" > "$TMPD/body"
jq -r "${I}.labels.nodes[]?.name // empty" "$TMPD/issue.json" > "$TMPD/labels"
prio=normal
grep -qiE '^(priority:[[:space:]]*high|urgent)$' "$TMPD/labels" && prio=urgent
grep -qiE '^priority:[[:space:]]*low$' "$TMPD/labels" && prio=low
URL="$(jq -r "${I}.url // \"\"" "$TMPD/issue.json")"
case "$URL" in https://*) ;; *) URL="https://github.com/${REPO}/issues/${NUM}" ;; esac
ITEM="$(queue_filename ticket "gh-${NUM}" "$(queue_ts)")"
DRAFT="${AGENT_DIR}/queue/drafts/${ITEM}"
mkdir -p "$(dirname "$DRAFT")"
write_ticket_item --path "$DRAFT" --type ticket --source github --source-url "$URL" --source-id "$KEY" \
  --title "$(jq -r "${I}.title // \"\"" "$TMPD/issue.json")" --priority "$prio" \
  --created-at "$(iso_now)" --project "$SLUG" --ticket-key "#${NUM}" --state Open \
  --labels-file "$TMPD/labels" --kind-method default --body-file "$TMPD/body"
fm_set "$DRAFT" status drafted
fm_set "$DRAFT" autopilot true
fm_set "$DRAFT" autopilot_job "$JOB"
fm_set "$DRAFT" autopilot_rule "$RULE"
cat >> "$DRAFT" <<EOF

## Draft Response

Autopilot pick: job \`${JOB}\`, rule \`${RULE}\`. Approving claims ${KEY} on GitHub (per the rule's
\`claim\`), implements it in a confined worktree, and opens a draft PR. On failure the claim is
rolled back per the rule's \`on_fail\`.
EOF
autopilot_record "$ITEM" "$JOB" "$RULE" "$KEY" github
job_record_pick "$JOB" "$ITEM"
echo 1 > "$ITEMS"
log "picked ${KEY} (rule ${RULE}) -> drafts/${ITEM}"

# --- 4. gate --------------------------------------------------------------------------------------
gate=""
if ! jobs_autonomy_allows implement || ! jobs_autonomy_allows github-claim; then
  gate="autonomy tiers implement and github-claim not both set"
else
  gate="$(gr_untrusted_reason "$TMPD/issue.json" "$(_arcl "${P}.trusted_authors")")"
fi
if [ -n "$gate" ]; then
  printf '\nUnattended run not allowed: %s.\n' "$gate" >> "$DRAFT"
  "$NOTIFY" --title "Autopilot: ${KEY}" \
    --message "Job ${JOB} (rule ${RULE}) picked ${KEY}. Approve to claim and implement it. (${gate})" \
    --priority normal --item-id "$ITEM" --source-url "$URL" </dev/null >>"$LOG_FILE" 2>&1 || true
  log "awaiting Approve for ${ITEM}: ${gate}"
  exit 0
fi
record_ticket_text "$ITEM" "$(jq -r "${I}.title // \"\"" "$TMPD/issue.json")" "$TMPD/body"

# --- 5. claim + implement -------------------------------------------------------------------------
# A watchdog kill must not leave the issue claimed with nobody working on it.
trap 'log "interrupted; releasing ${KEY}"; autopilot_release "$ITEM"; rm -rf "$TMPD"; exit 1' TERM INT
autopilot_implement "$ITEM" "$BUDGET"; rc=$?
trap 'rm -rf "$TMPD"' EXIT; trap - TERM INT
case "$rc" in
  0) push_ack normal "✅ Autopilot implemented ${KEY} (rule ${RULE}) — draft PR opened"; exit 0 ;;
  3) exit 0 ;;
  *) err "implementation of ${KEY} did not complete; claim rolled back, item left in drafts/"
     push_ack urgent "⚠️ Autopilot failed on ${KEY} — claim rolled back; item left in drafts/ for review"
     exit 1 ;;
esac
