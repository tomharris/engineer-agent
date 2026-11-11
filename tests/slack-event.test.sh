#!/bin/bash
# Tests for scripts/slack-event.sh — status reactions and the watched-thread registry.
# `spy` is a PATH stub that logs argv; exit codes per verb are set by the test.
#
# Run: bash tests/slack-event.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EV="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/slack-event.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state" "$TMP/bin"
export PATH="$TMP/bin:$PATH" SPY_ARGV="$TMP/spy.argv"
cat > "$TMP/bin/spy" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SPY_ARGV"
case "$1" in react) exit "${SPY_REACT_RC:-0}" ;; unreact) exit "${SPY_UNREACT_RC:-0}" ;; esac
EOF
chmod +x "$TMP/bin/spy"

config() {   # config <auto_execute flow list> [reactions block]
  cat > "$EA_AGENT_DIR/engineer.yaml" <<YAML
agent:
  autonomy:
    auto_execute: $1
  slack:
    workspace: "myco"
    reactions:
${2:-      detected: eyes
      drafted: memo
      posted: white_check_mark
      rejected: no_entry_sign}
projects:
  alpha:
    path: "/tmp/alpha"
    slack:
      channels: ["C1"]
YAML
}
item() {   # item <dir> <name> [extra frontmatter line]
  printf -- '---\ntype: slack-question\nsource: %s\nproject: "alpha"\nchannel_id: "%s"\nmessage_ts: "1700000100.000200"\n%s\n---\n' \
    "${SRC:-slack}" "${CH:-C1}" "${3:-}" > "$EA_AGENT_DIR/queue/$1/$2"
}
reset() {
  rm -f "$EA_AGENT_DIR"/queue/*/* "$SPY_ARGV" "$EA_AGENT_DIR/state/watched-threads.tsv" "$EA_AGENT_DIR/state/slack-events.log"
  unset SPY_REACT_RC SPY_UNREACT_RC SRC CH
}
calls() { cat "$SPY_ARGV" 2>/dev/null | paste -sd'|' -; }
W="$EA_AGENT_DIR/state/watched-threads.tsv"

echo "== tier and closed map"
reset; config '[]'; item incoming a.md
bash "$EV" detected a.md; eq "slack-react tier absent => exit 0, no Slack call" "0|" "$?|$(calls)"
reset; config '["slack-react"]'; item incoming a.md
bash "$EV" detected a.md
eq "detected adds the mapped emoji on the item's message" "react C1 1700000100.000200 eyes --json -w myco" "$(calls)"
reset; config '["slack-react"]' '      detected: eyes'; item drafts a.md
bash "$EV" drafted a.md; eq "unmapped event => no call" "" "$(calls)"
reset; config '["slack-react"]' '      detected: "eyes; rm"'; item incoming a.md
bash "$EV" detected a.md
eq "emoji outside ^[a-z0-9_+-]+\$ => no call, logged" "|1" "$(calls)|$(grep -c 'invalid emoji' "$EA_AGENT_DIR/state/slack-events.log")"

echo "== swap"
reset; config '["slack-react"]'; item completed a.md
bash "$EV" posted a.md
eq "posted adds its emoji, then removes every earlier status" \
  "react C1 1700000100.000200 white_check_mark --json -w myco|unreact C1 1700000100.000200 eyes --json -w myco|unreact C1 1700000100.000200 memo --json -w myco" "$(calls)"
reset; config '["slack-react"]'; item drafts a.md
bash "$EV" drafted a.md
eq "drafted removes only detected" "react C1 1700000100.000200 memo --json -w myco|unreact C1 1700000100.000200 eyes --json -w myco" "$(calls)"
reset; config '["slack-react"]'; item rejected a.md; export SPY_UNREACT_RC=64
bash "$EV" rejected a.md
eq "backend without unreact (64): one attempt, logged once, exit 0" "0|2|1" \
  "$?|$(grep -c . "$SPY_ARGV")|$(grep -c 'unreact unsupported' "$EA_AGENT_DIR/state/slack-events.log")"
reset; config '["slack-react"]'; item incoming a.md; export SPY_REACT_RC=1
bash "$EV" detected a.md; eq "a failed reaction never fails the caller" "0" "$?"

echo "== target comes from the queue item only"
reset; config '["slack-react"]'; item incoming a.md
bash "$EV" detected "../../etc/a.md"; eq "a path is reduced to its basename under queue/" "react C1 1700000100.000200 eyes --json -w myco" "$(calls)"
reset; config '["slack-react"]'
bash "$EV" detected nope.md; eq "unknown item => no call" "" "$(calls)"
reset; config '["slack-react"]'; SRC=jira item incoming a.md
bash "$EV" detected a.md; eq "non-Slack item => no call" "" "$(calls)"
reset; config '["slack-react"]'; CH='C1 --thread x' item incoming a.md
bash "$EV" detected a.md; eq "malformed channel_id => no call" "" "$(calls)"
bash "$EV" bogus a.md >/dev/null 2>&1; eq "unknown event => usage exit 2" "2" "$?"
bash "$EV" detected 'a b' >/dev/null 2>&1; eq "invalid item name => usage exit 2" "2" "$?"

echo "== watched threads"
reset; config '[]'; item completed a.md
EA_NOW=1800000000 bash "$EV" posted a.md
eq "posted records the thread even without the reaction tier" $'C1\t1700000100.000200\t1800000000.000000\t1800000000\talpha' "$(cat "$W")"
reset; config '[]'; item completed b.md 'thread_ts: "1700000000.000001"'
EA_NOW=1800000000 bash "$EV" posted b.md
eq "a reply item watches its parent thread" "1700000000.000001" "$(cut -f2 "$W")"
EA_NOW=1800000500 bash "$EV" posted b.md
eq "re-posting upserts (one row, refreshed)" "1|1800000500" "$(grep -c . "$W")|$(cut -f4 "$W")"
printf 'C9\t1.000000\t1.000000\t%s\talpha\n' "$(( 1800000500 - 31 * 86400 ))" >> "$W"
EA_NOW=1800000500 bash "$EV" posted b.md
eq "rows past 30 days are dropped" "0" "$(grep -c '^C9' "$W")"
reset; config '[]'; item drafts a.md
bash "$EV" drafted a.md; eq "only posted registers a thread" "0" "$(cat "$W" 2>/dev/null | grep -c .)"

echo "== ea_slack_bin"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
eq "mcp-proxy uses the plugin's slack-mcp.sh" "$REPO_ROOT/scripts/slack-mcp.sh|-w|ws1" \
  "$( . "$REPO_ROOT/scripts/lib-paths.sh"; ea_slack_bin mcp-proxy ignored ws1; printf '%s|%s' "$SLACK_BIN" "$(IFS='|'; echo "${SLACK_WS[*]}")" )"
eq "otherwise agent.slack.bin, default spy, no workspace" "spy|" \
  "$( . "$REPO_ROOT/scripts/lib-paths.sh"; ea_slack_bin spy "" ""; printf '%s|%s' "$SLACK_BIN" "${SLACK_WS[*]-}" )"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
