#!/bin/bash
# confined-push.sh [--no-verify] [<branch>] — the only push a confined ticket run is allowed.
#
# A `Bash(git push -u origin:*)` rule is a prefix match, so it still admits any refspec and flag
# after it (`HEAD:main --force`, `--delete`). This pushes exactly one local branch to the SAME
# name on origin, only under agent.branch_prefix, never the base branch, never forced: a
# non-fast-forward is refused by git. Exit 2 = refused here; otherwise git's own exit code.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "confined-push: $*" >&2; exit 2; }

nv=() br=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-verify) nv=(--no-verify); shift ;;
    -*) die "unsupported option '$1'" ;;
    *) [ -z "$br" ] || die "one branch only"; br="$1"; shift ;;
  esac
done
if [ -z "$br" ]; then
  br="$(git symbolic-ref --quiet --short HEAD)" || die "detached HEAD; name the branch to push"
fi

prefix="$("${PLUGIN_ROOT}/scripts/ea-config.sh" dump 2>/dev/null | awk -F= '$1=="agent.branch_prefix" {print $2; exit}')"
prefix="${prefix:-engineer-agent}"
[[ "$br" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid branch name '${br}'"
case "$br" in "${prefix}/"?*) ;; *) die "'${br}' is not under agent.branch_prefix '${prefix}/'" ;; esac
base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
[ -z "$base" ] || [ "$br" != "$base" ] || die "refusing to push the base branch"
git show-ref --verify --quiet "refs/heads/${br}" || die "no local branch '${br}'"

exec git push ${nv[@]+"${nv[@]}"} -u origin "refs/heads/${br}:refs/heads/${br}"
