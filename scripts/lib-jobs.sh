#!/bin/bash
# lib-jobs.sh — scheduled jobs: config enumeration, validation, due/window checks, per-job state.
#
# A job is (project, integration, action, every). scripts/jobs-tick.sh runs every minute and asks
# this library which jobs are due; everything a job needs to be safe to run unattended — its lock,
# receipt, failure streak and pause marker — lives under state/jobs/<project>.<id>.*.
#
# Config comes from `ea-config.sh dump` (projects.<slug>.job.<N>.*), which only SHAPES the data.
# Semantic validation is here so the dispatcher, `jobs-ctl.sh list` and `status` agree on which
# jobs are runnable and why the rest are not.
#
# Requires lib-paths.sh (EA_AGENT_DIR).

JOBS_STATE_DIR="${EA_AGENT_DIR}/state/jobs"
JOBS_MIN_EVERY=60
JOBS_DAYS="mon tue wed thu fri sat sun"
# `reactions` (trigger emoji) is specified but not built yet.
JOBS_SLACK_WATCH_SUPPORTED="channels mentions my-threads"

_jobs_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-assign-rules.sh
. "${_jobs_script_dir}/lib-assign-rules.sh"
# shellcheck source=lib-gh-assign-rules.sh
. "${_jobs_script_dir}/lib-gh-assign-rules.sh"

# jobs_now — epoch; EA_NOW overrides for tests.
jobs_now() { printf '%s' "${EA_NOW:-$(date +%s)}"; }

# _jobs_local <epoch> <fmt> — format an epoch in the MACHINE LOCAL timezone (spec decision).
_jobs_local() {
  if date -d "@$1" +%s >/dev/null 2>&1; then LC_ALL=C date -d "@$1" "+$2"
  else LC_ALL=C date -r "$1" "+$2"; fi
}

# jobs_duration_seconds <5m|30s|2h|1d> — prints seconds, or nothing if malformed.
jobs_duration_seconds() {
  local v="${1:-}" n u
  [[ "$v" =~ ^([0-9]+)([smhd])$ ]] || return 0
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  n=$((10#$n))
  case "$u" in s) echo "$n" ;; m) echo $((n*60)) ;; h) echo $((n*3600)) ;; d) echo $((n*86400)) ;; esac
}

# jobs_autonomy_allows <tier> — rc 0 if the tier is in agent.autonomy.auto_execute (deny-by-default).
jobs_autonomy_allows() {
  jobs_cfg_load
  printf '%s\n' "$EA_JOBS_CFG" | grep -qxF "agent.autonomy.auto_execute[]=$1"
}

jobs_cfg_load() {
  [ -n "${EA_JOBS_CFG:-}" ] && return 0
  EA_JOBS_CFG="$("${_jobs_script_dir}/ea-config.sh" dump 2>/dev/null)"
}
_jcfg()  { printf '%s\n' "$EA_JOBS_CFG" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); gsub(/\|/,"?"); print; exit}'; }
_jcfgl() { printf '%s\n' "$EA_JOBS_CFG" | awk -v p="$1[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}' | tr '|' '?' | paste -sd, -; }

# jobs_enumerate — one '|'-separated row per configured job (not tab: `read` collapses empty
# tab-separated fields, shifting every column after an unset `hours`):
#   slug idx id integration action every hours days watch exclusive supported budget_usd pause_after
jobs_enumerate() {
  jobs_cfg_load
  local slug n i p
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    n="$(_jcfg "projects.${slug}.job_count")"
    [ "${n:-0}" -gt 0 ] 2>/dev/null || continue
    i=0
    while [ "$i" -lt "$n" ]; do
      p="projects.${slug}.job.${i}"
      printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$slug" "$i" \
        "$(_jcfg "${p}.id")" "$(_jcfg "${p}.integration")" "$(_jcfg "${p}.action")" \
        "$(_jcfg "${p}.every")" "$(_jcfg "${p}.hours")" "$(_jcfgl "${p}.days")" \
        "$(_jcfgl "${p}.watch")" "$(_jcfg "${p}.exclusive")" "$(_jcfg "${p}.supported")" \
        "$(_jcfg "${p}.budget_usd")" "$(_jcfg "${p}.pause_after_failures")"
      i=$((i+1))
    done
  done < <(printf '%s\n' "$EA_JOBS_CFG" | awk 'index($0,"project[]=")==1 {print substr($0,11)}')
}

# jobs_validate <row> — prints a reason and returns 1 if the job must not run; silent 0 if valid.
# Needs the full enumeration to detect duplicate ids, so pass it as $2.
jobs_validate() {
  local row="$1" all="$2" slug idx id integ action every hours days watch excl sup budget pause secs d w
  IFS='|' read -r slug idx id integ action every hours days watch excl sup budget pause <<< "$row"
  [[ "$id" =~ ^[a-z0-9-]+$ ]] || { echo "id '${id}' must match ^[a-z0-9-]+\$"; return 1; }
  [ "$(printf '%s\n' "$all" | awk -F'|' -v s="$slug" -v i="$id" '$1==s && $3==i' | wc -l | tr -d ' ')" -eq 1 ] \
    || { echo "duplicate job id '${id}' in project ${slug}"; return 1; }
  case "${integ}:${action}" in
    jira:implement-next)
      ar_validate "$slug" "$idx" || return 1
      jobs_validate_implement "$slug" "$idx" jira || return 1 ;;
    github-issues:implement-next)
      gr_validate "$slug" "$idx" || return 1
      jobs_validate_implement "$slug" "$idx" github-issues || return 1 ;;
    slack:cr-qa)
      jobs_validate_cr_qa "$slug" "$idx" || return 1 ;;
  esac
  [ "$sup" = "1" ] || { echo "unsupported integration/action '${integ}:${action}'"; return 1; }
  secs="$(jobs_duration_seconds "$every")"
  [ -n "$secs" ] || { echo "every '${every}' must look like 30s, 5m, 2h or 1d"; return 1; }
  [ "$secs" -ge "$JOBS_MIN_EVERY" ] || { echo "every '${every}' is below the 1m floor"; return 1; }
  if [ -n "$hours" ]; then
    if [[ "$hours" =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]]; then
      [ $((10#${BASH_REMATCH[1]})) -lt $((10#${BASH_REMATCH[2]})) ] && [ $((10#${BASH_REMATCH[2]})) -le 24 ] \
        || { echo "hours '${hours}' must be start-end with 0 <= start < end <= 24"; return 1; }
    else
      echo "hours '${hours}' must look like 9-17"; return 1
    fi
  fi
  if [ -n "$days" ]; then
    for d in ${days//,/ }; do
      case " $JOBS_DAYS " in *" $d "*) ;; *) echo "days entry '${d}' must be one of: ${JOBS_DAYS}"; return 1 ;; esac
    done
  fi
  if [ -n "$budget" ] && ! [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "budget_usd '${budget}' must be a number"; return 1
  fi
  if [ -n "$pause" ] && ! [[ "$pause" =~ ^[1-9][0-9]*$ ]]; then
    echo "guards.pause_after_failures '${pause}' must be a positive integer"; return 1
  fi
  if [ "${integ}:${action}" = "slack:watch" ]; then
    for w in ${watch//,/ }; do
      case " $JOBS_SLACK_WATCH_SUPPORTED " in *" $w "*) ;; *) echo "watch source '${w}' is not supported yet (supported: ${JOBS_SLACK_WATCH_SUPPORTED})"; return 1 ;; esac
    done
    jobs_cfg_load
    case ",${watch}," in
      *,mentions,*) [ -n "$(_jcfg agent.slack.user_id)" ] || { echo "watch source 'mentions' needs agent.slack.user_id"; return 1; } ;;
    esac
    d="$(_jcfg "projects.${slug}.job.${idx}.thread_ttl")"
    [ -z "$d" ] || [ -n "$(jobs_duration_seconds "$d")" ] || { echo "thread_ttl '${d}' must look like 12h or 7d"; return 1; }
  fi
  return 0
}

# jobs_validate_implement <slug> <idx> <jira|github-issues> — guards and the sandbox prerequisite.
# Deny-by-default: the allowlist check uses the same reader and charset as
# run_ticket_implementation, so a job that validates here cannot be refused there for a missing
# build list.
jobs_validate_implement() {
  local slug="$1" idx="$2" tracker="$3" v c ok=0 re what
  for v in max_in_flight daily_cap; do
    c="$(_jcfg "projects.${slug}.job.${idx}.${v}")"
    [ -z "$c" ] || [[ "$c" =~ ^[1-9][0-9]*$ ]] || { echo "guards.${v} '${c}' must be a positive integer"; return 1; }
  done
  case "$tracker" in
    jira) re='^[A-Za-z0-9:_-]+$'; what="a Jira accountId" ;;
    *)    re='^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$'; what="a GitHub login" ;;
  esac
  while IFS= read -r c; do
    [ -z "$c" ] || [[ "$c" =~ $re ]] || { echo "trusted_authors entry '${c}' is not ${what}"; return 1; }
  done < <(printf '%s\n' "$EA_JOBS_CFG" | awk -v p="projects.${slug}.job.${idx}.trusted_authors[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}')
  [ "$(_jcfg "projects.${slug}.tracker")" = "$tracker" ] || { echo "${tracker}:implement-next needs a project with tracker ${tracker}"; return 1; }
  if [ "$tracker" = github-issues ]; then
    [ -n "$(gr_project_repos "$slug")" ] || { echo "github-issues:implement-next needs projects.${slug}.github.owner and github.repos"; return 1; }
  fi
  while IFS= read -r c; do
    [[ "$c" =~ ^[A-Za-z0-9._/-]+$ ]] && ok=1
  done < <(yaml_project_list "$slug" exec allowed_commands)
  [ "$ok" = 1 ] || { echo "${tracker}:implement-next needs projects.${slug}.exec.allowed_commands (build/test commands for the confined run)"; return 1; }
  jobs_validate_after_pr "$slug" "$idx"
}

# jobs_validate_cr_qa <slug> <idx> — the slack/cr-qa job (scripts/job-slack-cr-qa.sh). Unknown keys
# under reactions/security/qa are errors, as for after_pr.
jobs_validate_cr_qa() {
  local p="projects.$1.job.$2" v
  jobs_cfg_load   # callers may have enumerated in a subshell (jobs-ctl list)
  [ -n "$(_jcfg "$p.channel")" ] || { echo "cr-qa needs channel"; return 1; }
  [ -n "$(_jcfgl "$p.trusted_slack_users")" ] || { echo "cr-qa needs trusted_slack_users"; return 1; }
  [ -n "$(_jcfgl "$p.trusted_authors")" ] || { echo "cr-qa needs trusted_authors"; return 1; }
  [ -n "$(_jcfg "$p.transition")" ] || { echo "cr-qa needs transition"; return 1; }
  [ "$(_jcfg "projects.$1.tracker")" = jira ] || { echo "cr-qa needs projects.$1.tracker: jira"; return 1; }
  [ -n "$(gr_project_repos "$1")" ] || { echo "cr-qa needs projects.$1.github.repos"; return 1; }
  _ar_check_keys "$p.reactions" "claim approve" "reactions" || return 1
  _ar_check_keys "$p.security" "command timeout" "security" || return 1
  _ar_check_keys "$p.qa" "timeout" "qa" || return 1
  v="$(_jcfg "$p.security.command")"
  [ -n "$v" ] || { echo "cr-qa security.command is required"; return 1; }
  case "$v" in /*|"~/"*) ;; *) echo "cr-qa security.command '${v}' must be an absolute or ~/ path"; return 1 ;; esac
  for v in security.timeout qa.timeout; do
    [ -z "$(_jcfg "$p.$v")" ] || [ -n "$(jobs_duration_seconds "$(_jcfg "$p.$v")")" ] \
      || { echo "cr-qa ${v} '$(_jcfg "$p.$v")' must look like 30s, 5m, 2h or 1d"; return 1; }
  done
}

# jobs_validate_after_pr <slug> <idx> — the optional after_pr block (scripts/pr-pipeline.sh).
# Unknown keys are errors: a mistyped `mark_redy` must not silently leave a PR in draft forever.
jobs_validate_after_pr() {
  local p="projects.$1.job.$2.after_pr" k v
  [ -n "$(_ar_children "$p")" ] || return 0
  _ar_check_keys "$p" "budget_usd max_runtime mark_ready ci browser security qa transition announce" "after_pr" || return 1
  _ar_check_keys "$p.ci" "timeout fix_attempts" "after_pr.ci" || return 1
  _ar_check_keys "$p.browser" "setup serve url ready_timeout instructions chrome_device" "after_pr.browser" || return 1
  _ar_check_keys "$p.security" "command fix_attempts timeout" "after_pr.security" || return 1
  _ar_check_keys "$p.qa" "document" "after_pr.qa" || return 1
  _ar_check_keys "$p.announce" "channel" "after_pr.announce" || return 1
  [ -n "$(gr_project_repos "$1")" ] || { echo "after_pr needs projects.$1.github.owner and github.repos"; return 1; }
  v="$(_arc "$p.budget_usd")"
  [ -z "$v" ] || [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "after_pr.budget_usd '${v}' must be a number"; return 1; }
  for k in max_runtime ci.timeout browser.ready_timeout security.timeout; do
    v="$(_arc "$p.$k")"
    [ -z "$v" ] || [ -n "$(jobs_duration_seconds "$v")" ] || { echo "after_pr.${k} '${v}' must look like 30m or 2h"; return 1; }
  done
  v="$(_arc "$p.ci.fix_attempts")"
  [ -z "$v" ] || [[ "$v" =~ ^[0-3]$ ]] || { echo "after_pr.ci.fix_attempts '${v}' must be 0-3"; return 1; }
  v="$(_arc "$p.mark_ready")"
  _ar_bool "$v" || { echo "after_pr.mark_ready '${v}' must be true or false"; return 1; }
  if [ -n "$(_ar_children "$p.security")" ]; then
    v="$(_arc "$p.security.command")"
    [ -n "$v" ] || { echo "after_pr.security.command is required"; return 1; }
    case "$v" in /*|"~/"*) ;; *) echo "after_pr.security.command '${v}' must be an absolute or ~/ path"; return 1 ;; esac
  fi
  v="$(_arc "$p.security.fix_attempts")"
  [ -z "$v" ] || [[ "$v" =~ ^[0-3]$ ]] || { echo "after_pr.security.fix_attempts '${v}' must be 0-3"; return 1; }
  v="$(_arc "$p.qa.document")"
  _ar_bool "$v" || { echo "after_pr.qa.document '${v}' must be true or false"; return 1; }
  if [ "$v" = true ] && { [ "$(_arc "projects.$1.qa.document_to")" != slite ] || [ -z "$(_arc "projects.$1.qa.document_parent")" ]; }; then
    echo "after_pr.qa.document needs projects.$1.qa.document_to: slite and document_parent"; return 1
  fi
  if [ -n "$(_arc "$p.transition")" ] && [ "$(_arc "projects.$1.job.$2.integration")" != jira ]; then
    echo "after_pr.transition needs a jira job"; return 1
  fi
  v="$(_arc "$p.announce.channel")"
  if [ -n "$v" ] && ! _arcl "projects.$1.slack.channels" | grep -qxF -- "$v"; then
    echo "after_pr.announce.channel '${v}' is not one of projects.$1.slack.channels"; return 1
  fi
  if [ -n "$(_ar_children "$p.browser")" ]; then
    [ -n "$(_arc "$p.browser.serve")" ] || { echo "after_pr.browser.serve is required"; return 1; }
    [[ "$(_arc "$p.browser.url")" =~ ^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?(/|$) ]] \
      || { echo "after_pr.browser.url must be an http://localhost[:port] URL (the branch is served locally)"; return 1; }
    v="$(_arc "$p.browser.chrome_device")"
    [ -z "$v" ] || [[ "$v" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
      || { echo "after_pr.browser.chrome_device '${v}' must be a Claude in Chrome deviceId (a UUID)"; return 1; }
  fi
  return 0
}

# job_record_pick <key> <item> / job_picks_today <key> — the daily_cap ledger, keyed by the
# MACHINE LOCAL date (spec decision), in state/jobs/<key>.picks.
job_record_pick() { mkdir -p "$JOBS_STATE_DIR"; printf '%s\t%s\n' "$(_jobs_local "$(jobs_now)" %Y-%m-%d)" "$2" >> "$(job_path "$1" picks)"; }
job_picks_today() {
  local f; f="$(job_path "$1" picks)"
  [ -f "$f" ] || { echo 0; return 0; }
  awk -F'\t' -v d="$(_jobs_local "$(jobs_now)" %Y-%m-%d)" '$1==d {n++} END {print n+0}' "$f"
}

# jobs_in_window <hours> <days-csv> <epoch> — 0 if the epoch's LOCAL time is inside the window.
# hours "9-17" means 09:00 inclusive to 17:00 exclusive. Empty means unrestricted.
jobs_in_window() {
  local hours="$1" days="$2" now="$3" h d
  if [ -n "$days" ]; then
    d="$(_jobs_local "$now" %a | tr '[:upper:]' '[:lower:]')"
    case ",${days}," in *",${d},"*) ;; *) return 1 ;; esac
  fi
  if [ -n "$hours" ]; then
    h=$((10#$(_jobs_local "$now" %H)))
    [ "$h" -ge $((10#${hours%-*})) ] && [ "$h" -lt $((10#${hours#*-})) ] || return 1
  fi
  return 0
}

job_key()  { printf '%s.%s' "$1" "$2"; }
job_path() { printf '%s/%s.%s' "$JOBS_STATE_DIR" "$1" "$2"; }   # job_path <key> <suffix>

job_last_run() { cat "$(job_path "$1" last-run)" 2>/dev/null || true; }

# jobs_is_due <key> <every_secs> <epoch>
jobs_is_due() {
  local last; last="$(job_last_run "$1")"
  [ -n "$last" ] || return 0
  [ "$3" -ge $((last + $2)) ]
}

job_is_paused() { [ -e "$(job_path "$1" paused)" ]; }

# job_lock <key> — PID lock; reclaims a stale lock from a dead PID. Returns 1 if held.
job_lock() {
  local f pid; f="$(job_path "$1" lock)"
  mkdir -p "$JOBS_STATE_DIR"
  if [ -f "$f" ]; then
    pid="$(cat "$f" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 1
  fi
  echo "${2:-$$}" > "$f"
}
job_unlock() { rm -f "$(job_path "$1" lock)"; }

# job_write_receipt <key> <run_id> <started_iso> <status> <items> <errors-file> [drafting]
# drafting: none | done | deferred (the poll held the lock) | incomplete
job_write_receipt() {
  local key="$1" f tmp e
  f="$(job_path "$key" receipt)"; tmp="${f}.tmp.$$"
  {
    printf 'run_id: "%s"\n' "$2"
    printf 'started_at: "%s"\n' "$3"
    printf 'finished_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'status: %s\n' "$4"
    printf 'items: %s\n' "${5:-0}"
    printf 'drafting: %s\n' "${7:-none}"
    if [ -s "${6:-}" ]; then
      printf 'errors:\n'
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        printf '  - "%s"\n' "$(printf '%s' "$e" | tr -d '"\\' | cut -c1-300)"
      done < "$6"
    else
      printf 'errors: []\n'
    fi
  } > "$tmp" && mv "$tmp" "$f"
}

# job_receipt_field <key> <field>
job_receipt_field() {
  awk -v k="$2" 'index($0, k ": ") == 1 { v = substr($0, length(k) + 3); gsub(/^"|"$/, "", v); print v; exit }' \
    "$(job_path "$1" receipt)" 2>/dev/null
}

# job_record_outcome <key> <status> <pause_after> — maintain the failure streak. Prints "first" on
# a streak's first failure and "paused" on the run that crosses the threshold (which wins when both
# apply), so the caller pushes at most two alerts per streak instead of one per run.
job_record_outcome() {
  local key="$1" status="$2" limit="${3:-3}" f n
  f="$(job_path "$key" failures)"
  if [ "$status" = "error" ]; then
    n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$f"
    if [ "$n" -ge "$limit" ] && ! job_is_paused "$key"; then
      date -u +%Y-%m-%dT%H:%M:%SZ > "$(job_path "$key" paused)"
      echo paused
    elif [ "$n" -eq 1 ]; then
      echo first
    fi
  else
    rm -f "$f"
  fi
}

# jobs_kill_tree <pid> — TERM a process and every descendant (macOS has no timeout(1), and
# with_timeout only signals its direct child, which would orphan a `claude` grandchild).
jobs_kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do jobs_kill_tree "$c"; done
  kill -TERM "$1" 2>/dev/null || true
}
