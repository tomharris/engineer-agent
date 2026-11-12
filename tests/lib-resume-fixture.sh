#!/bin/bash
# Shared by the implement-next job suites, whose git stub answers ls-remote with $LS_REMOTE.

# stopped_pipeline_fixture <job> <item> — <item>'s pipeline stopped on commit "old"; a second
# ledger item of <job> is pending in drafts/, so the job's guards skip a new pick. Run the job with
# LS_REMOTE=new for a branch that has moved since.
stopped_pipeline_fixture() {
  local d="$EA_AGENT_DIR/state/pr-pipeline/${2%.md}"
  mkdir -p "$d"
  echo tom/branch > "$d/branch"
  printf 'stopped\tCI still failing\n' > "$d/result"
  echo old > "$d/stopped_head"
  printf '%s\t%s\tr\tK-1\n%s\t%s\tr\tK-2\n' "$2" "$1" "pending-$2" "$1" >> "$EA_AGENT_DIR/state/autopilot-items.tsv"
  touch "$Q/drafts/pending-$2"
}
