#!/bin/bash
# migrate-poll-to-jobs.sh — replace the global poll with per-project `watch` jobs.
#
# For each project, appends a watch job for every configured source that has none
# (jobs-default-watch.sh), at the old poll's cadence: launchd StartInterval or crontab */N; for a
# StartCalendarInterval (EA_POLL_HOURS) poll, hourly with `hours:` when the hours are contiguous.
# Drops `exclusive:` (it only hid a source from the global poll). Seeds each new job's state file
# from last-poll.yaml so its first run does not re-discover the backlog, then removes the poll's
# launchd agent / crontab entry; leaving it would poll every source twice and, without
# `exclusive:`, poll sources a cr-qa job had kept it off.
#
# Dry run by default: prints the engineer.yaml diff and what would be seeded and removed.
# --apply writes engineer.yaml (backup engineer.yaml.bak-<epoch>) and the state files and removes
# the poll. It refuses while the jobs dispatcher (install-jobs.sh) is not installed. Idempotent.
#
# Usage: migrate-poll-to-jobs.sh [--apply] [--every <dur>]
# Exit:  0 ok; 1 refused (no dispatcher, or the rewritten config does not read back); 2 usage or
#        a config this script cannot edit.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
# shellcheck source=lib-jobs.sh
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"
# shellcheck source=lib-yaml.sh
. "${PLUGIN_ROOT}/scripts/lib-yaml.sh"
# shellcheck source=lib-state.sh
. "${PLUGIN_ROOT}/scripts/lib-state.sh"

die() { echo "migrate-poll-to-jobs: $*" >&2; exit 2; }

APPLY=0; EVERY_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --every) EVERY_ARG="${2:-}"; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -z "$EVERY_ARG" ] || [ -n "$(jobs_duration_seconds "$EVERY_ARG")" ] \
  || die "--every '${EVERY_ARG}' must look like 30s, 5m, 2h or 1d"
CFG="$EA_CONFIG_FILE"
[ -f "$CFG" ] || die "no engineer.yaml at ${CFG}; run /engineer-agent setup"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
LAST_POLL="${EA_AGENT_DIR}/state/last-poll.yaml"
POLL_PLIST="${HOME}/Library/LaunchAgents/engineer-agent-poll.plist"
JOBS_PLIST="${HOME}/Library/LaunchAgents/engineer-agent-jobs.plist"
POLL_RE='engineer-agent.*cron-poll.sh'

# --- the old poll's schedule ------------------------------------------------------------------
secs_to_dur() {
  if [ $(($1 % 3600)) -eq 0 ]; then echo "$(($1 / 3600))h"
  elif [ $(($1 % 60)) -eq 0 ]; then echo "$(($1 / 60))m"
  else echo "${1}s"; fi
}
POLL_EVERY=15m; POLL_HOURS=""; POLL_NOTE=""; POLL_DESC="none installed"
POLL_CRON="$(crontab -l 2>/dev/null | grep "$POLL_RE" | head -1)"
if [ -f "$POLL_PLIST" ]; then
  hours="$(grep -o '<key>Hour</key>[[:space:]]*<integer>[0-9]*' "$POLL_PLIST" | sed 's/.*<integer>//' \
           | sort -n -u | paste -sd, -)"
  interval="$(awk '/<key>StartInterval<\/key>/ { getline; gsub(/[^0-9]/, ""); print; exit }' "$POLL_PLIST")"
  if [ -n "$hours" ]; then
    POLL_EVERY=1h
    first="${hours%%,*}"; last="${hours##*,}"; n="$(printf '%s\n' "$hours" | tr ',' '\n' | grep -c .)"
    if [ $((last - first + 1)) -eq "$n" ]; then
      POLL_HOURS="${first}-$((last + 1))"; POLL_DESC="launchd, hours ${POLL_HOURS}"
    else
      POLL_DESC="launchd, hours ${hours}"
      POLL_NOTE="hours ${hours} are not a contiguous range; no hours: window set"
    fi
  elif [ -n "$interval" ] && [ "$interval" -gt 0 ]; then
    POLL_EVERY="$(secs_to_dur "$interval")"; POLL_DESC="launchd, every ${POLL_EVERY}"
  else
    POLL_DESC="launchd, schedule unreadable"; POLL_NOTE="could not read the plist schedule; using 15m"
  fi
elif [ -n "$POLL_CRON" ]; then
  m="${POLL_CRON%% *}"
  case "$m" in
    "*") POLL_EVERY=1m ;;
    "*/"*) [[ "${m#*/}" =~ ^[0-9]+$ ]] && POLL_EVERY="$((10#${m#*/}))m" \
             || POLL_NOTE="crontab minute field '${m}' is not */N; using 15m" ;;
    *) POLL_NOTE="crontab minute field '${m}' is not */N; using 15m" ;;
  esac
  POLL_DESC="crontab, every ${POLL_EVERY}"
fi
EVERY="${EVERY_ARG:-$POLL_EVERY}"
POLL_INSTALLED=0; { [ -f "$POLL_PLIST" ] || [ -n "$POLL_CRON" ]; } && POLL_INSTALLED=1

dispatcher_installed() {
  [ -f "$JOBS_PLIST" ] || crontab -l 2>/dev/null | grep -q 'engineer-agent.*jobs-tick.sh'
}

# --- the rewritten config ---------------------------------------------------------------------
# insert_jobs <file> <slug> <entries> — print <file> with <entries> (6-space-indented list items
# from jobs-default-watch.sh) appended to projects.<slug>.jobs, re-indented to the list's own item
# indent, creating `jobs:` when absent. Exit 3: flow-style jobs; 4: project not found.
insert_jobs() {
  awk -v slug="$2" -v entries="$3" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    function emit(n,   arr, c, k, pad, l) {
      c = split(entries, arr, "\n"); pad = ""
      for (k = 0; k < n; k++) pad = pad " "
      for (k = 1; k <= c; k++) { l = arr[k]; sub(/^      /, "", l); print pad l }
    }
    function flush(   k) { for (k = 1; k <= nb; k++) print buf[k]; nb = 0 }
    st == 0 {
      if ($0 ~ /^[^[:space:]#]/) inp = ($0 ~ /^projects:[[:space:]]*(#.*)?$/)
      if (inp && $0 ~ ("^  " slug ":[[:space:]]*(#.*)?$")) st = 1
      print; next
    }
    st == 3 { print; next }
    /^[[:space:]]*(#.*)?$/ { buf[++nb] = $0; next }
    st == 1 {
      if (ind($0) <= 2) { print "    jobs:"; emit(6); flush(); print; st = 3; next }
      flush()
      if ($0 ~ /^    jobs:/) {
        rest = $0; sub(/^    jobs:[[:space:]]*/, "", rest)
        if (rest ~ /^\[[[:space:]]*\][[:space:]]*(#.*)?$/) { print "    jobs:"; emit(6); st = 3; next }
        if (rest !~ /^(#.*)?$/) { bad = 3; exit }
        print; st = 2; item = -1; next
      }
      print; next
    }
    st == 2 {
      if (item < 0) {
        if ($0 ~ /^ *- / && ind($0) >= 4) { item = ind($0); flush(); print; next }
        emit(6); flush(); print; st = 3; next
      }
      if (ind($0) > item || (ind($0) == item && $0 ~ /^ *- /)) { flush(); print; next }
      emit(item); flush(); print; st = 3; next
    }
    END {
      if (bad) exit bad
      if (st == 0) exit 4
      if (st == 1) { print "    jobs:"; emit(6) }
      else if (st == 2) emit(item < 0 ? 6 : item)
      flush()
    }' "$1"
}

jobs_cfg_load
OLD_JOBS="$(jobs_enumerate | awk -F'|' '{print $1 "|" $3 "|" $4}')"
NEW="$TMPD/engineer.yaml"; cp "$CFG" "$NEW"
NEW_JOBS=""   # slug|id|integration
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  entries="$(bash "${PLUGIN_ROOT}/scripts/jobs-default-watch.sh" "$slug" --every "$EVERY" \
             ${POLL_HOURS:+--hours "$POLL_HOURS"})" || exit 2
  [ -n "$entries" ] || continue
  insert_jobs "$NEW" "$slug" "$entries" > "$NEW.tmp"
  case $? in
    0) mv "$NEW.tmp" "$NEW" ;;
    3) die "project '${slug}': jobs is a flow-style list; rewrite it as a block list and re-run" ;;
    *) die "project '${slug}': could not find its block under projects: in engineer.yaml" ;;
  esac
  NEW_JOBS="${NEW_JOBS}$(printf '%s\n' "$entries" \
    | awk -v s="$slug" '/^      - id: / {id=$3} /^        integration: / {print s "|" id "|" $2}')
"
done < <(printf '%s\n' "$EA_JOBS_CFG" | sed -n 's/^project\[\]=//p')

awk '/^[^[:space:]#]/ { inp = ($0 ~ /^projects:/) }
     inp && /^      [[:space:]]*exclusive:/ { next }
     { print }' "$NEW" > "$NEW.tmp" && mv "$NEW.tmp" "$NEW"

# The candidate must read back as exactly the old jobs plus the new ones, none exclusive.
if ! cmp -s "$CFG" "$NEW"; then
  mkdir -p "$TMPD/verify/state"; cp "$NEW" "$TMPD/verify/engineer.yaml"
  got="$(EA_JOBS_CFG="$(EA_AGENT_DIR="$TMPD/verify" "${PLUGIN_ROOT}/scripts/ea-config.sh" dump 2>/dev/null)" \
         jobs_enumerate | awk -F'|' '{print $1 "|" $3 "|" $4 "|" $10}' | LC_ALL=C sort)"
  want="$(printf '%s\n%s\n' "$OLD_JOBS" "$NEW_JOBS" | grep . | sed 's/$/|/' | LC_ALL=C sort)"
  if [ "$got" != "$want" ]; then
    echo "migrate-poll-to-jobs: the rewritten engineer.yaml does not read back as expected; nothing written" >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2
    exit 1
  fi
fi

# --- state seeding ----------------------------------------------------------------------------
# seed_lines <slug> <integration> — the last-poll.yaml keys (flat, pipe paths) that job owns.
LAST_FLAT=""
[ -f "$LAST_POLL" ] && { state_load "$LAST_POLL"; LAST_FLAT="$EA_STATE"; }
seed_lines() {
  local slug="$1" integ="$2" src="$1" prefixes owner r i
  src="$integ"; [ "$integ" = github-issues ] && src=github_issues
  prefixes="projects|${slug}|${src}|"
  case "$integ" in
    github-issues)
      owner="$(_jcfg "projects.${slug}.github.owner")"
      for r in $(printf '%s\n' "$EA_JOBS_CFG" | sed -n "s/^projects\.${slug}\.github\.repos\[\]=//p"); do
        prefixes="${prefixes}
github_repos|${owner}/${r}|"
      done ;;
    jira)
      for i in $(printf '%s\n' "$EA_JOBS_CFG" | sed -n "s/^projects\.${slug}\.jira\.source\.[0-9]*\.project=//p"); do
        prefixes="${prefixes}
jira_projects|${i}|"
      done ;;
  esac
  printf '%s\n' "$LAST_FLAT" | awk -v ps="$prefixes" '
    BEGIN { n = split(ps, p, "\n") }
    { for (k = 1; k <= n; k++) if (index($0, p[k]) == 1) { print; next } }'
}

# --- report / apply ---------------------------------------------------------------------------
echo "Global poll: ${POLL_DESC}"
[ -n "$POLL_NOTE" ] && echo "  note: ${POLL_NOTE}"

if cmp -s "$CFG" "$NEW" && [ "$POLL_INSTALLED" -eq 0 ]; then
  echo "Nothing to migrate."
  exit 0
fi

if [ "$APPLY" -eq 1 ] && ! dispatcher_installed; then
  echo "migrate-poll-to-jobs: the jobs dispatcher is not installed; run scripts/install-jobs.sh first" >&2
  exit 1
fi

if ! cmp -s "$CFG" "$NEW"; then
  if [ "$APPLY" -eq 1 ]; then
    bak="${CFG}.bak-$(jobs_now)"
    cp -p "$CFG" "$bak"
    cat "$NEW" > "$CFG"
    echo "engineer.yaml updated (backup: ${bak})"
  else
    diff -u -L engineer.yaml -L "engineer.yaml (migrated)" "$CFG" "$NEW"
  fi
fi

verb_seed="would seed"; verb_keep="would keep"; [ "$APPLY" -eq 1 ] && { verb_seed=seeded; verb_keep=kept; }
while IFS='|' read -r slug id integ; do
  [ -n "$slug" ] || continue
  rel="state/jobs/$(job_key "$slug" "$id").state.yaml"; f="${EA_AGENT_DIR}/${rel}"
  if [ -e "$f" ]; then echo "${verb_keep} existing ${rel}"; continue; fi
  lines="$(seed_lines "$slug" "$integ")"
  if [ -z "$lines" ]; then echo "nothing to seed for ${rel}; its first run starts without cutoffs"; continue; fi
  echo "${verb_seed} ${rel} ($(printf '%s\n' "$lines" | grep -c .) keys from last-poll.yaml)"
  [ "$APPLY" -eq 1 ] && { EA_STATE="$lines"; state_save "$f"; }
done <<< "$NEW_JOBS"

if [ "$POLL_INSTALLED" -eq 1 ]; then
  if [ "$APPLY" -eq 1 ]; then
    if [ -f "$POLL_PLIST" ]; then
      command -v launchctl >/dev/null 2>&1 \
        && launchctl bootout "gui/$(id -u)/engineer-agent-poll" >/dev/null 2>&1
      rm -f "$POLL_PLIST"; echo "removed the global poll (launchd agent)"
    fi
    if [ -n "$POLL_CRON" ]; then
      kept="$(crontab -l 2>/dev/null | grep -v "$POLL_RE")"
      { [ -z "$kept" ] || printf '%s\n' "$kept"; } | crontab -
      echo "removed the global poll (crontab entry)"
    fi
  else
    [ -f "$POLL_PLIST" ] && echo "would remove the global poll (launchd agent)"
    [ -n "$POLL_CRON" ] && echo "would remove the global poll (crontab entry)"
  fi
fi

if [ "$APPLY" -eq 0 ]; then
  dispatcher_installed || echo "note: the jobs dispatcher is not installed; run scripts/install-jobs.sh before --apply"
  echo "Dry run. Re-run with --apply to write engineer.yaml (backup first) and the state files, and remove the global poll."
fi
exit 0
