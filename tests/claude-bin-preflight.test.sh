#!/bin/bash
# Tests for the macOS TCC preflight in scripts/lib-paths.sh (resolve_real_path +
# claude_bin_changed).
#
# Background: macOS keys folder-access grants (Desktop / Documents / Downloads / network
# volumes) on the RESOLVED executable. `claude` auto-updates by writing a new
# ~/.local/share/claude/versions/<ver> file and repointing the ~/.local/bin/claude symlink, so
# every update produces a path with zero grants — observed directly in this machine's TCC
# database as one full set of grants per version (2.1.245 … 2.1.248) and none for the freshly
# installed 2.1.251. Interactively a human clicks Allow; the launchd poll has nobody to click.
#
# Each branch is a silent failure when wrong:
#   - a missed change means no warning, and the poll is denied folder access with nothing in the
#     receipt to explain it (the receipt reports `status: ok` on a run that read nothing).
#   - a spurious change means a low-priority push on EVERY fire, which trains the user to ignore
#     the topic they approve queue items on.
#   - reporting the FIRST observation would fire on every fresh install, where no grant could
#     have existed to go stale.
#
# Run: bash tests/claude-bin-preflight.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR/state"

# Stub `uname` so the Darwin gate is exercised on either platform. PATH shim, per the
# convention the other suites use for gh/claude/curl/security.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/uname" <<'STUB'
#!/bin/bash
echo "${FAKE_UNAME:-Darwin}"
STUB
chmod +x "$TMP/bin/uname"
export PATH="$TMP/bin:$PATH"

# shellcheck source=../scripts/lib-paths.sh
source "${REPO_ROOT}/scripts/lib-paths.sh"

RECORD="${EA_AGENT_DIR}/state/claude-bin.path"

# Mirror the real install layout: versions/<ver> real files, bin/claude a symlink to one.
mkdir -p "$TMP/versions" "$TMP/localbin"
: > "$TMP/versions/2.1.248"; chmod +x "$TMP/versions/2.1.248"
: > "$TMP/versions/2.1.251"; chmod +x "$TMP/versions/2.1.251"
ln -sf "$TMP/versions/2.1.248" "$TMP/localbin/claude"

echo "resolve_real_path"
eq "follows a symlink to its target" "$TMP/versions/2.1.248" "$(resolve_real_path "$TMP/localbin/claude")"
eq "leaves a real file alone" "$TMP/versions/2.1.251" "$(resolve_real_path "$TMP/versions/2.1.251")"
# A BARE command name must resolve through PATH, then follow symlinks like any other input.
# Returned verbatim instead, the record could never change and the preflight would silently
# never fire — install-cron.sh bakes in whatever CLAUDE_BIN held at install time, bare or not.
chmod +x "$TMP/localbin/claude"
eq "resolves a bare name via PATH, then follows it" "$TMP/versions/2.1.248" \
  "$(PATH="$TMP/localbin:$PATH" resolve_real_path claude)"
if PATH="$TMP/localbin:$PATH" resolve_real_path definitely-not-on-path >/dev/null 2>&1; then
  bad "a bare name not on PATH is rejected"
else
  ok "a bare name not on PATH is rejected"
fi

ln -sf "$TMP/localbin/claude" "$TMP/localbin/claude2"
eq "follows a multi-hop chain" "$TMP/versions/2.1.248" "$(resolve_real_path "$TMP/localbin/claude2")"
# A symlink loop must hit the hop bound and return, not spin forever — an unattended poll that
# hangs here never writes a receipt, which reads exactly like the outage this warning exists for.
# `timeout` is GNU-only, so bound it with a background job + kill instead.
ln -sf loop_b "$TMP/localbin/loop_a"; ln -sf loop_a "$TMP/localbin/loop_b"
bash -c "source '${REPO_ROOT}/scripts/lib-paths.sh'; resolve_real_path '$TMP/localbin/loop_a'" >/dev/null 2>&1 &
loop_pid=$!
loop_done=0
for _ in $(seq 1 50); do
  kill -0 "$loop_pid" 2>/dev/null || { loop_done=1; break; }
  sleep 0.1
done
if [ "$loop_done" -eq 1 ]; then
  ok "a symlink loop terminates instead of hanging"
else
  kill -9 "$loop_pid" 2>/dev/null
  bad "a symlink loop terminates instead of hanging (still running after 5s)"
fi
wait "$loop_pid" 2>/dev/null
if [ -z "$(resolve_real_path "" 2>/dev/null)" ]; then ok "empty input is rejected"; else bad "empty input is rejected"; fi

echo "claude_bin_changed"
# 1. First observation records but does NOT report — nothing could have been granted yet.
out="$(claude_bin_changed "$TMP/localbin/claude")"; rc=$?
eq "first observation does not report" "1" "$rc"
eq "first observation emits nothing" "" "$out"
eq "first observation records the RESOLVED target, not the symlink" \
   "$TMP/versions/2.1.248" "$(cat "$RECORD")"

# 2. Unchanged binary stays quiet, however many times it is polled.
out="$(claude_bin_changed "$TMP/localbin/claude")"; rc=$?
eq "unchanged binary does not report" "1" "$rc"
eq "unchanged binary emits nothing" "" "$out"

# 3. The auto-update: same symlink, new target. This is the case that must fire.
ln -sf "$TMP/versions/2.1.251" "$TMP/localbin/claude"
out="$(claude_bin_changed "$TMP/localbin/claude")"; rc=$?
eq "a new version behind the same symlink reports" "0" "$rc"
eq "it echoes the new resolved path" "$TMP/versions/2.1.251" "$out"
eq "it records the new path" "$TMP/versions/2.1.251" "$(cat "$RECORD")"

# 4. Warn ONCE per new binary, not on every fire — the record updates as it reports.
out="$(claude_bin_changed "$TMP/localbin/claude")"; rc=$?
eq "the same change does not report twice" "1" "$rc"

# 5. Non-Darwin has no TCC grants to go stale.
rm -f "$RECORD"
FAKE_UNAME=Linux claude_bin_changed "$TMP/localbin/claude" >/dev/null 2>&1
eq "non-Darwin does not report" "1" "$?"
if [ ! -f "$RECORD" ]; then ok "non-Darwin writes no record"; else bad "non-Darwin writes no record"; fi

# 6. A missing binary must not fail the poll or poison the record.
rm -f "$RECORD"
out="$(claude_bin_changed "$TMP/does-not-exist")"; rc=$?
eq "a nonexistent binary reports nothing on first sight" "1" "$rc"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
