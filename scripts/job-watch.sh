#!/bin/bash
# job-watch.sh — collector for an `<integration>` / `watch` scheduled job.
#
# Runs one project's Phase A collector (scripts/poll-<source>.sh --project) with the same routing,
# classification and reconciliation as the global poll, but its OWN state file. The separate state
# file is what makes running alongside the global poll safe: both do a read-modify-write of their
# state, and sharing last-poll.yaml would lose updates. Anything both paths find is deduplicated by
# the queue's (type, source_id) reconciliation.
#
# slack also takes the job's `watch` sources (default: channels) and `thread_ttl`.
#
# Usage: job-watch.sh --integration <github|github-issues|jira|slite|slack> --project <slug>
#                     --job <key> --manifest <file> --errors <file> [--run-ts <iso>]
# Exit:  the collector's (0 ok, 3 unavailable — e.g. no jq or credential); 2 usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib-paths.sh"

INTEG=""; PROJECT=""; JOB=""; MANIFEST=""; ERRORS=""; RUN_TS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --integration) INTEG="$2"; shift 2 ;;
    --project)     PROJECT="$2"; shift 2 ;;
    --job)         JOB="$2"; shift 2 ;;
    --manifest)    MANIFEST="$2"; shift 2 ;;
    --errors)      ERRORS="$2"; shift 2 ;;
    --run-ts)      RUN_TS="$2"; shift 2 ;;
    *) echo "job-watch.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$INTEG" ] && [ -n "$PROJECT" ] && [ -n "$JOB" ] && [ -n "$MANIFEST" ] \
  || { echo "job-watch.sh: missing arguments" >&2; exit 2; }

case "$INTEG" in
  github)        COLLECTOR=poll-github-prs.sh ;;
  github-issues) COLLECTOR=poll-github-issues.sh ;;
  jira)          COLLECTOR=poll-jira.sh ;;
  slite)         COLLECTOR=poll-slite.sh ;;
  slack)         COLLECTOR=poll-slack.sh ;;
  *) echo "job-watch.sh: unsupported integration '$INTEG'" >&2; exit 2 ;;
esac

EXTRA=()
if [ "$INTEG" = slack ]; then
  . "${SCRIPT_DIR}/lib-jobs.sh"
  jobs_cfg_load
  IDX="$(jobs_enumerate | awk -F'|' -v k="$JOB" '($1 "." $3) == k { print $2; exit }')"
  [ -n "$IDX" ] || { echo "job-watch.sh: no such job: $JOB" >&2; exit 2; }
  SOURCES="$(_jcfgl "projects.${PROJECT}.job.${IDX}.watch")"; SOURCES="${SOURCES:-channels}"
  TTL="$(_jcfg "projects.${PROJECT}.job.${IDX}.thread_ttl")"; TTL="$(jobs_duration_seconds "${TTL:-7d}")"
  EXTRA=(--sources "$SOURCES" --thread-ttl "$TTL")
fi

EA_POLL_STATE_FILE="${EA_AGENT_DIR}/state/jobs/${JOB}.state.yaml" \
EA_JOBS_IGNORE_EXCLUSIVE=1 \
EA_PHASE_A_ERRORS="$ERRORS" \
  bash "${SCRIPT_DIR}/${COLLECTOR}" --project "$PROJECT" --manifest "$MANIFEST" ${RUN_TS:+--run-ts "$RUN_TS"} \
    ${EXTRA[@]+"${EXTRA[@]}"}
