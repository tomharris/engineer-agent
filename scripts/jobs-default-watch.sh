#!/bin/bash
# jobs-default-watch.sh — print default `watch` job entries for one project: one per configured
# source that has no watch job yet. YAML list items indented for `projects.<slug>.jobs:`, ready to
# append. Prints nothing when every configured source is already watched. Read-only.
#
# Usage: jobs-default-watch.sh <project> [--every <dur>]   (default 15m)
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
# shellcheck source=lib-jobs.sh
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"

die() { echo "jobs-default-watch: $*" >&2; exit 2; }

SLUG="${1:-}"; [ -n "$SLUG" ] || die "usage: jobs-default-watch.sh <project> [--every <dur>]"
shift
EVERY=15m
while [ $# -gt 0 ]; do
  case "$1" in
    --every) EVERY="${2:-}"; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -n "$(jobs_duration_seconds "$EVERY")" ] || die "--every '${EVERY}' must look like 30s, 5m, 2h or 1d"

jobs_cfg_load
printf '%s\n' "$EA_JOBS_CFG" | grep -Fqx "project[]=${SLUG}" || die "no project '${SLUG}' in engineer.yaml"

# Existing jobs of this project: "<id>|<integration>|<action>" per line.
EXISTING="$(jobs_enumerate | awk -F'|' -v s="$SLUG" '$1==s {print $3 "|" $4 "|" $5}')"
NEW_IDS=""

id_taken() {
  printf '%s\n' "$EXISTING" | awk -F'|' -v i="$1" '$1==i {f=1} END {exit !f}' && return 0
  case " $NEW_IDS " in *" $1 "*) return 0 ;; esac
  return 1
}

for src in github github_issues jira slack slite; do
  case "$(_jcfg "projects.${SLUG}.source.${src}")" in
    configured|"skipped:owned by scheduled job "*) ;;
    *) continue ;;
  esac
  integ="$src"; [ "$src" = github_issues ] && integ=github-issues
  printf '%s\n' "$EXISTING" | awk -F'|' -v g="$integ" '$2==g && $3=="watch" {f=1} END {exit !f}' && continue
  id="${integ}-watch"; n=2
  while id_taken "$id"; do id="${integ}-watch-${n}"; n=$((n+1)); done
  NEW_IDS="${NEW_IDS} ${id}"
  printf '      - id: %s\n        integration: %s\n        action: watch\n        every: %s\n' "$id" "$integ" "$EVERY"
  [ "$integ" = slack ] && printf '        watch: [channels]\n'
done
exit 0
