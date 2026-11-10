#!/bin/bash
# Tests for scripts/jira-claim.sh — claim/release of a Jira ticket for implement-next.
# curl is a stateful Jira stub: assignee and status live in files and change on PUT/POST.
#
# Run: bash tests/jira-claim.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAIM="$REPO_ROOT/scripts/jira-claim.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state" "$TMP/bin"
export PATH="$TMP/bin:$PATH"
export EA_TEST_JIRA_TOKEN="s3cr3t-token"
export ST="$TMP/jira" REQ_LOG="$TMP/req.log" ARGV_LOG="$TMP/argv.log" NOTIFY_LOG="$TMP/notify.log"
export EA_NOTIFY_BIN="$TMP/bin/notify"
mkdir -p "$ST"

printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$NOTIFY_LOG"\n' > "$TMP/bin/notify"; chmod +x "$TMP/bin/notify"

cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out=""; url=""; body=""; method=GET; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; --data-binary) body="$a" ;; -X) method="$a" ;; esac
  case "$a" in https://*) url="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$*" >> "$ARGV_LOG"
cat > /dev/null
path="${url#https://example.atlassian.net/rest/api/2}"
printf '%s %s %s\n' "$method" "$path" "$body" >> "$REQ_LOG"
code=200
case "$method $path" in
  "GET /myself") echo '{"accountId":"acc-me"}' > "$out" ;;
  "GET /issue/"*"?fields="*)
    jq -n --arg a "$(cat "$ST/assignee")" --arg s "$(cat "$ST/status")" \
      '{fields:{assignee:(if $a == "" then null else {accountId:$a} end), status:{name:$s}}}' > "$out" ;;
  "PUT /issue/"*"/assignee")
    code=204; echo '' > "$out"
    if [ -f "$ST/put.code" ]; then code="$(cat "$ST/put.code")"
    elif [ -f "$ST/race_on_put" ]; then echo acc-other > "$ST/assignee"
    else printf '%s' "$body" | jq -r '.accountId // ""' > "$ST/assignee"; fi ;;
  "GET /issue/"*"/transitions") cat "$ST/transitions.json" > "$out" ;;
  "POST /issue/"*"/transitions")
    code=204; echo '' > "$out"
    id="$(printf '%s' "$body" | jq -r '.transition.id')"
    jq -r --arg id "$id" '.transitions[] | select(.id == $id) | .to.name' "$ST/transitions.json" > "$ST/status" ;;
  *) echo '{}' > "$out"; code=404 ;;
esac
printf '%s' "$code"
EOF
chmod +x "$TMP/bin/curl"

write_config() {  # write_config <auto_execute flow list>
  cat > "$EA_AGENT_DIR/engineer.yaml" <<YAML
agent:
  autonomy:
    auto_execute: $1
  jira:
    site: "example.atlassian.net"
    email: "me@example.com"
    api_token_env: "EA_TEST_JIRA_TOKEN"
projects:
  bill:
    path: "/tmp/bill"
    jobs:
      - id: auto
        integration: jira
        action: implement-next
        every: 30m
        rules:
          - name: bugs
            jql: 'project = BILL AND assignee is EMPTY'
            claim: { assign: self, transition: "In Progress" }
            on_fail: { unassign: true, transition: "To Do" }
          - name: mine
            jql: 'assignee = currentUser()'
            claim: { transition: "In Progress" }
            on_fail: { unassign: true, transition: "To Do" }
          - name: byname
            jql: 'project = BILL AND assignee is EMPTY'
            claim: { assign: self, transition: "Start work" }
          - name: quiet
            jql: 'project = BILL AND assignee is EMPTY'
            claim: { assign: none }
YAML
}

ITEM="$EA_AGENT_DIR/queue/drafts/20251110-000000-ticket-BILL-7.md"
reset() {  # reset <assignee> <status>
  printf '%s' "$1" > "$ST/assignee"; printf '%s' "$2" > "$ST/status"
  rm -f "$ST/put.code" "$ST/race_on_put"
  echo '{"transitions":[{"id":"21","name":"Start work","to":{"name":"In Progress"}},{"id":"11","name":"Stop","to":{"name":"To Do"}}]}' > "$ST/transitions.json"
  printf -- '---\ntype: ticket\nsource_id: "BILL-7"\nproject: bill\n---\n## Context\n' > "$ITEM"
  : > "$REQ_LOG"; : > "$NOTIFY_LOG"
}
run() {  # run <claim|release> <rule> [run-id] [extra...]
  local mode="$1" rule="$2" rid="${3:-run-1}"; shift 3 2>/dev/null || shift $#
  bash "$CLAIM" "$mode" --job bill.auto --rule "$rule" --key BILL-7 --item "$ITEM" --run-id "$rid" "$@" 2>"$TMP/err"
}
fmv() { awk -v k="$1" -F': ' '$1==k {gsub(/"/,"",$2); print $2; exit}' "$ITEM"; }
writes() { grep -cE '^(PUT|POST) ' "$REQ_LOG"; }
state() { printf '%s|%s' "$(cat "$ST/assignee")" "$(cat "$ST/status")"; }

echo "== autonomy tier"
write_config "[draft-pr]"
reset "" "To Do"
run claim bugs run-1; eq "claim refused without the jira-claim tier" "4" "$?"
eq "a refused claim writes nothing to Jira" "0" "$(writes)"
eq "a refused claim leaves the ticket untouched" "|To Do" "$(state)"
run claim bugs run-1 --approved; eq "a human Approve (--approved) claims without the tier" "0" "$?"
eq "approved claim assigns and transitions" "acc-me|In Progress" "$(state)"

write_config "[draft-pr, jira-claim]"

echo "== claim"
reset "" "To Do"
run claim bugs run-1; eq "claim succeeds" "0" "$?"
eq "ticket assigned to me and moved" "acc-me|In Progress" "$(state)"
eq "item records the claiming run" "run-1" "$(fmv claimed_by_run)"
eq "item records that this run assigned it" "true" "$(fmv claimed_assign)"
eq "item records the transition made" "In Progress" "$(fmv claimed_transition)"
eq "item records the prior status" "To Do" "$(fmv claim_from_status)"

reset "acc-other" "To Do"
run claim bugs run-1; eq "race lost before claim exits 3" "3" "$?"
eq "race lost before claim writes nothing" "0" "$(writes)"

reset "" "To Do"; touch "$ST/race_on_put"
run claim bugs run-1; eq "race lost after claim exits 3" "3" "$?"
eq "a lost claim is marked" "true" "$(fmv claim_lost)"
: > "$REQ_LOG"
run release bugs run-1; eq "release refuses a lost claim" "3" "$?"
eq "release of a lost claim writes nothing" "0" "$(writes)"

reset "" "To Do"
echo '{"transitions":[{"id":"31","name":"Done","to":{"name":"Done"}}]}' > "$ST/transitions.json"
run claim bugs run-1; eq "missing transition is not a failure" "0" "$?"
eq "missing transition: assigned, status unchanged" "acc-me|To Do" "$(state)"
grep -q "no transition to 'In Progress'" "$TMP/err" && ok "missing transition warns" || bad "missing transition warns"
eq "no transition recorded when none was made" "" "$(fmv claimed_transition)"

reset "" "To Do"
run claim byname run-1
eq "transition matched by transition name" "acc-me|In Progress" "$(state)"

reset "" "In Progress"
run claim bugs run-1
eq "already in the target status: no transition call" "0" "$(grep -c 'POST' "$REQ_LOG")"

reset "acc-me" "To Do"
run claim mine run-1; eq "inferred 'me' rule claims my own ticket" "0" "$?"
eq "my own ticket is not re-assigned" "0" "$(grep -c '^PUT' "$REQ_LOG")"
eq "claimed_assign false when this run did not assign" "false" "$(fmv claimed_assign)"

reset "" "To Do"
run claim quiet run-1; eq "assign: none claims without writes" "0|0" "$?|$(writes)"

reset "" "To Do"; echo 500 > "$ST/put.code"
run claim bugs run-1; eq "assign API error exits 1" "1" "$?"

echo "== input checks"
reset "" "To Do"
bash "$CLAIM" claim --job bill.auto --rule bugs --key BILL-8 --item "$ITEM" --run-id run-1 2>/dev/null
eq "key must match the item's source_id" "2" "$?"
bash "$CLAIM" claim --job bill.auto --rule bugs --key 'BILL-7;x' --item "$ITEM" --run-id run-1 2>/dev/null
eq "malformed key refused" "2" "$?"
run claim nosuch run-1; eq "unknown rule refused" "2" "$?"
eq "input errors write nothing" "0" "$(writes)"

echo "== release"
reset "" "To Do"; run claim bugs run-1; : > "$REQ_LOG"
run release bugs run-2; eq "release by another run refused" "3" "$?"
eq "foreign release writes nothing" "0" "$(writes)"
run release bugs run-1; eq "release succeeds" "0" "$?"
eq "release unassigns and moves back" "|To Do" "$(state)"
eq "release recorded" "run-1" "$(fmv released_by_run)"

reset "" "To Do"; run claim bugs run-1
echo acc-other > "$ST/assignee"; : > "$REQ_LOG"
run release bugs run-1; eq "release after reassignment succeeds" "0" "$?"
eq "someone else's assignment and status are left alone" "acc-other|In Progress" "$(state)"
eq "no writes after reassignment" "0" "$(writes)"

reset "" "To Do"; run claim bugs run-1
echo "In Review" > "$ST/status"; : > "$REQ_LOG"
run release bugs run-1
eq "status moved on since claim: unassigned but not transitioned" "|In Review" "$(state)"

reset "acc-me" "To Do"; run claim mine run-1
run release mine run-1
eq "release never unassigns a ticket that was already mine" "acc-me|To Do" "$(state)"

reset "" "To Do"; run claim bugs run-1
echo 500 > "$ST/put.code"
run release bugs run-1; eq "failed rollback exits 1" "1" "$?"
grep -q -- "--priority urgent" "$NOTIFY_LOG" && grep -q "BILL-7" "$NOTIFY_LOG" \
  && ok "failed rollback pushes an urgent alert" || bad "failed rollback pushes an urgent alert"

reset "" "To Do"; echo 500 > "$ST/put.code"
run claim bugs run-1; rm -f "$ST/put.code"; : > "$REQ_LOG"
run release bugs run-1; eq "release after a failed assign is a clean no-op" "0|0|To Do" "$?|$(writes)|$(cat "$ST/status")"

echo "== secrets"
if grep -q "s3cr3t-token" "$ARGV_LOG"; then bad "token appeared in curl argv"; else ok "token never in curl argv"; fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
