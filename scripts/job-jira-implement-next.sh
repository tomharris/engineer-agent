#!/bin/bash
# job-jira-implement-next.sh — the jira / implement-next scheduled job: pick the next ticket by the
# job's rules, queue it, and (only with both autonomy tiers) claim and implement it.
#
# Usage: job-jira-implement-next.sh --job <project>.<id> --errors <file> --items <file> [--budget <usd>]
# Exit: 0 ok (including "guard skipped" and "nothing eligible"), 1 failed, 3 Jira unavailable.
#
# Sequence (spec "Run sequence"): guards → select → write drafts/ item → either push for Approve
# (the listener then claims with --approved) or claim → confined implementation → rollback.
#
# UNATTENDED needs `implement` AND `jira-claim` in auto_execute AND trusted authorship: the ticket's
# creator and the author of every changelog edit to a field written into the queue item (summary,
# description, labels, components) must be in the job's trusted_authors. The confined run can
# execute code as the user (build commands run files the model edits), so without that, anyone
# able to file a matching ticket could steer it. The check
# and the queue item come from ONE fetch, and the confined run has no Jira access, so the text the
# model sees is exactly the text that was checked. Anything short of it falls back to Approve.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"
. "${PLUGIN_ROOT}/scripts/lib-time.sh"
. "${PLUGIN_ROOT}/scripts/lib-queue.sh"
. "${PLUGIN_ROOT}/scripts/lib-queue-write.sh"
. "${PLUGIN_ROOT}/scripts/lib-secret.sh"
. "${PLUGIN_ROOT}/scripts/lib-jira-api.sh"
. "${PLUGIN_ROOT}/scripts/lib-ticket-kind.sh"
. "${PLUGIN_ROOT}/scripts/lib-confined-run.sh"
. "${PLUGIN_ROOT}/scripts/lib-review.sh"

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
ar_jira_init || { err "Jira unavailable: ${AR_ERR}"; exit 3; }
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
_arcl "projects.${SLUG}.investigation.jira_types" > "$TMPD/jira_types"
export AR_JIRA_TYPES_FILE="$TMPD/jira_types"
pick="$(AR_TRACE=1 ar_select "$SLUG" "$IDX" 2>>"$LOG_FILE")"; rc=$?
case "$rc" in
  0) ;;
  1) log "nothing eligible"; exit 0 ;;
  *) err "selection failed: ${pick}"; exit 1 ;;
esac
IFS="	" read -r RULE KEY _ <<< "$pick"

# --- 3. queue item --------------------------------------------------------------------------------
code="$(jira_api "$TMPD/issue.json" GET "/issue/${KEY}?fields=summary,description,issuetype,components,labels,status,priority,creator&expand=changelog")"
[ "$code" = 200 ] || { err "could not read ${KEY} (HTTP ${code})"; exit 1; }
# The key written to the queue is the API's, never one parsed from ticket text.
[ "$(jq -r '.key // ""' "$TMPD/issue.json")" = "$KEY" ] || { err "issue response key mismatch for ${KEY}"; exit 1; }
jq -r '.fields.description // ""'           "$TMPD/issue.json" > "$TMPD/body"
jq -r '.fields.labels[]? // empty'          "$TMPD/issue.json" > "$TMPD/labels"
jq -r '.fields.components[]?.name // empty' "$TMPD/issue.json" > "$TMPD/comps"
case "$(jq -r '.fields.priority.name // "" | ascii_downcase' "$TMPD/issue.json")" in
  highest|high) prio=urgent ;; low|lowest) prio=low ;; *) prio=normal ;;
esac
URL="https://${JIRA_SITE}/browse/${KEY}"
ITEM="$(queue_filename ticket "$KEY" "$(queue_ts)")"
DRAFT="${AGENT_DIR}/queue/drafts/${ITEM}"
mkdir -p "$(dirname "$DRAFT")"
write_ticket_item --path "$DRAFT" --type ticket --source jira --source-url "$URL" --source-id "$KEY" \
  --title "$(jq -r '.fields.summary // ""' "$TMPD/issue.json")" --priority "$prio" \
  --created-at "$(iso_now)" --project "$SLUG" --ticket-key "$KEY" \
  --state "$(jq -r '.fields.status.name // ""' "$TMPD/issue.json")" \
  --jira-issue-type "$(jq -r '.fields.issuetype.name // ""' "$TMPD/issue.json")" \
  --labels-file "$TMPD/labels" --components-file "$TMPD/comps" \
  --kind-method jira-issuetype --body-file "$TMPD/body"
fm_set "$DRAFT" status drafted
fm_set "$DRAFT" autopilot true
fm_set "$DRAFT" autopilot_job "$JOB"
fm_set "$DRAFT" autopilot_rule "$RULE"
cat >> "$DRAFT" <<EOF

## Draft Response

Autopilot pick: job \`${JOB}\`, rule \`${RULE}\`. Approving claims ${KEY} in Jira (per the rule's
\`claim\`), implements it in a confined worktree, and opens a draft PR. On failure the claim is
rolled back per the rule's \`on_fail\`.
EOF
autopilot_record "$ITEM" "$JOB" "$RULE" "$KEY"
job_record_pick "$JOB" "$ITEM"
echo 1 > "$ITEMS"
log "picked ${KEY} (rule ${RULE}) -> drafts/${ITEM}"

# --- 4. gate --------------------------------------------------------------------------------------
# untrusted_reason — empty when every author of the text the model will read is trusted.
# Account ids only: a display name is attacker-chosen text and must not reach the push.
untrusted_reason() { jira_untrusted_reason "$TMPD/issue.json" "$(_arcl "${P}.trusted_authors")"; }
gate=""
if ! jobs_autonomy_allows implement || ! jobs_autonomy_allows jira-claim; then
  gate="autonomy tiers implement and jira-claim not both set"
else
  gate="$(untrusted_reason)"
fi
if [ -n "$gate" ]; then
  printf '\nUnattended run not allowed: %s.\n' "$gate" >> "$DRAFT"
  "$NOTIFY" --title "Autopilot: ${KEY}" \
    --message "Job ${JOB} (rule ${RULE}) picked ${KEY}. Approve to claim and implement it. (${gate})" \
    --priority normal --item-id "$ITEM" --source-url "$URL" </dev/null >>"$LOG_FILE" 2>&1 || true
  log "awaiting Approve for ${ITEM}: ${gate}"
  exit 0
fi
record_ticket_text "$ITEM" "$(jq -r '.fields.summary // ""' "$TMPD/issue.json")" "$TMPD/body"

# --- 5. claim + implement -------------------------------------------------------------------------
# A watchdog kill must not leave the ticket claimed with nobody working on it.
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
