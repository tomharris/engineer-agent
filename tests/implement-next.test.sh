#!/bin/bash
# Tests for the jira implement-next job (scripts/job-jira-implement-next.sh), its dispatcher wiring,
# and the listener's autopilot Approve path. git, claude, curl (a stateful Jira) and notify are
# stubbed; the clock is frozen with EA_NOW in a fixed TZ.
#
# Run: bash tests/implement-next.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HANDLER="$REPO_ROOT/scripts/job-jira-implement-next.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent" EA_CONFIG_FILE="$TMP/agent/engineer.yaml"
Q="$EA_AGENT_DIR/queue"
mkdir -p "$Q"/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state" "$TMP/bin" "$TMP/repo"
export PATH="$TMP/bin:$PATH"
export TZ=America/Denver
export EA_NOW=1762840740                 # 2025-11-10 22:59 MST
export EA_TEST_JIRA_TOKEN="s3cr3t"
export CLAUDE_ARGS="$TMP/claude.args"
export ST="$TMP/jira" REQ_LOG="$TMP/req.log" NOTIFY_LOG="$TMP/notify.log" CLAUDE_LOG="$TMP/claude.log"
export EA_NOTIFY_BIN="$TMP/bin/notify" NOTIFY_BIN="$TMP/bin/notify" CLAUDE_BIN="$TMP/bin/claude"
mkdir -p "$ST"

printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$NOTIFY_LOG"\n' > "$TMP/bin/notify"; chmod +x "$TMP/bin/notify"

cat > "$TMP/bin/git" <<'EOF'
#!/bin/bash
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[i]}" in
    ls-remote) [ -z "${LS_REMOTE:-}" ] || printf "%s\trefs/heads/b\n" "$LS_REMOTE"; exit 0;;
    symbolic-ref) echo "origin/main"; exit 0;;
    rev-parse) echo "deadbee"; exit 0;;
    worktree)
      if [ "${args[i+1]}" = "add" ]; then
        for ((j=i+2;j<${#args[@]};j++)); do [ "${args[j]}" = "--detach" ] && { mkdir -p "${args[j+1]}"; break; }; done
      fi
      exit 0;;
  esac
done
exit 0
EOF
chmod +x "$TMP/bin/git"

# FAKE_IMPL=ok writes completed/<item> (the confined run's success side effect); fail does nothing;
# hang blocks until killed. Records the in-flight markers visible while it runs.
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAUDE_ARGS"
printf '%s' "$*" | grep -q "Generate a QA test plan" && exit 0
item="$(printf '%s' "$*" | sed -nE "s/.*queue item '([^']+)'.*/\1/p")"
printf '%s markers=%s\n' "$item" "$(cat "$EA_AGENT_DIR"/state/implement-inflight/* 2>/dev/null | cut -f2 | paste -sd, -)" >> "$CLAUDE_LOG"
case "${FAKE_IMPL:-ok}" in
  ok)   cp "$EA_AGENT_DIR/queue/drafts/$item" "$EA_AGENT_DIR/queue/completed/$item" ;;
  hang) touch "$EA_AGENT_DIR/hanging"; exec sleep 300 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/claude"

# Stateful Jira: per-key assignee/status files; issue fixtures in $ST/<KEY>.json.
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out=""; url=""; body=""; method=GET; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; --data-binary) body="$a" ;; -X) method="$a" ;; esac
  case "$a" in https://*) url="$a" ;; esac
  prev="$a"
done
cat > /dev/null
path="${url#https://example.atlassian.net/rest/api/2}"
printf '%s %s\n' "$method" "$path" >> "$REQ_LOG"
key="$(printf '%s' "$path" | sed -nE 's#^/issue/([A-Z]+-[0-9]+).*#\1#p')"
cur() { jq --arg a "$(cat "$ST/$1.assignee")" --arg s "$(cat "$ST/$1.status")" \
  '.fields.assignee = (if $a == "" then null else {accountId:$a} end) | .fields.status = {name:$s}' "$ST/$1.json"; }
code=200
case "$method $path" in
  "GET /myself") echo '{"accountId":"acc-me"}' > "$out" ;;
  "POST /search/jql") for k in $(cat "$ST/search"); do cur "$k"; done | jq -s '{issues: .}' > "$out" ;;
  "GET /issue/"*"/transitions") echo '{"transitions":[{"id":"21","name":"Start","to":{"name":"In Progress"}},{"id":"11","name":"Stop","to":{"name":"To Do"}}]}' > "$out" ;;
  "GET /issue/"*) cur "$key" > "$out" ;;
  "PUT /issue/"*"/assignee")
    code=204; : > "$out"
    if [ -f "$ST/race_on_put" ]; then echo acc-other > "$ST/$key.assignee"
    else printf '%s' "$body" | jq -r '.accountId // ""' > "$ST/$key.assignee"; fi ;;
  "POST /issue/"*"/transitions")
    code=204; : > "$out"
    case "$(printf '%s' "$body" | jq -r '.transition.id')" in 21) echo "In Progress" ;; 11) echo "To Do" ;; esac > "$ST/$key.status" ;;
  *) echo '{}' > "$out"; code=404 ;;
esac
printf '%s' "$code"
EOF
chmod +x "$TMP/bin/curl"

mkissue() {  # mkissue <KEY> <type> [creator] [changelog-json]
  local cl='{"total":0,"histories":[]}'; [ -z "${4:-}" ] || cl="$4"
  jq -n --arg k "$1" --arg t "$2" --arg c "${3:-acc-lead}" --argjson cl "$cl" \
    '{id:"1", key:$k, changelog:$cl, fields:{summary:("Fix " + $k), description:"Do it.\n- [ ] works",
    issuetype:{name:$t}, priority:{name:"High"}, components:[], labels:[], issuelinks:[], creator:{accountId:$c},
    created:"2025-11-01T10:00:00.000+0000", updated:"2025-11-01T10:00:00.000+0000"}}' > "$ST/$1.json"
  : > "$ST/$1.assignee"; echo "To Do" > "$ST/$1.status"
}

ALLOW='    exec:
      allowed_commands:
        - "make"'
write_config() {  # write_config <auto_execute flow list> [daily_cap] [allowed_commands block] [trusted_authors]
  cat > "$EA_CONFIG_FILE" <<YAML
agent:
  autonomy:
    auto_execute: $1
  jira:
    site: "example.atlassian.net"
    email: "me@example.com"
    api_token_env: "EA_TEST_JIRA_TOKEN"
projects:
  bill:
    path: "$TMP/repo"
    jira:
      project: "BILL"
${3-    exec:
      allowed_commands:
        - "make"}
    investigation:
      jira_types: ["Spike"]
    qa:
      base_url: "http://localhost:3000"
    jobs:
      - id: auto
        integration: jira
        action: implement-next
        every: 30m
        trusted_authors: ${4-[acc-lead, acc-me]}
        guards: { daily_cap: ${2:-5}, max_in_flight: 1 }
        rules:
          - name: bugs
            jql: 'project = BILL AND assignee is EMPTY'
            claim: { assign: self, transition: "In Progress" }
            on_fail: { unassign: true, transition: "To Do" }
YAML
}

reset() {
  rm -rf "$Q"/*/* "$EA_AGENT_DIR/state" "$ST"/*; mkdir -p "$EA_AGENT_DIR/state" "$TMP/repo"
  rm -f "$EA_AGENT_DIR/hanging"
  : > "$REQ_LOG"; : > "$NOTIFY_LOG"; : > "$CLAUDE_LOG"; : > "$CLAUDE_ARGS"
  mkissue BILL-1 Bug; mkissue BILL-2 Bug; echo "BILL-1 BILL-2" > "$ST/search"
}
run_job() { bash "$HANDLER" --job bill.auto --errors "$TMP/errors" --items "$TMP/items" 2>/dev/null; }
drafts()  { ls "$Q/drafts" | tr '\n' ' ' | sed 's/ $//'; }
state()   { printf '%s|%s' "$(cat "$ST/$1.assignee")" "$(cat "$ST/$1.status")"; }
writes()  { grep -cE '^(PUT|POST /issue)' "$REQ_LOG"; }
valid()   { ( . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-jobs.sh"
              rows="$(jobs_enumerate)"; jobs_validate "$(printf '%s\n' "$rows" | head -1)" "$rows" ); }

echo "== validation"
write_config "[]" 5 ""
eq "no build allowlist refuses the job at parse time" \
  "jira:implement-next needs projects.bill.exec.allowed_commands (build/test commands for the confined run)" "$(valid)"
write_config "[]" 0
eq "daily_cap must be positive" "guards.daily_cap '0' must be a positive integer" "$(valid)"
write_config "[]" 5 "${ALLOW}" '["acc lead"]'
eq "a malformed trusted_authors entry is refused" "trusted_authors entry 'acc lead' is not a Jira accountId" "$(valid)"
write_config "[]"
eq "complete job is valid" "" "$(valid)"

echo "== gate: implement tier absent"
reset; write_config "[jira-claim]"
run_job; eq "exits ok" "0" "$?"
eq "one item counted" "1" "$(cat "$TMP/items")"
ITEM="$(drafts)"
case "$ITEM" in *-ticket-BILL-1.md) ok "first eligible ticket queued in drafts/" ;; *) bad "drafts/ holds [$ITEM]" ;; esac
eq "item marked as an autopilot pick" "true|bill.auto|bugs|drafted" \
  "$(for k in autopilot autopilot_job autopilot_rule status; do awk -F': ' -v k=$k '$1==k {gsub(/"/,"",$2); printf "%s|", $2}' "$Q/drafts/$ITEM"; done | sed 's/|$//')"
eq "ledger records the pick" "${ITEM}	bill.auto	bugs	BILL-1	jira" "$(cat "$EA_AGENT_DIR/state/autopilot-items.tsv")"
grep -q -- "--item-id ${ITEM} --source-url https://example.atlassian.net/browse/BILL-1" "$NOTIFY_LOG" \
  && ok "Approve/Reject push sent" || bad "Approve/Reject push sent ($(cat "$NOTIFY_LOG"))"
eq "nothing claimed in Jira" "0|To Do" "$(writes)|$(cat "$ST/BILL-1.status")"
eq "no implementation run" "0" "$(grep -c . "$CLAUDE_LOG")"

: > "$REQ_LOG"
run_job
eq "a pick awaiting a decision blocks the next pick" "0|0" "$(cat "$TMP/items")|$(grep -c search "$REQ_LOG")"

reset; write_config "[implement]"
run_job
eq "implement without jira-claim still waits for Approve" "0|0" "$(writes)|$(grep -c . "$CLAUDE_LOG")"
grep -q -- "--item-id" "$NOTIFY_LOG" && ok "and pushes Approve/Reject" || bad "and pushes Approve/Reject"

echo "== daily_cap at local midnight"
reset; write_config "[]" 1
run_job; mv "$Q/drafts/"*.md "$Q/rejected/"
: > "$REQ_LOG"; run_job
eq "cap reached for today: no search" "0|0" "$(cat "$TMP/items")|$(grep -c search "$REQ_LOG")"
EA_NOW=$((EA_NOW + 3720)) run_job     # 2025-11-11 00:01 MST
eq "the next local day picks again" "1" "$(cat "$TMP/items")"
case "$(drafts)" in *-ticket-BILL-2.md) ok "a rejected pick is never re-picked" ;; *) bad "drafts/ holds [$(drafts)]" ;; esac

echo "== kind"
reset; write_config "[]"
mkissue BILL-1 Spike
run_job
case "$(drafts)" in *-ticket-BILL-2.md) ok "an investigation-kind ticket is skipped" ;; *) bad "drafts/ holds [$(drafts)]" ;; esac

echo "== full autonomy"
reset; write_config "[implement, jira-claim]"
run_job; eq "implemented run exits ok" "0" "$?"
eq "ticket claimed and moved" "acc-me|In Progress" "$(state BILL-1)"
ITEM="$(ls "$Q/completed")"
case "$ITEM" in *-ticket-BILL-1.md) ok "completed/ record present" ;; *) bad "completed/ holds [$ITEM]" ;; esac
eq "drafts/ reconciled" "" "$(drafts)"
eq "in-flight marker present during the run" "${ITEM} markers=bill" "$(cat "$CLAUDE_LOG")"
eq "in-flight marker removed after" "" "$(ls "$EA_AGENT_DIR/state/implement-inflight" 2>/dev/null)"
grep -q "Autopilot implemented BILL-1" "$NOTIFY_LOG" && ok "success push" || bad "success push"
for r in "Bash(gh issue view" "Bash(gh pr view" "Bash(gh pr list" "mcp__atlassian" "Bash(curl"; do
  grep -qF -- "$r" "$CLAUDE_ARGS" && bad "unattended run grants $r" || ok "unattended run omits $r"
done
eq "unattended run starts no QA follow-on" "0" "$(grep -c "Generate a QA test plan" "$CLAUDE_ARGS")"

reset; write_config "[implement, jira-claim]"
FAKE_IMPL=fail run_job; eq "failed implementation exits 1" "1" "$?"
eq "claim rolled back" "|To Do" "$(state BILL-1)"
case "$(drafts)" in *-ticket-BILL-1.md) ok "item left in drafts/" ;; *) bad "drafts/ holds [$(drafts)]" ;; esac
grep -q "urgent.*Autopilot failed on BILL-1\|Autopilot failed on BILL-1.*urgent" "$NOTIFY_LOG" && ok "urgent failure push" || bad "urgent failure push"
grep -q "did not complete; claim rolled back" "$TMP/errors" && ok "error recorded for the receipt" || bad "error recorded"

reset; write_config "[implement, jira-claim]"; touch "$ST/race_on_put"
run_job; eq "lost race exits ok" "0" "$?"
eq "lost race: item moved to rejected/, nothing implemented" "1|0|0" \
  "$(ls "$Q/rejected" | grep -c ticket-BILL-1)|$(grep -c . "$CLAUDE_LOG")|$(ls "$Q/drafts" | wc -l | tr -d ' ')"
eq "lost race: the other person's assignment is untouched" "acc-other" "$(cat "$ST/BILL-1.assignee")"

echo "== trusted authorship (unattended)"
untrusted_case() {  # untrusted_case <name> <expected reason fragment> [trusted_authors]
  write_config "[implement, jira-claim]" 5 "$ALLOW" "${3-[acc-lead, acc-me]}"
  run_job
  eq "$1: nothing claimed or implemented" "0|0" "$(writes)|$(grep -c . "$CLAUDE_LOG")"
  grep -q -- "--item-id" "$NOTIFY_LOG" && grep -qF "$2" "$NOTIFY_LOG" \
    && ok "$1: pushed for Approve with the reason" || bad "$1: push ($(cat "$NOTIFY_LOG"))"
  grep -qF "Unattended run not allowed: $2" "$Q/drafts/"*.md && ok "$1: reason shown at the gate" || bad "$1: reason in item"
}
reset; mkissue BILL-1 Bug acc-stranger
untrusted_case "untrusted creator" "created by acc-stranger, not a trusted author"
reset; mkissue BILL-1 Bug acc-lead '{"total":1,"histories":[{"author":{"accountId":"acc-stranger"},"items":[{"field":"description","fieldId":"description"}]}]}'
untrusted_case "description edited by an untrusted account" "edited by acc-stranger, not a trusted author"
reset; mkissue BILL-1 Bug acc-lead '{"total":1,"histories":[{"author":{"accountId":"acc-stranger"},"items":[{"field":"labels","fieldId":"labels"}]}]}'
untrusted_case "labels edited by an untrusted account" "edited by acc-stranger, not a trusted author"
reset; mkissue BILL-1 Bug acc-lead '{"total":1,"histories":[{"author":{"accountId":"acc-stranger"},"items":[{"field":"Component","fieldId":"components"}]}]}'
untrusted_case "components edited by an untrusted account" "edited by acc-stranger, not a trusted author"
reset; mkissue BILL-1 Bug acc-lead '{"total":150,"histories":[]}'
untrusted_case "truncated changelog" "changelog truncated; cannot verify edits"
reset
untrusted_case "no trusted_authors" "no trusted_authors configured" "[]"
reset; mkissue BILL-1 Bug acc-lead '{"total":2,"histories":[{"author":{"accountId":"acc-stranger"},"items":[{"field":"status","fieldId":"status"}]},{"author":{"accountId":"acc-me"},"items":[{"field":"summary","fieldId":"summary"}]}]}'
write_config "[implement, jira-claim]"
run_job
eq "trusted text edits plus untrusted non-text edits still run unattended" "acc-me|In Progress|1" \
  "$(state BILL-1)|$(ls "$Q/completed" | grep -c ticket-BILL-1)"

echo "== resume a stopped pipeline"
. "$SCRIPT_DIR/lib-resume-fixture.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$TMP/pipeline.log" > "$TMP/bin/pipeline"; chmod +x "$TMP/bin/pipeline"
: > "$TMP/pipeline.log"; reset; write_config "[implement, jira-claim]"
awk '{print} /^        guards: /{print "        after_pr: { mark_ready: true }"}' "$EA_CONFIG_FILE" > "$TMP/c" && mv "$TMP/c" "$EA_CONFIG_FILE"
stopped_pipeline_fixture bill.auto stopped-ticket-BILL-9.md
LS_REMOTE=new EA_PR_PIPELINE_BIN="$TMP/bin/pipeline" EA_PR_PIPELINE_FOREGROUND=1 run_job
eq "a stopped pipeline whose branch moved resumes, even when no new pick is allowed" \
  "--item stopped-ticket-BILL-9.md|0" "$(cat "$TMP/pipeline.log")|$(grep -c . "$CLAUDE_LOG")"

echo "== max_in_flight"
reset; write_config "[implement, jira-claim]"
mkdir -p "$EA_AGENT_DIR/state/implement-inflight"
sleep 300 & live=$!
printf '%s\tbill\n' "$live" > "$EA_AGENT_DIR/state/implement-inflight/other.md"
: > "$REQ_LOG"; run_job
eq "a live implementation on the project blocks the job" "0|0" "$(cat "$TMP/items")|$(grep -c search "$REQ_LOG")"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
run_job
eq "a dead marker is reclaimed" "1|" "$(cat "$TMP/items")|$(ls "$EA_AGENT_DIR/state/implement-inflight")"

echo "== killed mid-implementation"
reset; write_config "[implement, jira-claim]"
FAKE_IMPL=hang bash "$HANDLER" --job bill.auto --errors "$TMP/errors" --items "$TMP/items" 2>/dev/null &
hp=$!
for _ in $(seq 1 100); do [ -e "$EA_AGENT_DIR/hanging" ] && break; sleep 0.1; done
( . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-jobs.sh"; jobs_kill_tree "$hp" )
wait "$hp" 2>/dev/null
eq "a watchdog kill releases the claim" "|To Do" "$(state BILL-1)"

echo "== dispatcher"
reset; write_config "[implement, jira-claim]"
bash "$REPO_ROOT/scripts/jobs-tick.sh" --only bill.auto --force --foreground
R="$EA_AGENT_DIR/state/jobs/bill.auto.receipt"
eq "receipt ok with one item" "ok|1" "$(awk -F': ' '/^status:/ {gsub(/"/,"",$2); s=$2} /^items:/ {i=$2} END {print s "|" i}' "$R")"
reset; write_config "[implement, jira-claim]"
FAKE_IMPL=fail bash "$REPO_ROOT/scripts/jobs-tick.sh" --only bill.auto --force --foreground
grep -q "did not complete; claim rolled back" "$R" && grep -q '^status: "\{0,1\}error' "$R" \
  && ok "failed run is an error receipt naming the cause" || bad "failed run receipt: $(cat "$R")"

echo "== listener Approve"
export EA_NTFY_SERVER="https://example.invalid" EA_NTFY_TOPIC="t" EA_NTFY_COMMAND_TOPIC="c" EA_NTFY_AUTH_TOKEN=""
msg() { jq -nc --arg id "$1" --arg m "$2" '{event:"message",id:$id,time:1,message:$m}'; }
reset; write_config "[]"
run_job; ITEM="$(drafts)"; : > "$REQ_LOG"
( source "$REPO_ROOT/scripts/approval-listener.sh"; handle_line "$(msg m1 "approve|$ITEM")" ) >/dev/null 2>&1
eq "Approve claims the autopilot pick without the jira-claim tier" "acc-me|In Progress" "$(state BILL-1)"
eq "Approve implements it" "1|" "$(ls "$Q/completed" | grep -c ticket-BILL-1)|$(drafts)"
eq "an approved run keeps the QA follow-on" "1" "$(grep -c "Generate a QA test plan" "$CLAUDE_ARGS")"

reset; write_config "[]"
printf -- '---\ntype: ticket\nsource: jira\nsource_id: "BILL-2"\nproject: "bill"\nautopilot: true\nautopilot_job: "bill.auto"\nautopilot_rule: "bugs"\n---\n' \
  > "$Q/drafts/20251110-000000-ticket-BILL-2.md"
( source "$REPO_ROOT/scripts/approval-listener.sh"; handle_line "$(msg m2 "approve|20251110-000000-ticket-BILL-2.md")" ) >/dev/null 2>&1
eq "frontmatter alone never triggers a Jira claim" "0|To Do" "$(writes)|$(cat "$ST/BILL-2.status")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
