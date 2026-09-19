#!/bin/bash
# Tests for scripts/poll-slack.sh — the deterministic Slack collector, and scripts/lib-typesafe.sh
# under it.
#
# Both external services are stubbed on PATH: `spy` serves channel reads and thread reads, `curl`
# serves the TypeSafe judgment. No network is touched and every probability is chosen here, which
# is the point — the whole reason the relevance decision is four numbers composed in bash rather
# than one model's prose verdict is that the composition can be tested without a model.
#
# What is pinned, and why each one is a thing that could silently break:
#   • DOUBLE OPT-IN. No TypeSafe key => exit 3 and nothing written. This is the user-facing promise
#     that enabling `slack` in scripted_sources cannot, by itself, start sending Slack text anywhere.
#   • The API key never appears in argv (this runs unattended every 15 minutes; `ps` is public).
#   • Threshold composition, in both directions, one question at a time.
#   • A failed judgment does NOT become a silent "no", and does NOT advance the cutoff past the
#     message it failed on — otherwise a transient error eats messages invisibly.
#   • ONE READ PER CHANNEL, routed. Two projects sharing a channel must produce an _unrouted item,
#     not an arbitrary winner (the shared-repo trap, third costume).
#   • Terminal state is absorbing, and a zero-message poll leaves last_checked_ts alone.
#
# Run: bash tests/poll-slack.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLL="${REPO_ROOT}/scripts/poll-slack.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (poll-slack.sh degrades to the model without it)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state" "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# `security` MUST be shimmed, for the same reason poll-slite.test.sh shims it: ea_secret_resolve
# falls through env -> file -> macOS login keychain, so without this the "no key" case finds the
# DEVELOPER'S REAL engineer-agent-typesafe credential and the collector correctly proceeds — making
# the degradation assertions fail on exactly the machines the plugin is developed on.
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"

export READ_JSON="$TMP/read.json";     echo '[]' > "$READ_JSON"
export THREAD_JSON="$TMP/thread.json"; echo '[]' > "$THREAD_JSON"
export SPY_ARGV="$TMP/spy.argv"
export SPY_EXIT="$TMP/spy.exit";       echo 0 > "$SPY_EXIT"
export ANSWERS="$TMP/answers.json"
export TS_CODE="$TMP/ts.code";         echo 200 > "$TS_CODE"
export CURL_ARGV="$TMP/curl.argv"
export CURL_STDIN="$TMP/curl.stdin"
export CURL_BODY="$TMP/curl.body"

cat > "$TMP/bin/spy" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SPY_ARGV"
rc="$(cat "$SPY_EXIT")"
[ "$rc" != "0" ] && exit "$rc"
case "${1:-}" in
  read)   cat "$READ_JSON" ;;
  thread) cat "$THREAD_JSON" ;;
  *)      echo '[]' ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/spy"

cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out=""; prev=""; body=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; esac
  case "$a" in --data-binary) : ;; @*) body="${a#@}" ;; esac
  prev="$a"
done
printf '%s\n' "$*" >> "$CURL_ARGV"
cat >> "$CURL_STDIN"
[ -n "$body" ] && cat "$body" > "$CURL_BODY"
cat "$ANSWERS" > "$out"
printf '%s' "$(cat "$TS_CODE")"
EOF
chmod +x "$TMP/bin/curl"

# answers <question> <directed> <answered> <engineer>
answers() {
  jq -nc --argjson q "$1" --argjson d "$2" --argjson a "$3" --argjson e "$4" \
    '{model:"jev-latest", answers:{
       is_question:{type:"noul",noul:$q}, directed_at_user:{type:"noul",noul:$d},
       already_answered:{type:"noul",noul:$a}, needs_engineer:{type:"noul",noul:$e}},
      usage:{input_tokens:1,output_tokens:1}}' > "$ANSWERS"
}

# msgs <json-array>
msgs() { printf '%s' "$1" > "$READ_JSON"; }

write_config() {   # one project watching one channel
  cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  slack:
    workspace: "myco"
    user_id: "UME"
    user_name: "Tom"
  typesafe:
    api_key_env: "EA_TEST_TS_KEY"
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "none"
    slack:
      channels: ["C1"]
      keywords: ["deploy"]
      ignore_bots: true
YAML
}

write_shared_config() {   # two projects, SAME channel, different keywords
  cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  slack:
    workspace: "myco"
  typesafe:
    api_key_env: "EA_TEST_TS_KEY"
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "none"
    slack:
      channels: ["C1"]
      keywords: ["deploy"]
  beta:
    path: "/tmp/beta"
    tracker: "none"
    slack:
      channels: ["C1"]
      keywords: ["deploy"]
YAML
}

reset() {
  rm -f "$EA_AGENT_DIR"/queue/*/*.md "$EA_AGENT_DIR/state/last-poll.yaml" \
        "$SPY_ARGV" "$CURL_ARGV" "$CURL_STDIN" "$CURL_BODY"
  : > "$TMP/manifest"; echo 0 > "$SPY_EXIT"; echo 200 > "$TS_CODE"
  echo '[]' > "$THREAD_JSON"
  answers 0.95 0.92 0.02 0.90
}
run()  { EA_TEST_TS_KEY="tskey" bash "$POLL" --manifest "$TMP/manifest" "$@" 2>"$TMP/err"; }
item() { ls "$EA_AGENT_DIR/queue/incoming/"*slack-question* 2>/dev/null | head -1; }
fmv()  { sed -n "s/^$2: //p" "$1" | head -1 | tr -d '"'; }
nitems() { ls "$EA_AGENT_DIR/queue/incoming/"*slack-question* 2>/dev/null | wc -l | tr -d ' '; }

Q='[{"ts":"1700000100.000100","user_id":"U1","user_name":"Ann","reply_count":0,"thread_ts":null,"text":"how does the deploy pipeline pick a base image?"}]'

echo "== double opt-in: the TypeSafe key is a hard gate =="
write_config; reset; msgs "$Q"
EA_TEST_TS_KEY="" bash "$POLL" --manifest "$TMP/manifest" >/dev/null 2>&1
eq "no TypeSafe key => exit 3 (Slack stays model-driven)" "3" "$?"
eq "nothing written without a key" "0" "$(nitems)"
if [ -s "$SPY_ARGV" ]; then bad "Slack must not be read at all when the judgment is unavailable"; else ok "no Slack read attempted"; fi

echo "== the API key never appears in argv =="
write_config; reset; msgs "$Q"
run >/dev/null
if grep -q 'Bearer tskey' "$CURL_ARGV"; then bad "API key leaked into argv"; else ok "key absent from argv"; fi
if grep -q 'Bearer tskey' "$CURL_STDIN"; then ok "key passed on stdin via --config -"; else bad "key should go via --config -"; fi

echo "== a relevant message becomes a slack-question item =="
write_config; reset; msgs "$Q"
run >/dev/null
f="$(item)"
if [ -n "$f" ]; then ok "item written"; else bad "no item written"; fi
if [ -n "$f" ]; then
  eq "type"           "slack-question"            "$(fmv "$f" type)"
  eq "source"         "slack"                     "$(fmv "$f" source)"
  eq "source_id"      "C1:1700000100.000100"      "$(fmv "$f" source_id)"
  eq "project"        "alpha"                     "$(fmv "$f" project)"
  eq "routing_method" "single-candidate"          "$(fmv "$f" routing_method)"
  eq "relevance_method" "typesafe"                "$(fmv "$f" relevance_method)"
  # The probabilities are recorded so the approval gate can audit the decision, not just its result.
  if grep -q 'relevance_scores: "question=0.95 directed=0.92 answered=0.02 engineer=0.90"' "$f"; then
    ok "relevance_scores recorded"
  else bad "relevance_scores missing/mangled: $(fmv "$f" relevance_scores)"; fi
  grep -q 'https://myco.slack.com/archives/C1/p1700000100000100' "$f" && ok "permalink built" || bad "permalink wrong"
fi
grep -q $'draft\t.*\tslack-question\talpha\tC1:1700000100.000100\t0\t0\t' "$TMP/manifest" \
  && ok "manifest row" || bad "manifest row wrong: $(cat "$TMP/manifest")"

echo "== the message text is the STATE, and the questions are ours =="
write_config; reset; msgs "$Q"
run >/dev/null
if jq -e '.state.message.text | test("base image")' "$CURL_BODY" >/dev/null 2>&1; then
  ok "message text sent as state"
else bad "message text missing from state"; fi
if jq -e '(.questions | keys | sort) == ["already_answered","directed_at_user","is_question","needs_engineer"]' "$CURL_BODY" >/dev/null 2>&1; then
  ok "exactly the four questions, batched in one request"
else bad "question set wrong: $(jq -c '.questions | keys' "$CURL_BODY" 2>/dev/null)"; fi
eq "one request for four questions" "1" "$(grep -c . "$CURL_ARGV")"

echo "== threshold composition, one dimension at a time =="
# Each of these is a message that a keyword filter alone would have queued. That is the point:
# the keyword filter is unchanged, and these are the false positives it cannot see.
for spec in "0.20 0.92 0.02 0.90 not-a-question" \
            "0.95 0.10 0.02 0.90 aimed-at-the-channel" \
            "0.95 0.92 0.95 0.90 already-answered" \
            "0.95 0.92 0.02 0.10 not-an-engineering-question"; do
  set -- $spec
  write_config; reset; msgs "$Q"; answers "$1" "$2" "$3" "$4"
  run >/dev/null
  eq "filtered: $5" "0" "$(nitems)"
done
write_config; reset; msgs "$Q"; answers 0.61 0.56 0.39 0.51
run >/dev/null
eq "just inside every threshold => queued" "1" "$(nitems)"

echo "== thresholds are configurable =="
write_config; reset; msgs "$Q"
cat >> "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
YAML
python3 - "$EA_AGENT_DIR/engineer.yaml" <<'PY' 2>/dev/null || true
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('    api_key_env: "EA_TEST_TS_KEY"',
            '    api_key_env: "EA_TEST_TS_KEY"\n    slack:\n      min_directed: 0.99')
open(p,'w').write(s)
PY
answers 0.95 0.92 0.02 0.90
run >/dev/null
eq "raising min_directed filters a message that passed the default" "0" "$(nitems)"

echo "== a failed judgment is not a silent no =="
write_config; reset; msgs "$Q"
echo 500 > "$TS_CODE"
run >/dev/null; rc=$?
eq "API failure => exit 3 (hand Slack back to the model)" "3" "$rc"
eq "nothing queued on a failed judgment" "0" "$(nitems)"
# The cutoff must NOT move: exit 3 hands Slack to the model, and an advanced cutoff would hide the
# message from that fallback too — a transient error would silently eat everything around it.
if [ -f "$EA_AGENT_DIR/state/last-poll.yaml" ] && grep -q last_checked_ts "$EA_AGENT_DIR/state/last-poll.yaml"; then
  bad "cutoff advanced on an errored run"
else ok "cutoff left alone on an errored run"; fi

echo "== a malformed threshold falls back to the shipped default =="
write_config; reset; msgs "$Q"
python3 - "$EA_AGENT_DIR/engineer.yaml" <<'PY' 2>/dev/null || true
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('    api_key_env: "EA_TEST_TS_KEY"',
            '    api_key_env: "EA_TEST_TS_KEY"\n    slack:\n      min_directed: "high"')
open(p,'w').write(s)
PY
run >/dev/null
# A non-numeric threshold compared by awk would be 0, making every comparison false and the
# collector silently find nothing — the Jira-timezone failure shape. It must degrade to the default.
eq "non-numeric threshold => default applies, message still queued" "1" "$(nitems)"

echo "== keyword filter is whole-word and runs before any judgment =="
write_config; reset
msgs '[{"ts":"1700000200.000100","user_id":"U1","user_name":"Ann","reply_count":0,"thread_ts":null,"text":"redeployment of the CDN is done"}]'
run >/dev/null
eq "substring 'deploy' inside 'redeployment' does not match" "0" "$(nitems)"
if [ -s "$CURL_ARGV" ]; then bad "must not pay for a judgment on a message no keyword matched"; else ok "no judgment requested"; fi

echo "== the user's own messages are dropped for free =="
write_config; reset
msgs '[{"ts":"1700000300.000100","user_id":"UME","user_name":"Tom","reply_count":0,"thread_ts":null,"text":"the deploy pipeline is fixed"}]'
run >/dev/null
eq "own message not queued" "0" "$(nitems)"
if [ -s "$CURL_ARGV" ]; then bad "must not pay for a judgment on your own message"; else ok "no judgment requested"; fi

echo "== bot messages are dropped when ignore_bots is true =="
write_config; reset
msgs '[{"ts":"1700000400.000100","user_id":"B99","user_name":"Deploybot","reply_count":0,"thread_ts":null,"text":"deploy finished"}]'
run >/dev/null
eq "B-prefixed author dropped" "0" "$(nitems)"

echo "== thread context is fetched only for surviving candidates, and sent as evidence =="
write_config; reset
msgs '[{"ts":"1700000500.000100","user_id":"U1","user_name":"Ann","reply_count":2,"thread_ts":"1700000500.000100","text":"who owns the deploy pipeline?"}]'
printf '%s' '[{"ts":"1700000500.000200","user_id":"U2","user_name":"Bo","reply_count":0,"thread_ts":null,"text":"I think Tom does"}]' > "$THREAD_JSON"
run >/dev/null
grep -q '^thread ' "$SPY_ARGV" && ok "thread read once" || bad "thread not read: $(cat "$SPY_ARGV")"
jq -e '.state.thread | length > 0' "$CURL_BODY" >/dev/null 2>&1 && ok "thread sent as state" || bad "thread missing from state"
f="$(item)"; [ -n "$f" ] && grep -q '### Thread Context' "$f" && ok "thread rendered in the item" || bad "thread context missing from item"

echo "== one read per channel, routed (the shared-channel trap) =="
write_shared_config; reset; msgs "$Q"
run >/dev/null
eq "channel read exactly once for two watchers" "1" "$(grep -c '^read ' "$SPY_ARGV")"
eq "one item, not one per project" "1" "$(nitems)"
f="$(item)"
eq "ambiguous => _unrouted, never an arbitrary winner" "_unrouted" "$(fmv "$f" project)"
grep -q 'matched_projects: \["alpha", "beta"\]' "$f" && ok "candidates recorded for review-queue" || bad "matched_projects missing"
# needs_routing is 0 here, and that is the ladder working: Tier 3b is skipped ENTIRELY when no
# candidate carries a routing block, so an install that never adds hints behaves exactly as it did
# before the ladder existed. The item is still _unrouted and still reachable — review-queue
# surfaces _unrouted items from incoming/ for a human to assign.
grep -q $'\t_unrouted\t.*\t0\t0\t' "$TMP/manifest" \
  && ok "no routing hints => Tier 3b not requested, human resolves it" \
  || bad "needs_routing wrong: $(cat "$TMP/manifest")"

echo "== ... and Tier 3b IS requested when a candidate carries routing hints =="
write_shared_config; reset; msgs "$Q"
python3 - "$EA_AGENT_DIR/engineer.yaml" <<'PY' 2>/dev/null || true
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('''  beta:
    path: "/tmp/beta"''','''  beta:
    path: "/tmp/beta"
    routing:
      description: "the deployment pipeline and its base images"''')
open(p,'w').write(s)
PY
run >/dev/null
grep -q $'\t_unrouted\t.*\t1\t0\t' "$TMP/manifest" \
  && ok "needs_routing=1 flagged for the model's Tier 3b" \
  || bad "needs_routing not flagged: $(cat "$TMP/manifest")"

echo "== terminal state is absorbing =="
write_config; reset; msgs "$Q"
run >/dev/null
f="$(item)"; mv "$f" "$EA_AGENT_DIR/queue/completed/"
rm -f "$EA_AGENT_DIR/state/last-poll.yaml"
run >/dev/null
eq "a completed message is not re-queued" "0" "$(nitems)"

echo "== zero-message poll leaves the cutoff alone =="
write_config; reset; msgs '[]'
run >/dev/null; rc=$?
eq "exit 0 on a quiet channel" "0" "$rc"
if [ -f "$EA_AGENT_DIR/state/last-poll.yaml" ] && grep -q last_checked_ts "$EA_AGENT_DIR/state/last-poll.yaml"; then
  bad "cutoff must not advance when no message was read (it is a message ts, not a clock)"
else ok "cutoff unchanged"; fi

echo "== the cutoff advances past judged-irrelevant messages =="
write_config; reset; msgs "$Q"; answers 0.05 0.05 0.02 0.05
run >/dev/null
eq "cutoff advances past a rejected message" "1700000100.000100" \
   "$(sed -n 's/.*last_checked_ts: //p' "$EA_AGENT_DIR/state/last-poll.yaml" | tr -d '"')"
# Deliberately NOT reset() — that deletes last-poll.yaml, and the cutoff written above is the whole
# subject of this assertion. Clear only the request log.
: > "$CURL_ARGV"
run >/dev/null
eq "and it is not re-judged next tick" "0" "$(grep -c . "$CURL_ARGV")"

echo "== token expiry (exit 75) is a clean skip, not an error =="
write_config; reset; msgs "$Q"
echo 75 > "$SPY_EXIT"
run >/dev/null; rc=$?
eq "exit 0 on an expired Slack token" "0" "$rc"
if [ -f "$EA_AGENT_DIR/state/last-poll.yaml" ] && grep -q last_checked_ts "$EA_AGENT_DIR/state/last-poll.yaml"; then
  bad "cutoff must not advance when no channel was read"
else ok "cutoff unchanged on a token skip"; fi

echo "== unrecognised read shape is not 'no questions today' =="
write_config; reset
printf '%s' '{"unexpected":"shape"}' > "$READ_JSON"
run >/dev/null
eq "unknown response shape => exit 3" "3" "$?"

echo
echo "poll-slack.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
