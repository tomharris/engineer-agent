#!/bin/bash
# Run every test suite. There was no runner before this — each tests/*.test.sh was run by hand,
# and there is no CI, so "did anything break?" had no single answer.
#
# Each suite is self-isolating (its own mktemp -d + EA_AGENT_DIR), so they run in parallel and
# never touch the real ~/.local/share/engineer-agent. Largest suites start first (a proxy for the
# slowest), so the run takes about as long as the longest suite. Each suite's output is printed
# whole when it finishes.
#
# Run: bash tests/run-all.sh [-j N] [name-fragment]  (default N = half the cores; EA_TEST_JOBS=N works
# too; -j 1 is serial)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2

# Half the cores: the suites are fork-heavy, and a full-width run measured slower than half-width.
JOBS="${EA_TEST_JOBS:-$(( $(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8) / 2 ))}"
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1
if [ "${1:-}" = "-j" ]; then JOBS="$2"; shift 2; fi
FILTER="${1:-}"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
TOTAL=0; FAILED=0; FAILED_NAMES=""

SUITES=()
while IFS= read -r s; do
  [ -n "$FILTER" ] && case "$s" in *"$FILTER"*) ;; *) continue ;; esac
  SUITES+=("$s")
done < <(wc -l *.test.sh | awk '$2 != "total" {print $1, $2}' | sort -rn | awk '{print $2}')

report() {  # report <suite> — print a finished suite's output and tally it
  printf '\n\033[1m== %s ==\033[0m\n' "$1"
  cat "$OUT/$1.log"
  if [ "$(cat "$OUT/$1.rc")" = 0 ]; then
    printf '\033[32mPASS\033[0m %s\n' "$1"
  else
    printf '\033[31mFAIL\033[0m %s\n' "$1"
    FAILED=$((FAILED+1)); FAILED_NAMES="${FAILED_NAMES} $1"
  fi
}

running=() reported=""
reap() {  # reap — report every suite whose rc file has appeared; keep the rest in `running`
  local s still=()
  for s in ${running[@]+"${running[@]}"}; do
    if [ -e "$OUT/$s.rc" ]; then report "$s"; else still+=("$s"); fi
  done
  running=(${still[@]+"${still[@]}"})
}

for suite in ${SUITES[@]+"${SUITES[@]}"}; do
  TOTAL=$((TOTAL+1))
  while [ "${#running[@]}" -ge "$JOBS" ]; do reap; [ "${#running[@]}" -ge "$JOBS" ] && sleep 0.2; done
  ( bash "$suite" > "$OUT/$suite.log" 2>&1; echo $? > "$OUT/$suite.rc.tmp"; mv "$OUT/$suite.rc.tmp" "$OUT/$suite.rc" ) </dev/null &
  running+=("$suite")
done
while [ "${#running[@]}" -gt 0 ]; do reap; [ "${#running[@]}" -gt 0 ] && sleep 0.2; done
wait

printf '\n\033[1m=== %d suite(s), %d failed ===\033[0m\n' "$TOTAL" "$FAILED"
[ "$FAILED" -eq 0 ] || { printf 'failed:%s\n' "$FAILED_NAMES"; exit 1; }
