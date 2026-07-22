#!/bin/bash
# Unit test for scripts/slack-mcp.sh — the spy-compatible MCP-proxy Slack client.
# No framework: stubs `security` (keychain) and `curl` (network) via PATH shims, keeps `jq`
# real so the JSON-RPC framing and spy-shape mapping are genuinely exercised. Drives each
# subcommand end-to-end and asserts on stdout / exit codes. Run: bash tests/slack-mcp.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="${SCRIPT_DIR}/../scripts/slack-mcp.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
# assert <desc> <expected> <actual>
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

setup() {
  TMP="$(mktemp -d)"
  # Isolate config: point EA_AGENT_DIR at an empty temp dir so no real ~/.local config is read
  # and the shim falls back to its default server/server_id (curl is stubbed, so URL is moot).
  export EA_AGENT_DIR="$TMP/agent"; mkdir -p "$EA_AGENT_DIR"

  # Stub bin dir first on PATH: our fake `security` and `curl` shadow the real ones. jq/date/
  # uuidgen/sed/grep stay real.
  BIN="$TMP/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"

  export CURL_LOG="$TMP/curl.log"; : > "$CURL_LOG"

  # --- fake security: emits a credential JSON whose expiry/shape the test controls ----------
  # SECURITY_RC != 0  -> entry missing (exit nonzero, no output)
  # SECURITY_EXP      -> expiresAt value (epoch ms) baked into the credential blob
  # SECURITY_NOTOKEN=1-> valid JSON but no accessToken
  cat > "$BIN/security" <<'EOF'
#!/bin/bash
[ "${SECURITY_RC:-0}" != "0" ] && exit "${SECURITY_RC}"
if [ "${SECURITY_NOTOKEN:-0}" = "1" ]; then
  echo '{"claudeAiOauth":{"expiresAt":'"${SECURITY_EXP:-0}"'}}'; exit 0
fi
echo '{"claudeAiOauth":{"accessToken":"tok-abc","refreshToken":"ref-xyz","expiresAt":'"${SECURITY_EXP:-0}"',"scopes":["user:inference"]}}'
exit 0
EOF
  chmod +x "$BIN/security"

  # --- fake curl: parses the JSON-RPC request, logs it, returns canned SSE frames -----------
  cat > "$BIN/curl" <<'EOF'
#!/bin/bash
hdrfile=""; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -D) hdrfile="$2"; shift 2 ;;
    -d) data="$2"; shift 2 ;;
    -H|-X|--max-time) shift 2 ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$data" >> "$CURL_LOG"
[ -n "$url" ] && printf '%s\n' "$url" >> "${URL_LOG:-/dev/null}"
method="$(printf '%s' "$data" | jq -r '.method // empty' 2>/dev/null)"
tool="$(printf '%s' "$data" | jq -r '.params.name // empty' 2>/dev/null)"
sse() { printf 'event: message\ndata: %s\n\n' "$1"; }   # one SSE message frame
if [ "${CURL_GARBAGE:-0}" = "1" ]; then
  # Simulate an auth/connectivity failure that returns an HTML error page, not JSON.
  [ -n "$hdrfile" ] && printf 'HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\n\r\n' > "$hdrfile"
  printf '<html><body>403 Forbidden</body></html>\n'
  exit 0
fi
case "$method" in
  initialize)
    [ -n "$hdrfile" ] && printf 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nMcp-Session-Id: test-session-123\r\n\r\n' > "$hdrfile"
    sse '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"slack"}}}' ;;
  notifications/initialized) : ;;   # 202, empty body
  tools/list)
    sse '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"slack_read_channel"},{"name":"slack_read_thread"},{"name":"slack_send_message"}]}}' ;;
  tools/call)
    # The connector wraps a human-readable TEXT blob in {"messages":"…"} (reads) — NOT structured
    # JSON. These fixtures mirror the two real formats captured from the live connector.
    case "$tool" in
      slack_read_channel)
        # Two messages: one with a Thread line (reply_count) + trailing Reactions/Files metadata.
        inner=$(printf 'Channel: #general (C123)\n\n=== Message from Alice Smith <alice@x.com> (U111) at 2026-07-16 10:45:01 EDT === \nMessage TS: 1700000000.000100\nhello world\nsecond line\nReactions: +1 (3)\n\n=== Message from Bob Lee <bob@x.com> (U222) at 2026-07-16 10:40:00 EDT === \nMessage TS: 1700000000.000090\nquestion for the team?\nThread: 2 replies (latest: 2026-07-16 10:44:00 EDT)\nFiles: doc.pdf (ID: F1)')
        sse "$(jq -nc --arg t "$inner" '{jsonrpc:"2.0",id:3,result:{content:[{type:"text",text:$t}]}}')" ;;
      slack_read_thread)
        inner=$(printf '=== THREAD PARENT MESSAGE ===\nFrom: Bob Lee <bob@x.com> (U222)\nTime: 2026-07-16 10:40:00 EDT\nMessage TS: 1700000000.000090\nquestion for the team?\n\n=== THREAD REPLIES (1 total) ===\n\n--- Reply 1 of 1 ---\nFrom: Alice Smith <alice@x.com> (U111)\nTime: 2026-07-16 10:44:00 EDT\nMessage TS: 1700000000.000200\nhere is the answer')
        sse "$(jq -nc --arg t "$inner" '{jsonrpc:"2.0",id:3,result:{content:[{type:"text",text:$t}]}}')" ;;
      slack_send_message)
        # The post tool returns a human-readable confirmation with a permalink (not JSON).
        inner='Message sent. Link: https://x.slack.com/archives/C123/p1700000001000900'
        sse "$(jq -nc --arg t "$inner" '{jsonrpc:"2.0",id:3,result:{content:[{type:"text",text:$t}]}}')" ;;
      *)
        sse '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{}"}]}}' ;;
    esac ;;
  *) sse '{"jsonrpc":"2.0","id":0,"result":{}}' ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"

  # Fresh, valid token by default: expiry ~1h in the future (epoch ms).
  export SECURITY_EXP=$(( ($(date +%s) + 3600) * 1000 ))
  unset SECURITY_RC SECURITY_NOTOKEN
  # server_id is required by the shim; provide one via env for every test except the config
  # -override case (test 11), which unsets it so the config value is exercised.
  export EA_SLACK_MCP_SERVER_ID="mcpsrv_test"
}
teardown() { rm -rf "$TMP"; }

echo "== slack-mcp.sh unit tests =="
setup

# 1. auth: successful initialize -> {ok:true}
out="$("$SHIM" auth --json 2>/dev/null)"
eq "auth returns ok" "true" "$(printf '%s' "$out" | jq -r '.ok')"

# 2. list-tools: returns the connector tool list
out="$("$SHIM" list-tools 2>/dev/null)"
eq "list-tools includes read_channel" "slack_read_channel" \
   "$(printf '%s' "$out" | jq -r '.tools[0].name')"

# 3. read: parses the channel TEXT blob into spy message shape (multi-line body, metadata
#    stripped, reply_count from the Thread: line, thread_ts set on the parent).
out="$("$SHIM" read C123 5 --json 2>/dev/null)"
eq "read: count"             "2"                  "$(printf '%s' "$out" | jq -r 'length')"
eq "read: msg0 ts"           "1700000000.000100"  "$(printf '%s' "$out" | jq -r '.[0].ts')"
eq "read: msg0 user_id"      "U111"               "$(printf '%s' "$out" | jq -r '.[0].user_id')"
eq "read: msg0 user_name"    "Alice Smith"        "$(printf '%s' "$out" | jq -r '.[0].user_name')"
eq "read: msg0 multiline text" "hello world"$'\n'"second line" "$(printf '%s' "$out" | jq -r '.[0].text')"
eq "read: msg0 reactions stripped" "false"        "$(printf '%s' "$out" | jq -r '.[0].text|contains("Reactions")')"
eq "read: msg1 reply_count"  "2"                  "$(printf '%s' "$out" | jq -r '.[1].reply_count')"
eq "read: msg1 thread_ts"    "1700000000.000090"  "$(printf '%s' "$out" | jq -r '.[1].thread_ts')"
eq "read: msg1 metadata stripped" "question for the team?" "$(printf '%s' "$out" | jq -r '.[1].text')"

# 4. thread: parses the THREAD blob (parent + reply; identity from From: lines)
out="$("$SHIM" thread C123 1700000000.000090 --json 2>/dev/null)"
eq "thread: count"           "2"                  "$(printf '%s' "$out" | jq -r 'length')"
eq "thread: parent user_id"  "U222"               "$(printf '%s' "$out" | jq -r '.[0].user_id')"
eq "thread: reply user_id"   "U111"               "$(printf '%s' "$out" | jq -r '.[1].user_id')"
eq "thread: reply user_name" "Alice Smith"        "$(printf '%s' "$out" | jq -r '.[1].user_name')"
eq "thread: reply text"      "here is the answer" "$(printf '%s' "$out" | jq -r '.[1].text')"

# 5. send: uses channel_id/message args; returns {ok,ts,channel}, ts recovered from permalink
out="$("$SHIM" send C123 "hi there" --json 2>/dev/null)"
eq "send: ok"                "true"               "$(printf '%s' "$out" | jq -r '.ok')"
eq "send: ts from permalink" "1700000001.000900"  "$(printf '%s' "$out" | jq -r '.ts')"
eq "send: channel"           "C123"               "$(printf '%s' "$out" | jq -r '.channel')"
: > "$CURL_LOG"
"$SHIM" send C123 "hi" --json >/dev/null 2>&1
eq "send: arg names channel_id/message" "true" \
   "$(grep '"tools/call"' "$CURL_LOG" | jq -r 'first(select(.params.name=="slack_send_message"))|(.params.arguments|has("channel_id") and has("message"))')"

# 6. send --thread: thread_ts is forwarded in the tool-call arguments
: > "$CURL_LOG"
"$SHIM" send C123 "reply text" --thread 1700000000.000100 --json >/dev/null 2>&1
sent_thread="$(grep '"tools/call"' "$CURL_LOG" | jq -r '.params.arguments.thread_ts // empty' | head -1)"
eq "send --thread forwards thread_ts" "1700000000.000100" "$sent_thread"

# 7. expired token: clean skip (exit 75, {"skipped":true}), and NO network call made
export SECURITY_EXP=$(( ($(date +%s) - 60) * 1000 ))   # 60s in the past
: > "$CURL_LOG"
out="$("$SHIM" read C123 5 --json 2>/dev/null)"; rc=$?
eq "expired: exit code 75"        "75"   "$rc"
eq "expired: skipped=true"        "true" "$(printf '%s' "$out" | jq -r '.skipped')"
eq "expired: no network call"     "0"    "$(wc -l < "$CURL_LOG" | tr -d ' ')"
export SECURITY_EXP=$(( ($(date +%s) + 3600) * 1000 ))

# 8. missing keychain entry: clean skip too
export SECURITY_RC=44
out="$("$SHIM" auth --json 2>/dev/null)"; rc=$?
eq "no-entry: exit code 75"       "75"   "$rc"
eq "no-entry: skipped=true"       "true" "$(printf '%s' "$out" | jq -r '.skipped')"
unset SECURITY_RC

# 9. credential present but no accessToken: clean skip
export SECURITY_NOTOKEN=1
out="$("$SHIM" auth --json 2>/dev/null)"; rc=$?
eq "no-token: exit code 75"       "75"   "$rc"
unset SECURITY_NOTOKEN

# 10. handshake order: initialize -> notifications/initialized -> tools/call
: > "$CURL_LOG"
"$SHIM" read C123 5 --json >/dev/null 2>&1
methods="$(jq -r '.method' "$CURL_LOG" | tr '\n' ',')"
eq "handshake order" "initialize,notifications/initialized,tools/call," "$methods"

# 11. config override: agent.slack.mcp.server_id from config is used in the request URL
#     (regression guard for the trailing-comment bug in the yaml_agent_slack_mcp reader).
cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  slack:
    method: "mcp-proxy"
    mcp:
      server: "https://proxy.test/v1/mcp"   # inline comment must not break parsing
      server_id: "mcpsrv_FROMCONFIG"        # inline comment here too
projects: {}
YAML
export URL_LOG="$TMP/url.log"; : > "$URL_LOG"
unset EA_SLACK_MCP_SERVER_ID   # so the config value (not the env default) is exercised
"$SHIM" auth --json >/dev/null 2>&1
eq "config server_id used in URL" "https://proxy.test/v1/mcp/mcpsrv_FROMCONFIG" "$(head -1 "$URL_LOG")"
rm -f "$EA_AGENT_DIR/engineer.yaml"; unset URL_LOG
export EA_SLACK_MCP_SERVER_ID="mcpsrv_test"   # restore for remaining tests

# 12. non-JSON proxy response: a clear error + non-zero exit that is NOT the 75 skip code
export CURL_GARBAGE=1
err="$("$SHIM" auth --json 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 75 ]; then ok "non-JSON: fails (not the skip code)"; else bad "non-JSON: expected a hard error, got rc=$rc"; fi
case "$err" in *non-JSON*) ok "non-JSON: actionable error message" ;; *) bad "non-JSON: message was '$err'" ;; esac
unset CURL_GARBAGE

# 13. _parse seam (no network): parser edge cases fed directly on stdin.
# 13a. Message with NO metadata (no Reactions/Thread/Files) => reply_count 0, clean text.
out="$(printf '=== Message from Carol <c@x.com> (U999) at 2026-01-01 00:00:00 EST === \nMessage TS: 1.0\nonly a body' | "$SHIM" _parse)"
eq "_parse: no-metadata reply_count" "0" "$(printf '%s' "$out" | jq -r '.[0].reply_count')"
eq "_parse: no-metadata text"        "only a body" "$(printf '%s' "$out" | jq -r '.[0].text')"
# 13b. Body line that itself starts with "From:" AFTER the ts must stay in the text (not be
#      swallowed as identity metadata).
out="$(printf '=== THREAD PARENT MESSAGE ===\nFrom: Dan <d@x.com> (U888)\nMessage TS: 2.0\nquoting:\nFrom: someone else' | "$SHIM" _parse)"
eq "_parse: From: in body kept"      "quoting:"$'\n'"From: someone else" "$(printf '%s' "$out" | jq -r '.[0].text')"
eq "_parse: thread identity"         "U888" "$(printf '%s' "$out" | jq -r '.[0].user_id')"
# 13c. Empty input => empty array, not an error.
eq "_parse: empty input"             "0" "$(printf '' | "$SHIM" _parse | jq -r 'length')"

# 14. missing server_id: a clear error mentioning server_id (no bogus default connector).
unset EA_SLACK_MCP_SERVER_ID
err="$("$SHIM" auth --json 2>&1 >/dev/null)"; rc=$?
case "$err" in *server_id*) ok "missing server_id: actionable error" ;; *) bad "missing server_id: message was '$err'" ;; esac
[ "$rc" -ne 0 ] && ok "missing server_id: non-zero exit" || bad "missing server_id: expected non-zero exit"
export EA_SLACK_MCP_SERVER_ID="mcpsrv_test"

teardown
echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
