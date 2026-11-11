#!/bin/bash
# jobs-tick.sh — scheduled-job dispatcher. Run every 60s by the engineer-agent-jobs scheduler entry
# (scripts/install-jobs.sh); runs alongside, and independently of, scripts/cron-poll.sh.
#
# Each tick: enumerate projects.<slug>.jobs, and for each valid, unpaused job that is inside its
# hours/days window and due (now >= last_run + every), launch it in the background. A tick with
# nothing due costs one config read and starts no model.
#
# ONE TICK + DUE-CHECK, NOT ONE SCHEDULER ENTRY PER JOB. Per-job LaunchAgents would multiply the
# launchd env-cache trap (an edited plist is inert until bootout+bootstrap), the TCC re-grant after
# every `claude` update, and the lockfile count.
#
# EACH JOB IS ISOLATED. Own PID lock (a held lock skips that job, not the tick), own wall-clock
# watchdog that kills its whole process tree, own receipt, own failure streak. Jobs run detached so
# a long drafting run never delays another job's tick — which is why the LaunchAgent sets
# AbandonProcessGroup (launchd otherwise kills a job's children when the tick exits).
#
# LIVENESS IS A RECEIPT THIS SCRIPT WRITES, never the model's word or an exit code: every run ends
# in state/jobs/<project>.<id>.receipt carrying a run_id minted here, including timed-out runs.
#
# Usage: jobs-tick.sh [--only <project>.<id>] [--force] [--foreground]
#   --only        consider just this job
#   --force       ignore last_run/every and hours/days (still honors pause, lock and validation)
#   --foreground  wait for launched jobs (tests, `jobs-ctl.sh run`); EA_JOBS_FOREGROUND=1 also works
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
# shellcheck source=lib-jobs.sh
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"
export PATH="${PATH}:${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/opt/homebrew/bin"   # appended: a caller's PATH (the installers', a test's stubs) wins

ONLY=""; FORCE=0; FOREGROUND="${EA_JOBS_FOREGROUND:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --only)       ONLY="$2"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    --foreground) FOREGROUND=1; shift ;;
    *) echo "jobs-tick.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

mkdir -p "$JOBS_STATE_DIR"
LOG_FILE="${EA_AGENT_DIR}/state/jobs.log"
JOB_MAX_SECONDS="${EA_JOB_MAX_SECONDS:-3600}"
NOTIFY="${EA_NOTIFY_BIN:-${PLUGIN_ROOT}/scripts/notify.sh}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"; }
push() { "$NOTIFY" --title "$1" --message "$2" --priority "$3" --tags warning --fyi >> "$LOG_FILE" 2>&1 || true; }

# job_body <slug> <key> <integration:action> <workdir> <run_ts> <budget>
# Writes "<status>\t<items>\t<drafting>" to <workdir>/result. Errors go to <workdir>/errors.
job_body() {
  local slug="$1" key="$2" kind="$3" w="$4" run_ts="$5" budget="$6" rc status=ok items=0 drafting=none
  case "$kind" in
    slack:watch)
      # EA_JOB_HANDLER_SLACK_WATCH: test seam — the real collector talks to Slack and TypeSafe.
      bash "${EA_JOB_HANDLER_SLACK_WATCH:-${PLUGIN_ROOT}/scripts/job-slack-watch.sh}" --project "$slug" --job "$key" \
        --manifest "$w/manifest.tsv" --errors "$w/errors" --run-ts "$run_ts" >> "$LOG_FILE" 2>&1
      rc=$? ;;
    jira:implement-next)
      bash "${EA_JOB_HANDLER_JIRA_IMPLEMENT_NEXT:-${PLUGIN_ROOT}/scripts/job-jira-implement-next.sh}" --job "$key" \
        --errors "$w/errors" --items "$w/items" ${budget:+--budget "$budget"} >> "$LOG_FILE" 2>&1
      rc=$?
      [ "$rc" = 0 ] && items="$(cat "$w/items" 2>/dev/null || echo 0)" ;;
    slack:cr-qa)
      bash "${EA_JOB_HANDLER_SLACK_CR_QA:-${PLUGIN_ROOT}/scripts/job-slack-cr-qa.sh}" --job "$key" \
        --errors "$w/errors" --items "$w/items" ${budget:+--budget "$budget"} >> "$LOG_FILE" 2>&1
      rc=$?
      [ "$rc" = 0 ] && items="$(cat "$w/items" 2>/dev/null || echo 0)" ;;
    github-issues:implement-next)
      bash "${EA_JOB_HANDLER_GITHUB_IMPLEMENT_NEXT:-${PLUGIN_ROOT}/scripts/job-github-implement-next.sh}" --job "$key" \
        --errors "$w/errors" --items "$w/items" ${budget:+--budget "$budget"} >> "$LOG_FILE" 2>&1
      rc=$?
      [ "$rc" = 0 ] && items="$(cat "$w/items" 2>/dev/null || echo 0)" ;;
    *) echo "no handler for ${kind}" >> "$w/errors"; rc=2 ;;
  esac
  case "${kind}:${rc}" in
    *:0) ;;
    slack:watch:3) status=error; echo "collector unavailable (exit 3): check agent.typesafe credential, curl and jq — see state/jobs.log" >> "$w/errors" ;;
    slack:watch:*) status=error; echo "collector exited ${rc} — see state/jobs.log" >> "$w/errors" ;;
    *:3) status=error; [ -s "$w/errors" ] || echo "${kind} unavailable (exit 3) — see state/jobs.log" >> "$w/errors" ;;
    *) status=error; [ -s "$w/errors" ] || echo "${kind} exited ${rc} — see state/jobs.log" >> "$w/errors" ;;
  esac
  [ "$status" = ok ] && [ -s "$w/errors" ] && status=partial

  if [ -s "$w/manifest.tsv" ]; then
    items="$(grep -c . "$w/manifest.tsv")"
    bash "${PLUGIN_ROOT}/scripts/jobs-draft.sh" --manifest "$w/manifest.tsv" --job "$key" \
      ${budget:+--budget "$budget"} >> "$LOG_FILE" 2>&1
    case "$?" in
      0) drafting=done ;;
      4) drafting=deferred ;;   # poll holds the lock; next tick's resume sweep retries
      *) drafting=incomplete
         echo "drafting incomplete — some items were not moved to drafts/ (see state/jobs.log)" >> "$w/errors"
         [ "$status" = ok ] && status=partial ;;
    esac
  fi
  printf '%s\t%s\t%s\n' "$status" "$items" "$drafting" > "$w/result"
}

# run_job <slug> <id> <integration> <action> <budget> <pause_after> — runs detached from the tick.
run_job() {
  local slug="$1" id="$2" kind="$3:$4" budget="$5" pause_after="${6:-3}"
  local key run_id started w bpid wpid status items drafting outcome
  key="$(job_key "$slug" "$id")"
  job_lock "$key" "$BASHPID" || { log "${key}: previous run still in progress; skipping"; return 0; }
  trap 'job_unlock "'"$key"'"' EXIT
  jobs_now > "$(job_path "$key" last-run)"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}"
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  w="$(job_path "$key" run)"; rm -rf "$w"; mkdir -p "$w"; : > "$w/errors"
  log "${key}: started run ${run_id}"

  job_body "$slug" "$key" "$kind" "$w" "$started" "$budget" &
  bpid=$!
  (
    s=""
    trap '[ -n "$s" ] && kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$JOB_MAX_SECONDS" & s=$!; wait "$s"
    touch "$w/timed-out"
    jobs_kill_tree "$bpid"
  ) </dev/null >/dev/null 2>&1 &
  wpid=$!
  wait "$bpid" 2>/dev/null
  kill -TERM "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null

  if [ -e "$w/timed-out" ]; then
    status=error; items=0; drafting=none
    echo "timed out after ${JOB_MAX_SECONDS}s and was killed" >> "$w/errors"
  elif [ -s "$w/result" ]; then
    IFS="	" read -r status items drafting < "$w/result"
  else
    status=error; items=0; drafting=none
    echo "job body exited without a result" >> "$w/errors"
  fi

  job_write_receipt "$key" "$run_id" "$started" "$status" "$items" "$w/errors" "$drafting"
  log "${key}: finished run ${run_id} status=${status} items=${items} drafting=${drafting}"

  outcome="$(job_record_outcome "$key" "$status" "$pause_after")"
  case "$outcome" in
    paused)
      push "engineer-agent: job ${key} paused" \
        "Failed ${pause_after} run(s) in a row and is paused. Last error: $(head -1 "$w/errors" | cut -c1-200). Resume: /engineer-agent jobs resume ${key}" urgent ;;
    first)
      push "engineer-agent: job ${key} failed" \
        "$(head -1 "$w/errors" | cut -c1-200). See state/jobs/${key}.receipt." high ;;
  esac
}

jobs_cfg_load
ROWS="$(jobs_enumerate)"
[ -n "$ROWS" ] || exit 0

NOW="$(jobs_now)"
PIDS=()
while IFS='|' read -r slug idx id integ action every hours days watch excl sup budget pause; do
  [ -n "$slug" ] || continue
  key="$(job_key "$slug" "$id")"
  [ -z "$ONLY" ] || [ "$ONLY" = "$key" ] || continue
  row="${slug}|${idx}|${id}|${integ}|${action}|${every}|${hours}|${days}|${watch}|${excl}|${sup}|${budget}|${pause}"
  if reason="$(jobs_validate "$row" "$ROWS")"; then
    rm -f "$(job_path "$key" invalid)"
  else
    # Recorded (for status) and logged only when the reason changes, so a bad config entry does not
    # write a log line every minute.
    if [ "$(cat "$(job_path "$key" invalid)" 2>/dev/null)" != "$reason" ]; then
      printf '%s\n' "$reason" > "$(job_path "$key" invalid)"
      log "${key}: invalid, not running: ${reason}"
    fi
    continue
  fi
  job_is_paused "$key" && continue
  if [ "$FORCE" -eq 0 ]; then
    jobs_in_window "$hours" "$days" "$NOW" || continue
    jobs_is_due "$key" "$(jobs_duration_seconds "$every")" "$NOW" || continue
  fi
  if [ "$FOREGROUND" = "1" ]; then
    ( run_job "$slug" "$id" "$integ" "$action" "$budget" "${pause:-3}" ) &
    PIDS+=("$!")
  else
    ( run_job "$slug" "$id" "$integ" "$action" "$budget" "${pause:-3}" ) </dev/null >/dev/null 2>&1 &
    disown
  fi
done <<< "$ROWS"

for p in "${PIDS[@]+"${PIDS[@]}"}"; do wait "$p"; done
exit 0
