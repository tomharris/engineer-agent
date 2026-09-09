#!/bin/bash
# Regression test for the ntfy subscribe stream going silently dead.
#
# The failure this pins: a TCP connection that dies WITHOUT a FIN (dropped NAT
# mapping, sleeping laptop, silent middlebox) leaves curl blocked in read()
# forever. The reconnect loop never runs, so every Approve/Reject tap after that
# moment is lost — permanently, and with nothing in the log to say so. Observed
# in the wild: one curl alive 5h with zero bytes while pushes kept going out.
#
# The test drives the real script against a server that sends HTTP headers and
# then goes permanently silent, and asserts the listener gives up and reconnects.
# Run: bash tests/listener-stream-stall.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="${SCRIPT_DIR}/../scripts/approval-listener.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

command -v nc >/dev/null 2>&1 || { echo "SKIP: nc not available"; exit 0; }

TMP="$(mktemp -d)"
PORT=45673
NC_PID=""
LISTENER_PID=""

cleanup() {
  [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null
  # The stream curl is a grandchild via process substitution; sweep by URL.
  pkill -f "127.0.0.1:${PORT}/cmd-topic" 2>/dev/null
  [ -n "$NC_PID" ] && kill "$NC_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR/queue/drafts" "$EA_AGENT_DIR/state"

# Point the listener at a local socket that answers and then says nothing.
export EA_NTFY_SERVER="http://127.0.0.1:${PORT}"
export EA_NTFY_TOPIC="ack-topic"
export EA_NTFY_COMMAND_TOPIC="cmd-topic"
export EA_NTFY_AUTH_TOKEN=""

# Short stall window so the test is fast; the production default is much larger.
export EA_NTFY_STALL_TIMEOUT=3

# Neutralize the outbound legs so nothing touches the network or spends money.
export NOTIFY_BIN="$TMP/fake-notify"
printf '#!/bin/bash\nexit 0\n' > "$NOTIFY_BIN"
chmod +x "$NOTIFY_BIN"
export CLAUDE_BIN="$TMP/fake-claude"
printf '#!/bin/bash\nexit 0\n' > "$CLAUDE_BIN"
chmod +x "$CLAUDE_BIN"

echo "listener stall detection"

# Serve headers, then stay silent well past the stall window.
( printf 'HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n\r\n'; sleep 60 ) \
  | nc -l "$PORT" >/dev/null 2>&1 &
NC_PID=$!
sleep 1

bash "$LISTENER" >/dev/null 2>&1 &
LISTENER_PID=$!

LOG="$EA_AGENT_DIR/state/approval-listener.log"
# Generous bound: the stall window plus startup and scheduling slack.
deadline=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if grep -q 'stream closed' "$LOG" 2>/dev/null; then break; fi
  sleep 1
done

if grep -q 'stream closed' "$LOG" 2>/dev/null; then
  ok "a silent stream is abandoned and the reconnect loop runs"
else
  bad "listener never abandoned a permanently silent stream (wedged in read())"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
