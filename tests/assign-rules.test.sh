#!/bin/bash
# Tests for scripts/lib-assign-rules.sh — rule validation, predicates, and first-match selection
# for jira:implement-next. curl and security are stubbed; the clock is frozen with EA_NOW.
#
# Run: bash tests/assign-rules.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state" "$TMP/bin" "$TMP/fx"
export PATH="$TMP/bin:$PATH"
export EA_NOW=1762790400            # 2025-11-10T16:00:00Z
export EA_TEST_JIRA_TOKEN="s3cr3t-token"
export FX="$TMP/fx" CURL_LOG="$TMP/curl.log" CURL_STDIN="$TMP/curl.stdin"

printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"

# Search responses are chosen by a marker word in the rule's JQL: `... AND text ~ "<marker>"`.
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out=""; url=""; body=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; --data-binary) body="$a" ;; esac
  case "$a" in https://*) url="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$*" >> "$CURL_LOG"
cat >> "$CURL_STDIN"
code=200
case "$url" in
  *"/search/jql")
    m="$(printf '%s' "$body" | jq -r '.jql' | sed -nE 's/.*text ~ "([a-z0-9]+)".*/\1/p')"
    if [ -f "$FX/search-$m.json" ]; then cat "$FX/search-$m.json" > "$out"; else echo '{}' > "$out"; fi
    [ -f "$FX/search-$m.code" ] && code="$(cat "$FX/search-$m.code")" ;;
  *"/myself") echo '{"accountId":"acc-me"}' > "$out" ;;
  *"/rest/dev-status/"*)
    id="${url##*issueId=}"
    if [ -f "$FX/dev-$id.json" ]; then cat "$FX/dev-$id.json" > "$out"; else echo '{}' > "$out"; code=500; fi ;;
  *) echo '{}' > "$out"; code=404 ;;
esac
printf '%s' "$code"
EOF
chmod +x "$TMP/bin/curl"

# shellcheck source=../scripts/lib-paths.sh
. "$REPO_ROOT/scripts/lib-paths.sh"
. "$REPO_ROOT/scripts/lib-jobs.sh"
. "$REPO_ROOT/scripts/lib-time.sh"
. "$REPO_ROOT/scripts/lib-queue.sh"
. "$REPO_ROOT/scripts/lib-secret.sh"
. "$REPO_ROOT/scripts/lib-jira-api.sh"
TMPD="$TMP/w"; mkdir -p "$TMPD"
jira_ready() { ar_jira_init || { echo "ar_jira_init: $AR_ERR"; exit 1; }; }

# write_rules <sp-field> <rules-yaml> — one jira:implement-next job (bill.auto) with these rules.
write_rules() {
  {
    cat <<YAML
agent:
  jira:
    site: "example.atlassian.net"
    email: "me@example.com"
    api_token_env: "EA_TEST_JIRA_TOKEN"
    story_points_field: "$1"
projects:
  bill:
    path: "/tmp/bill"
    jobs:
      - id: auto
        integration: jira
        action: implement-next
        every: 30m
        rules:
YAML
    printf '%s\n' "$2" | sed 's/^/          /'
  } > "$EA_AGENT_DIR/engineer.yaml"
  unset EA_JOBS_CFG; jobs_cfg_load; jira_ready
}
P="projects.bill.job.0.rule.0"

validate() { ar_validate bill 0; }

# mkissue <file> <jq-patch-on-.fields> [key] [id]
mkissue() {
  jq -n --arg key "${3:-BILL-1}" --arg id "${4:-10001}" '{id:$id, key:$key, fields:{
    summary:"s", description:"", issuetype:{name:"Bug"}, priority:{name:"High"},
    status:{name:"To Do"}, components:[], labels:[], assignee:null, issuelinks:[],
    created:"2025-11-01T10:00:00.000+0000", updated:"2025-11-09T10:00:00.000+0000"}}' \
    | jq ".fields |= ($2)" > "$1"
}
I="$TMP/issue.json"

# eval_rule <require-yaml-lines> <jq-patch> — reason (or PASS) for one issue under one rule.
eval_rule() {
  write_rules "${SPF:-}" "- name: r
  jql: 'project = BILL'
  require:
$(printf '%s\n' "$1" | sed 's/^/    /')"
  mkissue "$I" "$2"
  ar_eval "$I" "$P" || return 0
  echo PASS
}

echo "== validation"
write_rules "" "[]"
eq "no rules is a config error" "jira:implement-next needs at least one entry in rules" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL'
  requires: { assignee: any }"
eq "mistyped rule key is rejected, not ignored" "rule r: unknown key 'requires' (allowed: name jql require ready_check claim on_fail)" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL'
  require:
    label_none: [blocked]"
eq "mistyped require key is rejected" "rule r require: unknown key 'label_none' (allowed: issue_types priorities statuses components_any labels_any labels_none assignee max_story_points min_age min_quiet no_open_blockers no_linked_pr has_acceptance_criteria min_description_chars)" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL'
  require: { assignee: anyone }"
eq "assignee outside empty|me|any rejected" "rule r: require.assignee 'anyone' must be empty, me or any" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL'
  require: { max_story_points: 3 }"
eq "max_story_points without story_points_field is a config error" "rule r: require.max_story_points needs agent.jira.story_points_field (e.g. customfield_10016)" "$(validate)"

write_rules "customfield_10016" "- name: r
  jql: 'project = BILL'
  require: { max_story_points: 3 }"
validate >/dev/null; eq "max_story_points with the field id is valid" "0" "$?"

write_rules "" "- name: r
  jql: 'project = BILL'
  require: { min_age: 2hours }"
eq "malformed duration rejected" "rule r: require.min_age '2hours' must look like 30m, 2h or 1d" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL'
  require: { issue_types: Bug }"
eq "scalar where a list is required rejected" "rule r: require.issue_types must be a list" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL'
  require: { no_linked_pr: yes }"
eq "non-boolean flag rejected" "rule r: require.no_linked_pr 'yes' must be true or false" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL'
  ready_check: true"
eq "ready_check true refused until built" "rule r: ready_check is not built yet; remove it or set it to false" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL'
- name: r
  jql: 'project = OPS'"
eq "duplicate rule names rejected" "duplicate rule name 'r'" "$(validate)"

write_rules "" "- name: r
  require: { assignee: me }"
eq "missing jql rejected" "rule r: jql is required" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL'
  claim: { assign: someone }"
eq "claim.assign outside self|none rejected" "rule r: claim.assign 'someone' must be self or none" "$(validate)"

write_rules "" "- name: r
  jql: 'project = BILL | x'
  require: { assignee: any }
  claim: { assign: self, transition: 'In Progress' }
  on_fail: { unassign: true, transition: 'To Do' }"
validate >/dev/null; eq "complete rule is valid" "0" "$?"
eq "JQL keeps a literal |" "project = BILL | x" "$(_arc "$P.jql")"
rows="$(jobs_enumerate)"
eq "valid rules still report the job as not runnable yet" \
  "jira:implement-next does not run yet; check its rules with: jobs-ctl.sh preview bill.auto" \
  "$(jobs_validate "$(printf '%s\n' "$rows" | head -1)" "$rows")"

echo "== assignee default"
mode() { write_rules "" "- name: r
  jql: '$1'"; ar_assignee_mode "$P"; }
eq "JQL 'assignee is EMPTY' infers empty" "empty" "$(mode 'project = BILL AND assignee is EMPTY')"
eq "inference ignores case and spacing" "empty" "$(mode 'project = BILL and ASSIGNEE  IS  empty')"
eq "'assignee is not EMPTY' infers me" "me" "$(mode 'project = BILL AND assignee is not EMPTY')"
eq "no assignee clause infers me" "me" "$(mode 'project = BILL')"
write_rules "" "- name: r
  jql: 'project = BILL'
  require: { assignee: any }"
eq "explicit any is honored" "any" "$(ar_assignee_mode "$P")"

echo "== predicates"
eq "empty: unassigned passes"         "PASS" "$(eval_rule "assignee: empty" '.')"
eq "empty: assigned fails"            "assignee: already assigned" "$(eval_rule "assignee: empty" '.assignee={accountId:"acc-other"}')"
export AR_MY_ACCOUNT_ID=acc-me
eq "me: mine passes"                  "PASS" "$(eval_rule "assignee: me" '.assignee={accountId:"acc-me"}')"
eq "me: someone else's fails"         "assignee: not assigned to me" "$(eval_rule "assignee: me" '.assignee={accountId:"acc-other"}')"
eq "me: unassigned fails"             "assignee: not assigned to me" "$(eval_rule "assignee: me" '.')"
unset AR_MY_ACCOUNT_ID
eq "any: someone else's passes"       "PASS" "$(eval_rule "assignee: any" '.assignee={accountId:"acc-other"}')"

A="assignee: any"
eq "issue_types matches case-insensitively" "PASS" "$(eval_rule "$A
issue_types: [bug]" '.')"
eq "issue_types miss"                 "issue_types: 'Story' not in list" "$(eval_rule "$A
issue_types: [Bug]" '.issuetype.name="Story"')"
eq "priorities miss"                  "priorities: 'Low' not in list" "$(eval_rule "$A
priorities: [Highest, High]" '.priority.name="Low"')"
eq "statuses hit"                     "PASS" "$(eval_rule "$A
statuses: [\"To Do\"]" '.')"
eq "statuses miss"                    "statuses: 'In Progress' not in list" "$(eval_rule "$A
statuses: [\"To Do\"]" '.status.name="In Progress"')"
eq "components_any hit"               "PASS" "$(eval_rule "$A
components_any: [api]" '.components=[{name:"web"},{name:"API"}]')"
eq "components_any miss"              "components_any: no matching component" "$(eval_rule "$A
components_any: [api]" '.components=[{name:"web"}]')"
eq "labels_any hit"                   "PASS" "$(eval_rule "$A
labels_any: [backend]" '.labels=["backend"]')"
eq "labels_any is case-sensitive"     "labels_any: no matching label" "$(eval_rule "$A
labels_any: [backend]" '.labels=["Backend"]')"
eq "labels_none blocks"               "labels_none: has label 'blocked'" "$(eval_rule "$A
labels_none: [no-autopilot, blocked]" '.labels=["ok","blocked"]')"
eq "labels_none passes without them"  "PASS" "$(eval_rule "$A
labels_none: [blocked]" '.labels=["ok"]')"
eq "empty list is no constraint"      "PASS" "$(eval_rule "$A
labels_any: []" '.')"

SPF=customfield_10016
eq "story points at the cap pass"     "PASS" "$(eval_rule "$A
max_story_points: 3" '.customfield_10016=3')"
eq "story points over the cap fail"   "max_story_points: 5 > 3" "$(eval_rule "$A
max_story_points: 3" '.customfield_10016=5')"
eq "fractional estimate compared numerically" "max_story_points: 3.5 > 3" "$(eval_rule "$A
max_story_points: 3" '.customfield_10016=3.5')"
eq "no estimate fails"                "max_story_points: no estimate" "$(eval_rule "$A
max_story_points: 3" '.')"
SPF=""

# created 2025-11-10T14:00Z is exactly 2h before EA_NOW.
eq "min_age at the boundary passes"   "PASS" "$(eval_rule "$A
min_age: 2h" '.created="2025-11-10T14:00:00.000+0000"')"
eq "min_age one second short fails"   "min_age: created only 7199s ago (< 2h)" "$(eval_rule "$A
min_age: 2h" '.created="2025-11-10T14:00:01.000+0000"')"
eq "min_age honors the UTC offset"    "min_age: created only 3600s ago (< 2h)" "$(eval_rule "$A
min_age: 2h" '.created="2025-11-10T08:00:00.000-0700"')"
eq "min_quiet fails on a fresh edit"  "min_quiet: updated only 600s ago (< 30m)" "$(eval_rule "$A
min_quiet: 30m" '.updated="2025-11-10T15:50:00.000+0000"')"
eq "unparseable timestamp fails safe" "min_quiet: unparseable updated timestamp" "$(eval_rule "$A
min_quiet: 30m" '.updated="garbage"')"

eq "min_description_chars ignores surrounding whitespace" "min_description_chars: 3 < 4" "$(eval_rule "$A
min_description_chars: 4" '.description="  abc \n"')"
eq "min_description_chars met"        "PASS" "$(eval_rule "$A
min_description_chars: 4" '.description="abcd"')"
eq "AC heading found"                 "PASS" "$(eval_rule "$A
has_acceptance_criteria: true" '.description="h3. Acceptance Criteria\n* works"')"
eq "AC checklist found"               "PASS" "$(eval_rule "$A
has_acceptance_criteria: true" '.description="Do it\n- [ ] returns 200"')"
eq "AC absent fails"                  "has_acceptance_criteria: none found in description" "$(eval_rule "$A
has_acceptance_criteria: true" '.description="Make it faster"')"
eq "has_acceptance_criteria false is no constraint" "PASS" "$(eval_rule "$A
has_acceptance_criteria: false" '.description=""')"

BLK='{type:{inward:"is blocked by",outward:"blocks"},inwardIssue:{key:"BILL-9",fields:{status:{statusCategory:{key:"%s"}}}}}'
eq "open blocker fails"               "no_open_blockers: 1 unresolved blocker(s)" "$(eval_rule "$A
no_open_blockers: true" ".issuelinks=[$(printf "$BLK" indeterminate)]")"
eq "done blocker passes"              "PASS" "$(eval_rule "$A
no_open_blockers: true" ".issuelinks=[$(printf "$BLK" done)]")"
eq "an issue this one blocks does not count" "PASS" "$(eval_rule "$A
no_open_blockers: true" '.issuelinks=[{type:{inward:"is blocked by",outward:"blocks"},outwardIssue:{key:"BILL-8"}}]')"

echo '{"summary":{"pullrequest":{"overall":{"count":0}},"branch":{"overall":{"count":0}}}}' > "$FX/dev-10001.json"
eq "no dev links passes"              "PASS" "$(eval_rule "$A
no_linked_pr: true" '.')"
echo '{"summary":{"pullrequest":{"overall":{"count":1}},"branch":{"overall":{"count":2}}}}' > "$FX/dev-10001.json"
eq "linked PR fails"                  "no_linked_pr: 1 PR(s), 2 branch(es) linked" "$(eval_rule "$A
no_linked_pr: true" '.')"
rm "$FX/dev-10001.json"
eq "dev panel error fails safe"       "no_linked_pr: dev panel unavailable" "$(eval_rule "$A
no_linked_pr: true" '.')"

echo "== selection"
# search fixture: <marker> <issue-json...>
search_fx() {
  local m="$1"; shift
  if [ $# -eq 0 ]; then echo '{"issues":[]}' > "$FX/search-$m.json"
  else jq -s '{issues: .}' "$@" > "$FX/search-$m.json"; fi
}
mkissue "$TMP/a1.json" '.labels=["blocked"]' BILL-1 1
mkissue "$TMP/a2.json" '.' BILL-2 2
mkissue "$TMP/b1.json" '.' OPS-1 3
mkissue "$TMP/c1.json" '.assignee={accountId:"acc-me"}' MINE-1 4

RULES_AB="- name: first
  jql: 'project = BILL AND text ~ \"ra\" AND assignee is EMPTY'
  require: { labels_none: [blocked] }
- name: second
  jql: 'project = OPS AND text ~ \"rb\" AND assignee is EMPTY'"

search_fx ra "$TMP/a1.json" "$TMP/a2.json"; search_fx rb "$TMP/b1.json"
write_rules "" "$RULES_AB"
eq "first eligible ticket of the first rule wins" "first	BILL-2	2" "$(ar_select bill 0)"

search_fx ra "$TMP/a1.json"
eq "falls through to the next rule" "second	OPS-1	3" "$(ar_select bill 0)"

search_fx rb
ar_select bill 0 >/dev/null; eq "nothing eligible returns 1" "1" "$?"

search_fx ra "$TMP/a2.json"; search_fx rb "$TMP/b1.json"
printf -- '---\ntype: ticket-investigation\nsource_id: "BILL-2"\n---\n' > "$EA_AGENT_DIR/queue/completed/20251101-000000-ticket-investigation-BILL-2.md"
eq "a ticket already in the queue (even terminal) is never re-picked" "second	OPS-1	3" "$(ar_select bill 0)"
rm "$EA_AGENT_DIR/queue/completed/"*.md

echo 400 > "$FX/search-ra.code"
out="$(ar_select bill 0)"; rc=$?
eq "a failed search aborts instead of falling through" "2" "$rc"
eq "the abort names the rule" "rule first: search failed (HTTP 400)" "$out"
rm "$FX/search-ra.code"

: > "$CURL_LOG"; : > "$CURL_STDIN"; rm -f "$EA_AGENT_DIR/state/jira-account-id"
search_fx rc "$TMP/a2.json" "$TMP/c1.json"
write_rules "" "- name: mine
  jql: 'assignee = currentUser() AND text ~ \"rc\"'"
eq "an inferred 'me' rule resolves the account and skips others' tickets" "mine	MINE-1	4" "$(ar_select bill 0)"
eq "accountId cached per email" "me@example.com	acc-me" "$(cat "$EA_AGENT_DIR/state/jira-account-id")"
ar_select bill 0 >/dev/null
eq "/myself fetched once across runs" "1" "$(grep -c '/myself' "$CURL_LOG")"
if grep -q "s3cr3t-token" "$CURL_LOG"; then bad "token appeared in curl argv"; else ok "token never in curl argv"; fi
eq "token sent on stdin" "1" "$(grep -c 's3cr3t-token' "$CURL_STDIN" | awk '{print ($1>0)}')"

echo "== preview"
search_fx ra "$TMP/a1.json" "$TMP/a2.json"; search_fx rb "$TMP/b1.json"
write_rules "" "$RULES_AB"
out="$(bash "$REPO_ROOT/scripts/jobs-ctl.sh" preview bill.auto 2>&1)"
eq "preview shows every verdict and the pick" "rule first: 2 fetched
  BILL-1  skip  labels_none: has label 'blocked'
  BILL-2  PICK
rule second: 1 fetched
  OPS-1  eligible
would pick: BILL-2 (rule first)" "$out"
out="$(bash "$REPO_ROOT/scripts/jobs-ctl.sh" preview bill.nope 2>&1)"; rc=$?
eq "preview of an unknown job fails" "2:jobs-ctl: no such job: bill.nope" "$rc:$out"
write_rules "" "- name: r
  jql: 'project = BILL'
  require: { assignee: someone }"
out="$(bash "$REPO_ROOT/scripts/jobs-ctl.sh" preview bill.auto 2>&1)"
eq "preview refuses invalid rules" "jobs-ctl: bill.auto rules are invalid: rule r: require.assignee 'someone' must be empty, me or any" "$out"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
