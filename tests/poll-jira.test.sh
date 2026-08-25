#!/bin/bash
# Tests for scripts/poll-jira.sh — the deterministic Jira collector.
#
# `curl` is stubbed on PATH (following tests/cron-poll-scripted.test.sh, which stubs gh/claude the
# same way) so no network is touched and every response shape is chosen by the test.
#
# What is pinned here, and why each one matters:
#
#   1. THE TIMEZONE CONVERSION. A bare datetime in JQL is read in the ACCOUNT's Jira timezone, not
#      UTC, so handing a UTC watermark's clock digits to JQL shifts the window by the account
#      offset — six hours into the FUTURE for a Denver account. Every ticket updated during working
#      hours then falls before the cutoff and the poll queues nothing while reporting status: ok.
#      That is indistinguishable from a quiet day, which is what makes it worth a test rather than
#      a comment.
#   2. A FAILED TIMEZONE BOOTSTRAP MUST NOT DEFAULT TO UTC. Silently assuming +00:00 on an account
#      that is not UTC reintroduces (1) with no signal at all.
#   3. JQL QUOTING. An assignee is an email, and `@` is a reserved JQL character: unquoted, the
#      WHOLE query fails with Bad Request and the poll silently queues nothing.
#   4. KIND TIER 1 IS TERMINAL FOR JIRA. A Story titled "Add spike protection to the rate limiter"
#      must stay code work — decided by structure, not by a title keyword.
#   5. TERMINAL STATE IS ABSORBING. engineer-agent posting its own findings as a Jira comment bumps
#      `updated`, so a completed ticket that re-appears in the window must never be re-queued.
#   6. DEGRADATION IS CLEAN. No credential / no jq / a failed query all exit 3, which cron-poll.sh
#      reads as "leave this source to the model" — never a half-collected source.
#
# Run: bash tests/poll-jira.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLL="${REPO_ROOT}/scripts/poll-jira.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (poll-jira.sh degrades to the model without it)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state" "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# Fixtures the stub serves, and the logs it writes for assertions.
export TZ_JSON="$TMP/tz.json"
export SEARCH_JSON="$TMP/search.json"
export COMMENT_JSON="$TMP/comment.json"
export TZ_CODE="$TMP/tz.code";  echo 200 > "$TZ_CODE"
export SEARCH_CODE="$TMP/search.code"; echo 200 > "$SEARCH_CODE"
export CURL_ARGV="$TMP/curl.argv"
export CURL_STDIN="$TMP/curl.stdin"
export CURL_BODY="$TMP/curl.body"
echo '{"comments":[]}' > "$COMMENT_JSON"

cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out=""; url=""; body=""; prev=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;;
    --data-binary) body="$a" ;;
  esac
  case "$a" in https://*) url="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$*" >> "$CURL_ARGV"
cat >> "$CURL_STDIN"
printf '%s\n' "$body" >> "$CURL_BODY"

code=200
case "$url" in
  *"/search/jql"*)
    # NOTE the trailing comma: '"maxResults":1' is a SUBSTRING of '"maxResults":100', so without it
    # every search page is served the timezone fixture and the collector sees zero issues.
    if printf '%s' "$body" | grep -q '"maxResults":1,'; then
      cat "$TZ_JSON" > "$out"; code="$(cat "$TZ_CODE")"
    else
      cat "$SEARCH_JSON" > "$out"; code="$(cat "$SEARCH_CODE")"
    fi ;;
  *"/comment"*) cat "$COMMENT_JSON" > "$out" ;;
  *) echo '{}' > "$out"; code=404 ;;
esac
printf '%s' "$code"
EOF
chmod +x "$TMP/bin/curl"

write_config() {
  cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  jira:
    site: "example.atlassian.net"
    email: "me@example.com"
    api_token_env: "EA_TEST_JIRA_TOKEN"
  investigation:
    jira_types: ["Spike", "Decision"]
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "jira"
    jira:
      sources:
        - project: "ENG"
      assignee: "me@example.com"
      statuses: ["To Do", "In Progress"]
YAML
}

# Two projects watching the SAME key, which is the N:M case a real config actually has.
write_shared_config() {
  cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  jira:
    site: "example.atlassian.net"
    email: "me@example.com"
    api_token_env: "EA_TEST_JIRA_TOKEN"
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "jira"
    jira:
      sources:
        - project: "ENG"
          components: ["api"]
      assignee: "me@example.com"
      statuses: ["To Do"]
  beta:
    path: "/tmp/beta"
    tracker: "jira"
    jira:
      sources:
        - project: "ENG"
          components: ["ui"]
      assignee: "me@example.com"
      statuses: ["To Do"]
YAML
}

# issue <key> <summary> <issuetype> [components-json] [labels-json] [priority]
issue() {
  jq -nc --arg k "$1" --arg s "$2" --arg t "$3" \
        --argjson c "${4:-[]}" --argjson l "${5:-[]}" --arg p "${6:-Medium}" \
    '{key:$k, fields:{summary:$s, description:"A description.", issuetype:{name:$t},
      components:($c|map({name:.})), labels:$l, status:{name:"To Do"},
      priority:{name:$p}, updated:"2026-08-20T10:00:00.000-0600"}}'
}
set_issues() { jq -nc --argjson a "$1" '{issues:$a}' > "$SEARCH_JSON"; }

reset() {
  rm -f "$EA_AGENT_DIR"/queue/*/*.md "$EA_AGENT_DIR/state/last-poll.yaml" \
        "$CURL_ARGV" "$CURL_STDIN" "$CURL_BODY" "$TMP/manifest"
  : > "$TMP/manifest"
  echo 200 > "$TZ_CODE"; echo 200 > "$SEARCH_CODE"
  # A Denver account: the offset the collector must discover and apply.
  jq -nc '{issues:[{fields:{updated:"2026-08-20T10:00:00.000-0600"}}]}' > "$TZ_JSON"
  set_issues '[]'
}
run() { EA_TEST_JIRA_TOKEN="tok" bash "$POLL" --manifest "$TMP/manifest" "$@" 2>"$TMP/err"; }
item() { ls "$EA_AGENT_DIR/queue/incoming/"*"$1"* 2>/dev/null | head -1; }

echo "== degradation: no credential leaves the source to the model =="
write_config; reset
set_issues "[$(issue ENG-1 'A ticket' Story)]"
EA_TEST_JIRA_TOKEN="" bash "$POLL" --manifest "$TMP/manifest" >/dev/null 2>&1
eq "exit 3 (cron-poll reads this as: leave it to the model)" "3" "$?"
if [ -z "$(ls -A "$EA_AGENT_DIR/queue/incoming" 2>/dev/null)" ]; then ok "no items written"; else bad "must not write items without a credential"; fi

echo "== the credential never appears in argv =="
write_config; reset
set_issues "[$(issue ENG-1 'A ticket' Story)]"
run >/dev/null
if grep -q 'tok' "$CURL_ARGV"; then bad "credential leaked into curl argv (readable via ps)"; else ok "credential absent from argv"; fi
if grep -q 'tok' "$CURL_STDIN"; then ok "credential passed on stdin"; else bad "credential should be passed via --config -"; fi

echo "== JQL: the account offset is applied to the watermark =="
write_config; reset
mkdir -p "$EA_AGENT_DIR/state"
cat > "$EA_AGENT_DIR/state/last-poll.yaml" <<'YAML'
jira_projects:
  ENG:
    last_checked: "2026-08-20T14:03:03Z"
YAML
set_issues '[]'
run >/dev/null
# 14:03Z with a -06:00 account offset is 08:03 local. Feeding JQL the raw "14:03" would put the
# cutoff ~6h into the future and silently return nothing.
if grep -q 'updated > \\"2026-08-20 08:03\\"' "$CURL_BODY"; then ok "watermark converted to account-local wall clock"
else bad "cutoff not converted — got: $(grep -o 'updated > [^,]*' "$CURL_BODY" | head -1)"; fi

echo "== a failed timezone bootstrap must NOT silently assume UTC =="
write_config; reset
echo 500 > "$TZ_CODE"
set_issues "[$(issue ENG-1 'A ticket' Story)]"
run >/dev/null
eq "exit 3 rather than guessing the offset" "3" "$?"
if [ -z "$(ls -A "$EA_AGENT_DIR/queue/incoming" 2>/dev/null)" ]; then ok "no items written on a failed bootstrap"; else bad "must not collect with an unknown offset"; fi

echo "== JQL quoting: an assignee email contains a reserved character =="
write_config; reset
run >/dev/null
if grep -q 'assignee IN (\\"me@example.com\\")' "$CURL_BODY"; then ok "assignee is quoted"
else bad "unquoted assignee fails the WHOLE query with Bad Request"; fi
if grep -q 'status IN (\\"In Progress\\", \\"To Do\\")' "$CURL_BODY"; then ok "statuses quoted and unioned"
else bad "statuses not quoted/unioned — got: $(grep -o 'status IN ([^)]*)' "$CURL_BODY" | head -1)"; fi

echo "== a routed ticket is written with full frontmatter =="
write_config; reset
set_issues "[$(issue ENG-7 'Fix the thing' Story '["api"]' '["backend"]' High)]"
run >/dev/null
I="$(item ENG-7)"
if [ -n "$I" ]; then ok "queue item created"; else bad "no queue item"; fi
eq "type"             "ticket"       "$(grep -m1 '^type:' "$I" | sed 's/^type: *//')"
eq "source"           "jira"         "$(grep -m1 '^source:' "$I" | sed 's/^source: *//')"
eq "source_id"        "ENG-7"        "$(grep -m1 '^source_id:' "$I" | sed 's/^source_id: *"\(.*\)"/\1/')"
eq "project"          "alpha"        "$(grep -m1 '^project:' "$I" | sed 's/^project: *"\(.*\)"/\1/')"
eq "routing_method"   "single-candidate" "$(grep -m1 '^routing_method:' "$I" | sed 's/^routing_method: *"\(.*\)"/\1/')"
eq "jira_issue_type"  "Story"        "$(grep -m1 '^jira_issue_type:' "$I" | sed 's/^jira_issue_type: *"\(.*\)"/\1/')"
eq "jira_components"  '["api"]'      "$(grep -m1 '^jira_components:' "$I" | sed 's/^jira_components: *//')"
eq "jira_labels"      '["backend"]'  "$(grep -m1 '^jira_labels:' "$I" | sed 's/^jira_labels: *//')"
eq "priority mapped from High" "urgent" "$(grep -m1 '^priority:' "$I" | sed 's/^priority: *//')"
if grep -q '^## Context' "$I"; then ok "Context section present"; else bad "Context missing"; fi
if grep -q '^### Description' "$I"; then ok "Description section present"; else bad "Description missing"; fi
# The collector must NOT draft — that is the model's half of the split.
if grep -q '^## Draft Response' "$I"; then bad "collector must not draft"; else ok "no draft written (correct split)"; fi
if grep -q "	ticket	alpha	ENG-7	" "$TMP/manifest"; then ok "manifest row emitted"; else bad "manifest row missing"; fi

echo "== kind Tier 1 is TERMINAL for Jira =="
write_config; reset
set_issues "[$(issue ENG-8 'Spike: cache invalidation' Spike)]"
run >/dev/null
I="$(item ENG-8)"
eq "Spike issue type => investigation" "ticket-investigation" "$(grep -m1 '^type:' "$I" | sed 's/^type: *//')"
eq "method recorded"  "jira-issuetype" "$(grep -m1 '^ticket_kind_method:' "$I" | sed 's/^ticket_kind_method: *"\(.*\)"/\1/')"

write_config; reset
# The false positive the terminal tier exists to prevent: a title full of the word "spike" on a
# Story is code work, decided by structure rather than by luck.
set_issues "[$(issue ENG-9 'Add spike protection to the rate limiter' Story)]"
run >/dev/null
I="$(item ENG-9)"
eq "Story with a spike-shaped title stays code work" "ticket" "$(grep -m1 '^type:' "$I" | sed 's/^type: *//')"
eq "needs_kind_check is 0 for Jira" "0" "$(awk -F'\t' '/ENG-9/ {print $7}' "$TMP/manifest")"

echo "== terminal state is absorbing =="
write_config; reset
set_issues "[$(issue ENG-10 'Already done' Story)]"
run >/dev/null
mv "$(item ENG-10)" "$EA_AGENT_DIR/queue/completed/"
run > "$TMP/out2"
if [ -z "$(ls -A "$EA_AGENT_DIR/queue/incoming" 2>/dev/null)" ]; then ok "completed ticket not re-queued"; else bad "re-queued a completed ticket (the self-sustaining comment loop)"; fi
if grep -q 'Skipped (terminal): ENG-10' "$TMP/out2"; then ok "skip is REPORTED, not hidden as 0 new"; else bad "skipped ids must be reported"; fi

echo "== a completed investigation absorbs a rival ticket (one source_id family) =="
write_config; reset
set_issues "[$(issue ENG-11 'Spike: pick a queue' Spike)]"
run >/dev/null
mv "$(item ENG-11)" "$EA_AGENT_DIR/queue/completed/"
# The ticket is retyped to a Story: a naive (type, source_id) key would mint a rival live item for
# work already finished, because the type half of the key changed underneath the absorbing rule.
set_issues "[$(issue ENG-11 'Pick a queue backend' Story)]"
run >/dev/null
if [ -z "$(ls -A "$EA_AGENT_DIR/queue/incoming" 2>/dev/null)" ]; then ok "retyped ticket absorbed by the completed investigation"; else bad "family-wide lookup failed — rival item created"; fi

echo "== shared key: Tier 2 component filters decide, ambiguity goes _unrouted =="
write_shared_config; reset
set_issues "[$(issue ENG-20 'Backend work' Story '["api"]')]"
run >/dev/null
I="$(item ENG-20)"
eq "component filter routes to alpha" "alpha" "$(grep -m1 '^project:' "$I" | sed 's/^project: *"\(.*\)"/\1/')"
eq "method is filters" "filters" "$(grep -m1 '^routing_method:' "$I" | sed 's/^routing_method: *"\(.*\)"/\1/')"

write_shared_config; reset
# Matches BOTH watchers: ambiguity must fall through to _unrouted, never to a coin flip.
set_issues "[$(issue ENG-21 'Cross-cutting' Story '["api","ui"]')]"
run >/dev/null
I="$(item ENG-21)"
eq "ambiguous ticket is _unrouted" "_unrouted" "$(grep -m1 '^project:' "$I" | sed 's/^project: *"\(.*\)"/\1/')"
if grep -q '^matched_projects: \["alpha", "beta"\]' "$I"; then ok "matched_projects recorded"; else bad "matched_projects missing: $(grep '^matched_projects' "$I")"; fi
# An _unrouted item is classified LATE: the kind lists are per-project, so there is no slug yet.
if grep -q '^ticket_kind_method:' "$I"; then bad "unrouted item must not carry a kind method"; else ok "kind deferred for _unrouted"; fi

echo "== state =="
write_config; reset
run >/dev/null
if grep -q 'ENG' "$EA_AGENT_DIR/state/last-poll.yaml" 2>/dev/null; then ok "per-key cutoff advances on a zero-ticket poll"; else bad "cutoff must advance even when nothing was found"; fi

write_config; reset
echo 500 > "$SEARCH_CODE"
run >/dev/null
rc=$?
eq "a failed query exits 3" "3" "$rc"
if grep -q 'last_checked' "$EA_AGENT_DIR/state/last-poll.yaml" 2>/dev/null; then
  bad "cutoff must NOT advance after a failed query (it would drop that window forever)"
else ok "cutoff left unchanged after a failed query"; fi

echo "== resume sweep: an undrafted incoming/ item is re-emitted =="
write_config; reset
set_issues "[$(issue ENG-30 'Stranded' Story)]"
run >/dev/null
: > "$TMP/manifest"
set_issues '[]'
run >/dev/null
if grep -q "^resume	.*ENG-30" "$TMP/manifest"; then ok "stranded item re-emitted (self-healing)"; else bad "an undrafted incoming/ item is invisible to every approval path"; fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
