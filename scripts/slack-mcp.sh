#!/bin/bash
# slack-mcp.sh — a spy(1)-compatible Slack client backed by the Anthropic MCP proxy.
#
# WHY THIS EXISTS: engineer-agent's Slack surface historically ran through the `spy` CLI,
# which reuses the local Slack desktop session by scraping browser tokens (xoxc/xoxd). On
# Slack ENTERPRISE GRID that is broken and unsafe: the first automated call with a scraped
# xoxc is flagged as suspicious cross-context token use and force-logs the human out, xoxd
# rotates every few hours, and Slack keeps relocating where the tokens live. So on Grid,
# every Slack feature (poll -> answer -> post, digest, standup, status) silently dies.
#
# This script sidesteps browser tokens entirely. It reads Claude Code's existing claude.ai
# OAuth access token from the macOS login Keychain (READ-ONLY) and speaks JSON-RPC over
# Streamable-HTTP to Anthropic's MCP proxy, which fronts the official Slack connector. No
# browser tokens, no LLM invocation, zero model-token cost. It presents the SAME subcommands
# and JSON output shape as `spy`, so callers select it purely via config
# (`agent.slack.method: mcp-proxy`) and every existing call site works unchanged.
#
# Subcommands (spy-compatible):
#   read   <channel> <count> [--json] [-w <ws>]              recent messages in a channel
#   thread <channel> <ts>    [--json] [-w <ws>]              full thread context
#   send   <channel> <text>  [--thread <ts>] [--json] [-w <ws>]   post a (threaded) message
#   auth                     [--json] [-w <ws>]              signed-in identity / health check
# Discovery / debug (not used by skills):
#   list-tools               dump the connector's tools/list (use this to confirm tool names)
#   call <tool> <json-args>  call an arbitrary connector tool, print its raw text result
#
# `-w <workspace>` and `--json` are accepted for spy arg-compatibility. The connector is bound
# to its authorized workspace, so `-w` is a no-op here; output is always JSON, so `--json` is
# a no-op too. Accepting them means callers need no per-method branching.
#
# CRITICAL SAFETY CONSTRAINT (keychain): we only ever READ the Keychain token. We NEVER run an
# OAuth refresh or rewrite the Keychain entry -- a standard OAuth refresh rotates the refresh
# token, and re-storing it would invalidate Claude Code's own credential. If the token is
# expired we SKIP CLEANLY: print {"skipped":true,...} and exit EX_TOKEN_EXPIRED (75) so callers
# treat it as a *skipped* source, not a *failed* one. Claude Code re-auths on its own; the next
# run then succeeds. (This also means we depend on the login keychain being unlocked, which on
# macOS only happens inside the GUI login session -- the same reason the poll runs as a
# gui-session LaunchAgent. See CLAUDE.md -> Notifications & Remote Approval.)

set -euo pipefail

# EX_TOKEN_EXPIRED: distinct exit code so a caller (poll-slack, status) can tell "token expired,
# skip cleanly" apart from "real error". Matches BSD sysexits EX_TEMPFAIL.
readonly EX_TOKEN_EXPIRED=75

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib-paths.sh
source "${PLUGIN_ROOT}/scripts/lib-paths.sh"   # EA_CONFIG_FILE + USER/LOGNAME normalization

readonly KEYCHAIN_SERVICE="Claude Code-credentials"
readonly PROTOCOL_VERSION="2025-06-18"
readonly DEFAULT_SERVER="https://mcp-proxy.anthropic.com/v1/mcp"

# --- Connector tool names + result shape (confirmed against a live tools/list) --------------
# The official Slack connector's tools. Overridable via EA_SLACK_TOOL_* for forward-compat if
# the connector renames them. read/thread take `channel_id` (+ `limit`/`message_ts`); post
# takes `channel_id` + `message` (NOT the Slack-API `channel`/`text`). Results are NOT raw
# Slack JSON — the connector returns a human-readable Markdown-ish TEXT blob (see
# parse_messages_text), so the read/thread paths parse that text into spy's message shape.
TOOL_HISTORY="${EA_SLACK_TOOL_HISTORY:-slack_read_channel}"
TOOL_THREAD="${EA_SLACK_TOOL_THREAD:-slack_read_thread}"
TOOL_POST="${EA_SLACK_TOOL_POST:-slack_send_message}"

# --- Config: agent.slack.mcp.{server,server_id} -------------------------------------------
# yaml_agent_slack_mcp() is provided by lib-paths.sh (sourced above) — the same agent:-scoped
# descent used elsewhere, so this stays a single source of truth.
die() { echo "slack-mcp: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
need curl; need jq; need security

SERVER="${EA_SLACK_MCP_SERVER:-$(yaml_agent_slack_mcp server)}"
SERVER="${SERVER:-$DEFAULT_SERVER}"; SERVER="${SERVER%/}"
# server_id identifies YOUR authorized Slack connector — there is no sensible default (a wrong
# id reaches a connector you have not authorized, which the proxy rejects). Require it.
SERVER_ID="${EA_SLACK_MCP_SERVER_ID:-$(yaml_agent_slack_mcp server_id)}"
[ -n "$SERVER_ID" ] || die "agent.slack.mcp.server_id is not set (or \$EA_SLACK_MCP_SERVER_ID). Find your Slack connector's mcpsrv id (claude.ai → Connectors, or /mcp) and set it in config."
readonly MCP_URL="${SERVER}/${SERVER_ID}"

# --- Keychain token (read-only; skip cleanly on expiry) -----------------------------------
ACCESS_TOKEN=""
load_token() {
  local blob token exp now_ms
  # `security ... -w` prints just the password value (the credential JSON). Missing entry ->
  # non-zero; treat that as "not logged in", a clean skip (Claude Code not authed on this box).
  if ! blob="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"; then
    echo '{"skipped":true,"reason":"no Claude Code credential in keychain"}'; exit "$EX_TOKEN_EXPIRED"
  fi
  token="$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  exp="$(printf '%s' "$blob"   | jq -r '.claudeAiOauth.expiresAt // empty'   2>/dev/null)"
  if [ -z "$token" ]; then
    echo '{"skipped":true,"reason":"no access token in keychain credential"}'; exit "$EX_TOKEN_EXPIRED"
  fi
  # expiresAt is epoch MILLISECONDS. Skip with a 120s safety margin. A malformed/absent expiry
  # is treated as usable (let the proxy reject it) rather than force-skipping.
  if [ -n "$exp" ] && printf '%s' "$exp" | grep -qE '^[0-9]+$'; then
    now_ms=$(( $(date +%s) * 1000 ))
    if [ "$exp" -le $(( now_ms + 120000 )) ]; then
      echo '{"skipped":true,"reason":"token expired — Claude Code will re-auth; skipping this run"}'
      exit "$EX_TOKEN_EXPIRED"
    fi
  fi
  ACCESS_TOKEN="$token"
}

# --- MCP transport (JSON-RPC over Streamable-HTTP) ----------------------------------------
# Handshake: initialize (capture Mcp-Session-Id response header) -> notifications/initialized
# -> tools/call | tools/list. Responses come back as either application/json or SSE
# (text/event-stream); extract_jsonrpc() handles both.
SESSION_ID=""
CLIENT_SESSION_ID=""

# Pull the JSON-RPC payload out of a proxy response body: SSE frames carry it on `data:`
# lines, plain JSON responses are the body itself. Prints the last data payload that parses
# as an object (the response frame), else the raw body.
extract_jsonrpc() {
  local body="$1" data
  if printf '%s\n' "$body" | grep -q '^data:'; then
    # `|| true`: a malformed data line makes jq exit non-zero, which pipefail would propagate
    # and set -e would turn into a bare abort. Tolerate it and fall through to the raw body.
    data="$(printf '%s\n' "$body" | sed -n 's/^data: \{0,1\}//p' | jq -c 'select(type=="object")' 2>/dev/null | tail -1 || true)"
    [ -n "$data" ] && { printf '%s' "$data"; return 0; }
  fi
  printf '%s' "$body"
}

# require_json <label> <text> — die with an actionable message (not a cryptic set -e abort)
# when the proxy returns something that isn't JSON (an HTML error page, a 500 body, a login
# redirect — all common when auth is the problem).
require_json() {
  printf '%s' "$2" | jq -e . >/dev/null 2>&1 \
    || die "$1: proxy returned a non-JSON response (auth or connectivity problem?): $(printf '%s' "$2" | tr '\n' ' ' | head -c 200)"
}

# post_rpc <json-request> [expect_session_header]
# POSTs one JSON-RPC message. When expect_session_header=1, parses Mcp-Session-Id from the
# response headers into SESSION_ID. Prints the response body (headers stripped).
post_rpc() {
  local req="$1" capture_session="${2:-0}" hdrfile body sid
  hdrfile="$(mktemp)"
  # The Mcp-Session-Id header is sent only once we have one: the ${SESSION_ID:+...} expansion
  # emits the -H flag on later calls and nothing on the initialize call (SESSION_ID still "").
  # --retry 2: transient blips (recv timeout, connection reset, 5xx/429) self-heal without
  # failing a whole poll cycle. curl does NOT retry ordinary 4xx (e.g. a 403 auth error), so a
  # genuine auth failure still surfaces immediately.
  body="$(curl -sS --max-time 60 --retry 2 --retry-connrefused -X POST "$MCP_URL" \
    -D "$hdrfile" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "X-Mcp-Client-Session-Id: ${CLIENT_SESSION_ID}" \
    ${SESSION_ID:+-H "Mcp-Session-Id: ${SESSION_ID}"} \
    -d "$req")" || { rm -f "$hdrfile"; die "request to proxy failed"; }
  if [ "$capture_session" = "1" ]; then
    # Header names are case-insensitive; match either casing, take the value, trim CR/space.
    # `|| true`: grep returns 1 when the header is absent, which set -e would treat as fatal.
    sid="$(grep -i '^mcp-session-id:' "$hdrfile" 2>/dev/null | head -1 | sed 's/^[^:]*: *//; s/[[:space:]]*$//' | tr -d '\r' || true)"
    [ -n "$sid" ] && SESSION_ID="$sid"
  fi
  rm -f "$hdrfile"
  printf '%s' "$body"
}

mcp_connect() {
  load_token
  CLIENT_SESSION_ID="$(uuidgen)"
  local init resp err
  init=$(jq -nc --arg pv "$PROTOCOL_VERSION" '{
    jsonrpc:"2.0", id:1, method:"initialize",
    params:{ protocolVersion:$pv, capabilities:{},
             clientInfo:{ name:"engineer-agent-slack-mcp", version:"1.0.0" } } }')
  resp="$(extract_jsonrpc "$(post_rpc "$init" 1)")"
  require_json "initialize" "$resp"
  err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null || true)"
  [ -n "$err" ] && die "initialize failed: $err"
  printf '%s' "$resp" | jq -e '.result' >/dev/null 2>&1 || die "initialize returned no result: $resp"
  # Fire-and-forget the initialized notification (202, empty body).
  post_rpc '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || true
}

# mcp_tools_list -> prints the tools/list result JSON (.result.tools[...]).
mcp_tools_list() {
  mcp_connect
  local resp err
  resp="$(extract_jsonrpc "$(post_rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')")"
  require_json "tools/list" "$resp"
  err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null || true)"
  [ -n "$err" ] && die "tools/list failed: $err"
  printf '%s' "$resp" | jq '.result'
}

# mcp_call_text <tool> <arguments-json> -> prints the concatenated text of the tool result
# content blocks (MCP results are content:[{type:"text",text:...}]). Errors are fatal.
mcp_call_text() {
  local tool="$1" args="$2" req resp err
  req=$(jq -nc --arg n "$tool" --argjson a "$args" \
    '{jsonrpc:"2.0", id:3, method:"tools/call", params:{name:$n, arguments:$a}}')
  resp="$(extract_jsonrpc "$(post_rpc "$req")")"
  require_json "tool '$tool'" "$resp"
  err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null || true)"
  [ -n "$err" ] && die "tool '$tool' failed: $err"
  # isError inside the result is a tool-level failure (bad channel, no permission, ...).
  if [ "$(printf '%s' "$resp" | jq -r '.result.isError // false' 2>/dev/null)" = "true" ]; then
    die "tool '$tool' error: $(printf '%s' "$resp" | jq -r '[.result.content[]?.text] | join(" ")')"
  fi
  printf '%s' "$resp" | jq -r '[.result.content[]? | select(.type=="text") | .text] | join("\n")'
}

# --- spy-compatible message mapping -------------------------------------------------------
# The connector's read/thread result is NOT structured JSON — its content text is a JSON object
# whose `messages` field is a human-readable blob. There are TWO block formats:
#
#   CHANNEL (slack_read_channel) — identity is inline in the header:
#     === Message from <Name> <email> (<USER_ID>) at <time> ===
#     Message TS: 1784213101.258209
#     <body, may span multiple / blank lines>
#     Reactions: +1 (3), ...           <- optional trailing metadata (any of these, any order)
#     Thread: 2 replies (latest: ...)  <- optional; gives reply_count + marks a thread parent
#     Files: name.mp4 (ID: ...)        <- optional
#
#   THREAD (slack_read_thread) — identity on a following `From:` line:
#     === THREAD PARENT MESSAGE ===        (or:  --- Reply N of M ---)
#     From: <Name> <email> (<USER_ID>)
#     Time: <time>
#     Message TS: 1783621805.468149
#     <body>
#     (the line `=== THREAD REPLIES (N total) ===` separates parent from replies)
#
# parse_messages_text reads the blob on stdin and emits spy's JSON array
# ({ts,user_id,user_name,text,reply_count,thread_ts}) so downstream skill logic is unchanged.
# awk splits on the block delimiters (blank lines cannot delimit — bodies contain them), pulls
# identity from either the inline header or a From: line, strips trailing metadata, and captures
# reply_count from a Thread: line. Fields are joined with US (0x1f) / GS (0x1e) control chars and
# assembled by jq, which handles JSON escaping of the free-text body safely.
parse_messages_text() {
  awk '
    BEGIN { US=sprintf("%c",31); GS=sprintf("%c",30) }
    # setident(s): pull "(USER_ID)" and the display name (text before " <" or " (") out of an
    # identity string — works for both the inline channel header and a thread From: line.
    function setident(s) {
      uid=""; if (match(s, /\(U[A-Z0-9]+\)/)) uid=substr(s,RSTART+1,RLENGTH-2)
      p=index(s," <"); if (p==0) p=index(s," (")
      uname=(p>0)?substr(s,1,p-1):s
      sub(/[ \t]+$/,"",uname)
    }
    function flush(  tail, ms) {
      if (!have) return
      sub(/^\n+/,"",body); sub(/\n+$/,"",body)
      # Pop trailing connector metadata lines, capturing reply_count from a Thread line.
      # ms saves the OUTER match position first: the inner match() below overwrites the global
      # RSTART, so using RSTART after it would truncate body to the wrong offset.
      while (match(body, /\n(Reactions|Thread|Files|Edited): [^\n]*$/)) {
        ms = RSTART
        tail = substr(body, ms+1)
        if (tail ~ /^Thread: / && match(tail, /[0-9]+ repl/)) { rc = substr(tail, RSTART); sub(/ repl.*/, "", rc); reply_count = rc + 0 }
        body = substr(body, 1, ms-1); sub(/\n+$/,"",body)
      }
      thread_ts = (reply_count > 0) ? ts : ""
      # reply_count+0 forces a numeric string ("0"): an uninitialized awk var prints as "" with
      # %s, and a later tonumber on "" throws (surfacing as a misleading "Expected JSON value").
      printf "%s%s%s%s%s%s%s%s%s%s%s%s", ts, US, uid, US, uname, US, (reply_count+0), US, thread_ts, US, body, GS
      have=0; ts=""; uid=""; uname=""; body=""; reply_count=0; thread_ts=""
    }
    # Message-start delimiters. Channel header carries identity inline; thread delimiters do not
    # (a From: line follows).
    /^=== Message from / { flush(); have=1; h=$0; sub(/^=== Message from /,"",h); setident(h); next }
    /^=== THREAD PARENT MESSAGE ===/ { flush(); have=1; next }
    /^--- Reply [0-9]+ of [0-9]+ ---/ { flush(); have=1; next }
    /^=== THREAD REPLIES/ { next }   # parent/replies separator line, not a message
    # From:/Time: lines are per-message metadata ONLY before the body starts (ts still unset);
    # once ts is set, a body line that happens to start with From:/Time: is real text.
    (have && ts=="" && $0 ~ /^From: /) { h=$0; sub(/^From: /,"",h); setident(h); next }
    (have && ts=="" && $0 ~ /^Time: /) { next }
    /^Message TS: / { t=$0; sub(/^Message TS: /,"",t); ts=t; next }
    { if (have) body=(body=="")?$0:body "\n" $0 }
    END { flush() }
  ' | jq -Rs '
    split("\u001e") | map(select(length>0)) | map(split("\u001f")) | map({
      ts: .[0], user_id: .[1], user_name: .[2],
      reply_count: (.[3]|tonumber? // 0), thread_ts: (if (.[4]//"")=="" then null else .[4] end),
      text: (.[5] // "") })'
}

# extract_result_text <raw> <field> — the connector wraps its text blob in a JSON object
# ({"messages":"…"} for reads, {"results":"…"} for search). Pull the named field; if the
# result isn't that shape, fall back to the raw text so a format change fails visibly.
extract_result_text() {
  printf '%s' "$1" | jq -er --arg f "$2" '.[$f]' 2>/dev/null || printf '%s' "$1"
}

# --- Subcommands --------------------------------------------------------------------------
cmd_read() {
  local channel="$1" count="${2:-50}" raw
  mcp_connect   # load token (skip-on-expiry) + handshake before any tool call
  # slack_read_channel: channel_id + limit (max 100). Result text is the messages blob.
  raw="$(mcp_call_text "$TOOL_HISTORY" "$(jq -nc --arg c "$channel" --argjson n "$count" '{channel_id:$c, limit:$n}')")"
  extract_result_text "$raw" messages | parse_messages_text
}

cmd_thread() {
  local channel="$1" ts="$2" raw
  mcp_connect
  # slack_read_thread: channel_id + message_ts (the parent's ts). Same messages-blob format.
  raw="$(mcp_call_text "$TOOL_THREAD" "$(jq -nc --arg c "$channel" --arg t "$ts" '{channel_id:$c, message_ts:$t}')")"
  extract_result_text "$raw" messages | parse_messages_text
}

cmd_send() {
  local channel="$1" text="$2" thread_ts="$3" args raw ts
  mcp_connect
  # slack_send_message: channel_id + message (NOT channel/text); optional thread_ts for replies.
  args="$(jq -nc --arg c "$channel" --arg t "$text" --arg th "$thread_ts" \
    '{channel_id:$c, message:$t} + (if $th != "" then {thread_ts:$th} else {} end)')"
  raw="$(mcp_call_text "$TOOL_POST" "$args")"
  # The post tool returns a human-readable confirmation (it "returns the message link"), not
  # structured JSON. A non-error result means the post landed; recover a ts from the text if a
  # permalink is present (…/pNNNNNNNNNN → NNNNNNNNNN with a decimal inserted), else leave blank.
  # spy's callers only need {ok, ts, channel}; ts is informational.
  ts="$(printf '%s' "$raw" | grep -oE '/p[0-9]{16}' | head -1 | sed -E 's#/p([0-9]{10})([0-9]{6})#\1.\2#')"
  jq -nc --arg c "$channel" --arg ts "$ts" --arg raw "$raw" \
    '{ok:true, ts:$ts, channel:$c} + (if ($raw|length)>0 then {note:$raw} else {} end)'
}

cmd_auth() {
  # No message traffic — a successful initialize proves the token + connector are usable,
  # which is exactly what the status health check needs.
  mcp_connect
  jq -nc --arg url "$MCP_URL" '{ok:true, team:"", user:"", proxy:$url}'
}

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- Arg parsing (spy-compatible: positional + --json/-w/--thread) ------------------------
main() {
  [ $# -ge 1 ] || usage 1
  local sub="$1"; shift
  local -a pos=()
  local thread_ts=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) shift ;;                       # always JSON; accepted for spy-compat
      -w|--workspace) shift 2 2>/dev/null || shift ;;  # connector-bound workspace; no-op
      --thread) thread_ts="${2:-}"; shift 2 ;;
      -h|--help) usage 0 ;;
      --) shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      *) pos+=("$1"); shift ;;
    esac
  done

  case "$sub" in
    read)    [ ${#pos[@]} -ge 1 ] || die "usage: read <channel> [count]"
             cmd_read "${pos[0]}" "${pos[1]:-50}" ;;
    thread)  [ ${#pos[@]} -ge 2 ] || die "usage: thread <channel> <ts>"
             cmd_thread "${pos[0]}" "${pos[1]}" ;;
    send)    [ ${#pos[@]} -ge 2 ] || die "usage: send <channel> <text> [--thread <ts>]"
             cmd_send "${pos[0]}" "${pos[1]}" "$thread_ts" ;;
    auth)    cmd_auth ;;
    list-tools) mcp_tools_list ;;
    call)    [ ${#pos[@]} -ge 2 ] || die "usage: call <tool> <json-args>"
             mcp_connect; mcp_call_text "${pos[0]}" "${pos[1]}" ;;
    _parse)  parse_messages_text ;;   # test seam: parse a messages-blob from stdin, no network
    -h|--help|help) usage 0 ;;
    *)       die "unknown subcommand: $sub (try --help)" ;;
  esac
}

main "$@"
