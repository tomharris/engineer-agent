#!/bin/bash
# Tests for with_timeout (scripts/lib-paths.sh).
# Run: bash tests/with-timeout.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }
le()  { if [ "$3" -le "$2" ]; then ok "$1"; else bad "$1 — want <= $2 got $3"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
. "$REPO_ROOT/scripts/lib-paths.sh"

alive() { kill -0 "$1" 2>/dev/null && echo alive || echo dead; }

# spawner <pidfile> [ignore-term] — a wrapper whose child outlives a TERM to the wrapper alone.
cat > "$TMP/spawner.sh" <<'EOF'
#!/bin/bash
[ "${2:-}" = ignore ] && trap '' TERM
sleep 30 & echo $! > "$1"
wait
EOF
chmod +x "$TMP/spawner.sh"

echo "== exit status"
with_timeout 5 sh -c 'exit 3'; eq "returns the command's status" 3 "$?"

echo "== a quick command does not wait out the timeout"
s=$SECONDS; with_timeout 30 true; le "returns immediately" 1 $((SECONDS - s))

echo "== a timed-out command's descendants are killed"
s=$SECONDS; with_timeout 1 "$TMP/spawner.sh" "$TMP/g1" 2>/dev/null; rc=$?
eq "returns 124" 124 "$rc"
eq "grandchild is dead" dead "$(alive "$(cat "$TMP/g1")")"
le "returns within the TERM grace" 3 $((SECONDS - s))

echo "== a captured timed-out command returns at the timeout"
s=$SECONDS; out="$(with_timeout 1 "$TMP/spawner.sh" "$TMP/g2" 2>/dev/null)"
le "command substitution is not held open by the grandchild" 3 $((SECONDS - s))
eq "grandchild is dead" dead "$(alive "$(cat "$TMP/g2")")"

echo "== a TERM-ignoring tree is KILLed after the grace"
with_timeout 1 "$TMP/spawner.sh" "$TMP/g3" ignore 2>/dev/null; rc=$?
eq "returns 124" 124 "$rc"
eq "grandchild is dead" dead "$(alive "$(cat "$TMP/g3")")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
