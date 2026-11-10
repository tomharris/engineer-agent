#!/bin/bash
# jobs-ctl.sh — inspect and control scheduled jobs (backs /engineer-agent jobs and status).
#
# Usage:
#   jobs-ctl.sh list               one line per job: key, schedule, state, last receipt, next due
#   jobs-ctl.sh run <key>          run a job now in the foreground (ignores every/hours/days;
#                                  honors validation, pause and lock)
#   jobs-ctl.sh pause <key>        stop a job running until resumed
#   jobs-ctl.sh resume <key>       clear a pause (manual or circuit-breaker) and its failure streak
#   jobs-ctl.sh preview <key>      implement-next only: fetch each rule's tickets and show which
#                                  one would be picked and why each other one was skipped (read-only;
#                                  ignores the job's guards)
# <key> is <project>.<id>.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
# shellcheck source=lib-jobs.sh
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"

die() { echo "jobs-ctl: $*" >&2; exit 2; }

known_key() {
  jobs_enumerate | awk -F'|' -v k="$1" '($1 "." $3) == k { f = 1 } END { exit !f }'
}

fmt_epoch() { [ -n "$1" ] && _jobs_local "$1" '%Y-%m-%d %H:%M' || printf -- '-'; }

cmd_list() {
  local rows slug idx id integ action every hours days watch excl sup budget pause key state next last rstat
  rows="$(jobs_enumerate)"
  [ -n "$rows" ] || { echo "No scheduled jobs configured."; return 0; }
  printf '%-32s %-16s %-6s %-12s %-26s %s\n' JOB KIND EVERY STATE "LAST RUN" "NEXT DUE"
  while IFS='|' read -r slug idx id integ action every hours days watch excl sup budget pause; do
    [ -n "$slug" ] || continue
    key="$(job_key "$slug" "$id")"
    row="${slug}|${idx}|${id}|${integ}|${action}|${every}|${hours}|${days}|${watch}|${excl}|${sup}|${budget}|${pause}"
    if reason="$(jobs_validate "$row" "$rows")"; then
      if job_is_paused "$key"; then state=paused
      elif [ -f "$(job_path "$key" lock)" ] && kill -0 "$(cat "$(job_path "$key" lock)")" 2>/dev/null; then state=running
      else state=idle; fi
    else
      state=invalid
    fi
    last="$(job_last_run "$key")"
    rstat="$(job_receipt_field "$key" status)"
    if [ "$state" = idle ] || [ "$state" = running ]; then
      next="$(fmt_epoch "$(( ${last:-$(jobs_now)} + $(jobs_duration_seconds "$every") ))")"
      [ -n "$last" ] || next="next tick"
      [ -z "$hours$days" ] || next="${next} (window ${hours:-any}h ${days:-any day})"
    else
      next="-"
    fi
    printf '%-32s %-16s %-6s %-12s %-26s %s\n' "$key" "${integ}:${action}" "$every" "$state" \
      "$(fmt_epoch "$last")${rstat:+ ($rstat)}" "$next"
    [ "$state" = invalid ] && printf '    invalid: %s\n' "$reason"
    if [ -n "$rstat" ] && [ "$rstat" != ok ]; then
      printf '    last error: %s\n' "$(awk '/^errors:/ {f=1; next} f && /^  - / {sub(/^  - "?/, ""); sub(/"$/, ""); print; exit}' "$(job_path "$key" receipt)")"
    fi
  done <<< "$rows"
}

cmd_preview() {
  local key="$1" row slug idx integ action reason rc out
  row="$(jobs_enumerate | awk -F'|' -v k="$key" '($1 "." $3) == k { print; exit }')"
  [ -n "$row" ] || die "no such job: $key"
  IFS='|' read -r slug idx _ integ action _ <<< "$row"
  # shellcheck source=lib-time.sh
  . "${PLUGIN_ROOT}/scripts/lib-time.sh"
  # shellcheck source=lib-queue.sh
  . "${PLUGIN_ROOT}/scripts/lib-queue.sh"
  # shellcheck source=lib-ticket-kind.sh
  . "${PLUGIN_ROOT}/scripts/lib-ticket-kind.sh"
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  case "${integ}:${action}" in
    jira:implement-next)
      reason="$(ar_validate "$slug" "$idx")" || die "$key rules are invalid: $reason"
      # shellcheck source=lib-secret.sh
      . "${PLUGIN_ROOT}/scripts/lib-secret.sh"
      # shellcheck source=lib-jira-api.sh
      . "${PLUGIN_ROOT}/scripts/lib-jira-api.sh"
      ar_jira_init || die "$AR_ERR"
      _arcl "projects.${slug}.investigation.jira_types" > "$TMPD/jira_types"
      export AR_JIRA_TYPES_FILE="$TMPD/jira_types"
      out="$(AR_TRACE=1 AR_EVAL_ALL=1 ar_select "$slug" "$idx" 2>&1 >"$TMPD/pick")"; rc=$? ;;
    github-issues:implement-next)
      reason="$(gr_validate "$slug" "$idx")" || die "$key rules are invalid: $reason"
      gr_init || die "$GR_ERR"
      out="$(AR_TRACE=1 AR_EVAL_ALL=1 gr_select "$slug" "$idx" 2>&1 >"$TMPD/pick")"; rc=$? ;;
    *) die "preview applies to implement-next jobs only" ;;
  esac
  printf '%s\n' "$out"
  case "$rc" in
    0) printf 'would pick: %s (rule %s)\n' "$(cut -f2 "$TMPD/pick")" "$(cut -f1 "$TMPD/pick")" ;;
    1) echo "would pick: nothing eligible" ;;
    *) die "$(cat "$TMPD/pick")" ;;
  esac
}

case "${1:-}" in
  list) cmd_list ;;
  preview)
    [ -n "${2:-}" ] || die "usage: jobs-ctl.sh preview <project>.<id>"
    cmd_preview "$2"
    ;;
  run)
    [ -n "${2:-}" ] || die "usage: jobs-ctl.sh run <project>.<id>"
    known_key "$2" || die "no such job: $2"
    job_is_paused "$2" && die "$2 is paused; resume it first"
    before="$(job_receipt_field "$2" run_id)"
    bash "${PLUGIN_ROOT}/scripts/jobs-tick.sh" --only "$2" --force --foreground
    if [ -f "$(job_path "$2" invalid)" ]; then die "$2 is invalid: $(cat "$(job_path "$2" invalid)")"; fi
    [ "$(job_receipt_field "$2" run_id)" != "$before" ] || die "$2 did not run (another run in progress?)"
    cat "$(job_path "$2" receipt)"
    ;;
  pause)
    [ -n "${2:-}" ] || die "usage: jobs-ctl.sh pause <project>.<id>"
    known_key "$2" || die "no such job: $2"
    mkdir -p "$JOBS_STATE_DIR"
    echo "manual $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(job_path "$2" paused)"
    echo "paused $2"
    ;;
  resume)
    [ -n "${2:-}" ] || die "usage: jobs-ctl.sh resume <project>.<id>"
    known_key "$2" || die "no such job: $2"
    rm -f "$(job_path "$2" paused)" "$(job_path "$2" failures)"
    echo "resumed $2"
    ;;
  ""|-h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1'" ;;
esac
