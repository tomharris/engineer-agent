#!/bin/bash
# Run every test suite. There was no runner before this — each tests/*.test.sh was run by hand,
# and there is no CI, so "did anything break?" had no single answer.
#
# Each suite is self-isolating (its own mktemp -d + EA_AGENT_DIR), so they can run in any order and
# never touch the real ~/.local/share/engineer-agent.
#
# Run: bash tests/run-all.sh [name-fragment]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2

FILTER="${1:-}"
TOTAL=0; FAILED=0; FAILED_NAMES=""

for suite in *.test.sh; do
  [ -e "$suite" ] || continue
  [ -n "$FILTER" ] && case "$suite" in *"$FILTER"*) ;; *) continue ;; esac
  TOTAL=$((TOTAL+1))
  printf '\n\033[1m== %s ==\033[0m\n' "$suite"
  if bash "$suite"; then
    printf '\033[32mPASS\033[0m %s\n' "$suite"
  else
    printf '\033[31mFAIL\033[0m %s\n' "$suite"
    FAILED=$((FAILED+1)); FAILED_NAMES="${FAILED_NAMES} ${suite}"
  fi
done

printf '\n\033[1m=== %d suite(s), %d failed ===\033[0m\n' "$TOTAL" "$FAILED"
[ "$FAILED" -eq 0 ] || { printf 'failed:%s\n' "$FAILED_NAMES"; exit 1; }
