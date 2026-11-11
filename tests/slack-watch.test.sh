#!/bin/bash
# Tests for the slack/watch job's `mentions` and `my-threads` sources (scripts/job-slack-watch.sh →
# scripts/poll-slack.sh), plus the `detected` reaction a collector fires on create.
#
# `spy` (search/thread/react) and `curl` (the TypeSafe judgment) are PATH stubs.
#
# Run: bash tests/slack-watch.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JOB="${REPO_ROOT}/scripts/job-slack-watch.sh"
POLL="${REPO_ROOT}/scripts/poll-slack.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state/jobs" "$TMP/bin"
export PATH="$TMP/bin:$PATH"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"

export SEARCH_JSON="$TMP/search.json" THREAD_JSON="$TMP/thread.json" SPY_ARGV="$TMP/spy.argv"
export ANSWERS="$TMP/answers.json" TS_CODE="$TMP/ts.code" CURL_ARGV="$TMP/curl.argv"
cat > "$TMP/bin/spy" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SPY_ARGV"
case "${1:-}" in
  search) [ -n "${SPY_SEARCH_RC:-}" ] && exit "$SPY_SEARCH_RC"; cat "$SEARCH_JSON" ;;
  thread) cat "$THREAD_JSON" ;;
  react|unreact) : ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$TMP/bin/spy"
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out=""; prev=""
for a in "$@"; do case "$prev" in -o) out="$a" ;; esac; prev="$a"; done
printf '%s\n' "$*" >> "$CURL_ARGV"; cat >/dev/null
cat "$ANSWERS" > "$out"; printf '%s' "$(head -1 "$TS_CODE")"
[ "$(grep -c . "$TS_CODE")" -gt 1 ] && { tail -n +2 "$TS_CODE" > "$TS_CODE.n"; mv "$TS_CODE.n" "$TS_CODE"; }
exit 0
EOF
chmod +x "$TMP/bin/curl"

answers() {   # answers <question> <directed> <answered> <engineer>
  jq -nc --argjson q "$1" --argjson d "$2" --argjson a "$3" --argjson e "$4" \
    '{answers:{is_question:{type:"noul",noul:$q}, directed_at_user:{type:"noul",noul:$d},
      already_answered:{type:"noul",noul:$a}, needs_engineer:{type:"noul",noul:$e}}}' > "$ANSWERS"
}

# config <alpha watch list> [beta watch list] [auto_execute]
config() {
  {
    cat <<YAML
agent:
  autonomy:
    auto_execute: ${3:-[]}
  slack:
    workspace: "myco"
    user_id: "UME"
    user_name: "Tom"
    reactions:
      detected: eyes
  typesafe:
    api_key_env: "EA_TEST_TS_KEY"
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "none"
    slack:
      channels: ["C1"]
      keywords: ["deploy"]
    jobs:
      - id: sw
        integration: slack
        action: watch
        every: 5m
        watch: $1
        thread_ttl: 2d
YAML
    if [ -n "${2:-}" ]; then
      cat <<YAML
  beta:
    path: "/tmp/beta"
    tracker: "none"
    jobs:
      - id: sw
        integration: slack
        action: watch
        every: 5m
        watch: $2
YAML
    fi
  } > "$EA_AGENT_DIR/engineer.yaml"
}

STATE="$EA_AGENT_DIR/state/jobs/alpha.sw.state.yaml"
W="$EA_AGENT_DIR/state/watched-threads.tsv"
reset() {
  rm -f "$EA_AGENT_DIR"/queue/*/*.md "$STATE" "$W" "$SPY_ARGV" "$CURL_ARGV"
  : > "$TMP/manifest"; echo 200 > "$TS_CODE"; echo '[]' > "$THREAD_JSON"
  echo '{"query":"","total":0,"hits":[]}' > "$SEARCH_JSON"
  answers 0.95 0.92 0.02 0.90; unset SPY_SEARCH_RC
}
run_job() { EA_TEST_TS_KEY="tskey" bash "$JOB" --project alpha --job alpha.sw --manifest "$TMP/manifest" --errors "$TMP/errors" >/dev/null 2>"$TMP/err"; }
items() { ls "$EA_AGENT_DIR/queue/incoming/"*slack-question* 2>/dev/null; }
nitems() { items | grep -c .; }
fmv() { sed -n "s/^$2: //p" "$1" | head -1 | tr -d '"'; }
hits() {   # hits <json objects...>
  jq -sc '{query:"q", total:length, hits:.}' <<< "$*" > "$SEARCH_JSON"
}
hit() {   # hit <ts> <user> [permalink]
  jq -nc --arg t "$1" --arg u "$2" --arg p "${3:-}" \
    '{ts:$t, user_id:$u, user_name:"Ann", channel_id:"C7", channel_name:"eng", text:"<@UME> can you check the deploy config?", permalink:$p}'
}
# A cutoff a fixed day in the past keeps `after:` deterministic.
seed_cutoff() { printf 'projects:\n  alpha:\n    slack:\n      mentions_ts: "%s"\n' "$1" > "$STATE"; }

echo "== mentions"
config "[mentions]"; reset; seed_cutoff 1700000000.000000
hits "$(hit 1700000100.000100 U1)"
run_job; rc=$?
eq "a mention from someone else is queued" "0|1" "$rc|$(nitems)"
f="$(items | head -1)"
eq "item fields" "C7:1700000100.000100|alpha|single-candidate|mentions" \
  "$(fmv "$f" source_id)|$(fmv "$f" project)|$(fmv "$f" routing_method)|$(fmv "$f" watch_source)"
eq "search names the user and a day-granular lower bound" "search <@UME> after:2023-11-13 50 --json -w myco" "$(grep '^search' "$SPY_ARGV")"
eq "the mention's thread is read for context" "thread C7 1700000100.000100 --json -w myco" "$(grep '^thread' "$SPY_ARGV")"
eq "cutoff advances to the newest hit" "1700000100.000100" "$(sed -n 's/.*mentions_ts: //p' "$STATE" | tr -d '"')"

config "[mentions]"; reset; seed_cutoff 1700000100.000100
hits "$(hit 1700000100.000100 U1)" "$(hit 1700000050.000000 U1)"
run_job; eq "hits at or below the cutoff are not reconsidered" "0" "$(nitems)"

config "[mentions]"; reset; seed_cutoff 1700000000.000000
hits "$(hit 1700000100.000100 UME)"
run_job; eq "the user's own message is ignored" "0" "$(nitems)"

config "[mentions]"; reset; seed_cutoff 1700000000.000000
hits "$(hit 1700000100.000100 U1 'https://myco.slack.com/archives/C7/p1700000100000100?thread_ts=1700000090.000001&cid=C7')"
run_job; f="$(items | head -1)"
eq "a reply mention records its thread parent" "1700000090.000001" "$(fmv "$f" thread_ts)"
eq "and reads that thread" "thread C7 1700000090.000001 --json -w myco" "$(grep '^thread' "$SPY_ARGV")"
grep -q 'p1700000100000100?thread_ts=1700000090.000001&cid=C7' "$f" && ok "permalink points into the thread" || bad "permalink lacks thread_ts"

config "[mentions]"; reset; seed_cutoff 1700000000.000000; answers 0.95 0.10 0.02 0.90
hits "$(hit 1700000100.000100 U1)"
run_job; eq "directed_at_user is still thresholded for mentions" "0" "$(nitems)"

config "[mentions]"; reset; seed_cutoff 1700000000.000000; echo 500 > "$TS_CODE"
hits "$(hit 1700000100.000100 U1)"
run_job; rc=$?
eq "a failed judgment: exit 3, cutoff unchanged" "3|1700000000.000000" "$rc|$(sed -n 's/.*mentions_ts: //p' "$STATE" | tr -d '"')"

config "[mentions]"; reset; seed_cutoff 1700000000.000000; printf '200\n500\n' > "$TS_CODE"
hits "$(hit 1700000200.000000 U1)" "$(hit 1700000100.000100 U2)"
run_job
eq "one failed judgment holds the cutoff even past a hit that was judged" "1|1700000000.000000" \
  "$(nitems)|$(sed -n 's/.*mentions_ts: //p' "$STATE" | tr -d '"')"

config "[mentions]"; reset; seed_cutoff 1700000000.000000; export SPY_SEARCH_RC=64
run_job; eq "a backend without search: skipped, not an error" "0|0" "$?|$(nitems)"

config "[mentions]" "[mentions]"; reset; seed_cutoff 1700000000.000000
hits "$(hit 1700000100.000100 U1)"
run_job; f="$(items | head -1)"
eq "two projects watching mentions => _unrouted, not an arbitrary winner" "_unrouted" "$(fmv "$f" project)"

config "[mentions]"; reset; seed_cutoff 1700000000.000000
hits "$(hit 9999999999.000000 U1)"
run_job; eq "a future-dated hit is ignored and does not move the cutoff" "0|1700000000.000000" \
  "$(nitems)|$(sed -n 's/.*mentions_ts: //p' "$STATE" | tr -d '"')"
config "[mentions]"; reset; seed_cutoff 1700000000.000000
hits "$(hit 1700000100.000100 U1 'https://myco.slack.com/archives/C999/p1700000100000100')"
run_job; eq "a hit whose permalink names another message is ignored" "0" "$(nitems)"

EA_TEST_TS_KEY=tskey bash "$POLL" --sources mentions >/dev/null 2>&1
eq "mentions without --project is a usage error" "2" "$?"

echo "== my-threads"
thread() {   # parent by UME's teammate, our answer, then a follow-up
  jq -nc --arg r "${1:-U1}" '[
    {ts:"1700000000.000001", user_id:"U1", user_name:"Ann", reply_count:3, text:"q"},
    {ts:"1700000500.000000", user_id:"UME", user_name:"Tom", reply_count:0, text:"answer"},
    {ts:"1700000600.000000", user_id:$r, user_name:"Ann", reply_count:0, text:"thanks, but does that cover staging?"}]' > "$THREAD_JSON"
}
watch_row() { printf 'C1\t1700000000.000001\t%s\t%s\t%s\n' "$1" "$2" "${3:-alpha}" >> "$W"; }
NOW=1800000000

config "[my-threads]"; reset; thread; watch_row 1700000400.000000 "$NOW"; answers 0.95 0.05 0.02 0.90
EA_NOW=$NOW run_job; rc=$?
eq "a new reply from someone else is queued, even when not 'directed'" "0|1" "$rc|$(nitems)"
f="$(items | head -1)"
eq "item replies in the watched thread" "C1:1700000600.000000|1700000000.000001|my-threads|alpha" \
  "$(fmv "$f" source_id)|$(fmv "$f" thread_ts)|$(fmv "$f" watch_source)|$(fmv "$f" project)"
eq "last_seen advances to the newest reply" "1700000600.000000" "$(cut -f3 "$W")"

config "[my-threads]"; reset; thread UME; watch_row 1700000400.000000 "$NOW"
EA_NOW=$NOW run_job; eq "own replies and the parent are not candidates" "0" "$(nitems)"

config "[my-threads]"; reset; thread; watch_row 1700000600.000000 "$NOW"
EA_NOW=$NOW run_job; eq "replies at or before last_seen are ignored" "0|" "$(nitems)|$(cat "$CURL_ARGV" 2>/dev/null)"

config "[my-threads]"; reset; thread; watch_row 1700000400.000000 "$NOW"; echo 500 > "$TS_CODE"
EA_NOW=$NOW run_job; eq "a failed judgment leaves last_seen alone" "1700000400.000000" "$(cut -f3 "$W")"

config "[my-threads]"; reset; thread
watch_row 1700000400.000000 $(( NOW - 3 * 86400 ))
watch_row 1700000400.000000 $(( NOW - 3 * 86400 )) beta
EA_NOW=$NOW run_job
eq "rows past thread_ttl (2d) are pruned, unread; other projects' rows kept" "0|beta|" \
  "$(nitems)|$(cut -f5 "$W" | paste -sd, -)|$(grep '^thread' "$SPY_ARGV" 2>/dev/null)"

config "[my-threads]"; reset; thread; watch_row 1700000400.000000 "$NOW" beta
EA_NOW=$NOW run_job; eq "another project's watched thread is not read" "0|" "$(nitems)|$(grep '^thread' "$SPY_ARGV" 2>/dev/null)"

echo "== detected reaction"
config "[mentions]" "" '["slack-react"]'; reset; seed_cutoff 1700000000.000000
hits "$(hit 1700000100.000100 U1)"
run_job; eq "a created item gets the detected reaction" "react C7 1700000100.000100 eyes --json -w myco" "$(grep '^react' "$SPY_ARGV")"
config "[mentions]" "[mentions]" '["slack-react"]'; reset; seed_cutoff 1700000000.000000
hits "$(hit 1700000100.000100 U1)"
run_job; : > "$SPY_ARGV"; seed_cutoff 1700000000.000000
run_job; eq "an _unrouted item updated in place is not re-signalled" "1|" "$(nitems)|$(grep '^react' "$SPY_ARGV")"
config "[mentions]"; reset; seed_cutoff 1700000000.000000
hits "$(hit 1700000100.000100 U1)"
run_job; eq "no slack-react tier => no reaction" "" "$(grep '^react' "$SPY_ARGV")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
