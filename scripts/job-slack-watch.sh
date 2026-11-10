#!/bin/bash
# job-slack-watch.sh — collector for a `slack` / `watch` scheduled job.
#
# Phase 1 supports `watch: [channels]` only: the same channel scan, relevance judgment, routing and
# reconciliation as the global poll's scripts/poll-slack.sh, scoped to one project's channels and
# with its OWN cutoff file. The separate cutoff is what makes running alongside the global poll safe:
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

EA_POLL_STATE_FILE="${EA_AGENT_DIR}/state/jobs/${JOB}.state.yaml" \
EA_JOBS_IGNORE_EXCLUSIVE=1 \
EA_PHASE_A_ERRORS="$ERRORS" \
  bash "${SCRIPT_DIR}/poll-slack.sh" --project "$PROJECT" --manifest "$MANIFEST" ${RUN_TS:+--run-ts "$RUN_TS"}
