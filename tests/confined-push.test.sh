#!/bin/bash
# Tests for scripts/confined-push.sh — the only push a confined ticket run may make.
# Uses real git against a local bare "origin".
#
# Run: bash tests/confined-push.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/confined-push.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"; mkdir -p "$EA_AGENT_DIR"
printf 'agent:\n  branch_prefix: "ea"\n' > "$EA_AGENT_DIR/engineer.yaml"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
G() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

G init --bare "$TMP/origin.git"
G clone "$TMP/origin.git" "$TMP/w"
cd "$TMP/w" || exit 1
echo a > f; G add f; G commit -m init; G push -u origin main
G remote set-head origin main

remote_sha() { git --git-dir="$TMP/origin.git" rev-parse --verify --quiet "refs/heads/$1"; }
push() { bash "$PUSH" "$@" >/dev/null 2>"$TMP/err"; }

echo "== allowed"
G checkout -b ea/BILL-1; echo b > f; G commit -am b
push; eq "pushes the current prefixed branch" "0|$(git rev-parse HEAD)" "$?|$(remote_sha ea/BILL-1)"
eq "sets upstream" "origin/ea/BILL-1" "$(git rev-parse --abbrev-ref '@{u}')"
G checkout -b ea/BILL-2; echo c > f; G commit -am c; G checkout main
push ea/BILL-2; eq "pushes a named local prefixed branch" "0|$(git rev-parse ea/BILL-2)" "$?|$(remote_sha ea/BILL-2)"
G checkout ea/BILL-1; echo d > f; G commit -am d
push --no-verify; eq "--no-verify passes through" "0|$(git rev-parse HEAD)" "$?|$(remote_sha ea/BILL-1)"

echo "== refused"
main_before="$(remote_sha main)"
G checkout main; echo e > f; G commit -am e
push; eq "the base branch is refused" "2" "$?"
push main; eq "the base branch by name is refused" "2" "$?"
eq "origin main untouched" "$main_before" "$(remote_sha main)"
G checkout -b develop
push; eq "a branch outside agent.branch_prefix is refused" "2" "$?"
eq "nothing pushed for it" "" "$(remote_sha develop)"
for a in "HEAD:main" "ea/BILL-1:main" "--force" "--delete" "-f" "--receive-pack=sh" "ea/../main"; do
  push "$a"; eq "argument '$a' refused" "2" "$?"
done
push ea/BILL-1 ea/BILL-2; eq "two branches refused" "2" "$?"
for a in "--force" "--delete" "--force-with-lease"; do
  push "$a" ea/BILL-1; eq "option '$a' refused before a valid branch" "2|unsupported option" "$?|$(grep -o 'unsupported option' "$TMP/err")"
done
G remote set-head origin ea/BILL-2
push ea/BILL-2; eq "a base branch under the prefix is refused" "2|refusing to push the base branch" "$?|$(grep -o 'refusing to push the base branch' "$TMP/err")"
G remote set-head origin main
G branch 'ea/a@b' ea/BILL-1
push 'ea/a@b'; eq "a branch name outside the safe charset is refused" "2|invalid branch name|" "$?|$(grep -o 'invalid branch name' "$TMP/err")|$(remote_sha 'ea/a@b')"
push ea/nope; eq "a branch that does not exist locally is refused" "2" "$?"
G checkout --detach; push; eq "detached HEAD without a name is refused" "2|detached HEAD" "$?|$(grep -o 'detached HEAD' "$TMP/err")"

echo "== history is never rewritten"
G checkout ea/BILL-1; G reset --hard HEAD~1; echo z > f; G commit -am rewrite
before="$(remote_sha ea/BILL-1)"
push; rc=$?
eq "a non-fast-forward push fails (no force)" "1|$before" "$( [ "$rc" -ne 0 ] && echo 1)|$(remote_sha ea/BILL-1)"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
