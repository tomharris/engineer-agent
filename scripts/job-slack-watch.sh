#!/bin/bash
# job-slack-watch.sh — collector for a `slack` / `watch` scheduled job.
#
# Runs scripts/poll-slack.sh for one project with the job's `watch` sources (default: channels):
# the same relevance judgment, routing and reconciliation as the global poll, with its OWN cutoff
# file. The separate cutoff is what makes running alongside the global poll safe:
# both do a read-modify-write of their state file, and sharing last-poll.yaml would lose updates.
# Anything both paths find is deduplicated by the queue's (type, source_id) reconciliation.
#
# Usage: job-slack-watch.sh --project <slug> --job <key> --manifest <file> --errors <file> --run-ts <iso>
# Exit:  poll-slack.sh's (0 ok, 3 unavailable — e.g. no agent.typesafe credential).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib-paths.sh"

PROJECT=""; JOB=""; MANIFEST=""; ERRORS=""; RUN_TS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)  PROJECT="$2"; shift 2 ;;
    --job)      JOB="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --errors)   ERRORS="$2"; shift 2 ;;
    --run-ts)   RUN_TS="$2"; shift 2 ;;
    *) echo "job-slack-watch.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] && [ -n "$JOB" ] && [ -n "$MANIFEST" ] || { echo "job-slack-watch.sh: missing arguments" >&2; exit 2; }

. "${SCRIPT_DIR}/lib-jobs.sh"
jobs_cfg_load
IDX="$(jobs_enumerate | awk -F'|' -v k="$JOB" '($1 "." $3) == k { print $2; exit }')"
[ -n "$IDX" ] || { echo "job-slack-watch.sh: no such job: $JOB" >&2; exit 2; }
SOURCES="$(_jcfgl "projects.${PROJECT}.job.${IDX}.watch")"; SOURCES="${SOURCES:-channels}"
TTL="$(_jcfg "projects.${PROJECT}.job.${IDX}.thread_ttl")"; TTL="$(jobs_duration_seconds "${TTL:-7d}")"

EA_POLL_STATE_FILE="${EA_AGENT_DIR}/state/jobs/${JOB}.state.yaml" \
EA_JOBS_IGNORE_EXCLUSIVE=1 \
EA_PHASE_A_ERRORS="$ERRORS" \
  bash "${SCRIPT_DIR}/poll-slack.sh" --project "$PROJECT" --manifest "$MANIFEST" ${RUN_TS:+--run-ts "$RUN_TS"} \
    --sources "$SOURCES" --thread-ttl "$TTL"
