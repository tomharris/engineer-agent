#!/bin/bash
# Tests for the github-issues implement-next job: rule validation and predicates
# (lib-gh-assign-rules.sh), claim/release (gh-claim.sh), the handler
# (job-github-implement-next.sh) and the listener's autopilot Approve path. gh is a stateful stub
# (tests/lib-github-stub.sh); git, claude and notify are stubbed; the clock is frozen.
#
# Run: bash tests/github-implement-next.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HANDLER="$REPO_ROOT/scripts/job-github-implement-next.sh"
CLAIM="$REPO_ROOT/scripts/gh-claim.sh"
. "$SCRIPT_DIR/lib-github-stub.sh"

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
export CLAUDE_ARGS="$TMP/claude.args"
export ST="$TMP/gh" REQ_LOG="$TMP/req.log" NOTIFY_LOG="$TMP/notify.log" CLAUDE_LOG="$TMP/claude.log"
export EA_NOTIFY_BIN="$TMP/bin/notify" NOTIFY_BIN="$TMP/bin/notify" CLAUDE_BIN="$TMP/bin/claude"
mkdir -p "$ST"
gh_stub_install "$TMP/bin"

printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$NOTIFY_LOG"\n' > "$TMP/bin/notify"; chmod +x "$TMP/bin/notify"
cat > "$TMP/bin/git" <<'EOF'
#!/bin/bash
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[i]}" in
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
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAUDE_ARGS"
printf '%s' "$*" | grep -q "Generate a QA test plan" && exit 0
item="$(printf '%s' "$*" | sed -nE "s/.*queue item '([^']+)'.*/\1/p")"
printf '%s\n' "$item" >> "$CLAUDE_LOG"
[ "${FAKE_IMPL:-ok}" = ok ] && cp "$EA_AGENT_DIR/queue/drafts/$item" "$EA_AGENT_DIR/queue/completed/$item"
exit 0
EOF
chmod +x "$TMP/bin/claude"

ALLOW='    exec:
      allowed_commands:
        - "make"'
# write_config <auto_execute> [require flow map] [trusted_authors] [allowed_commands block] [query]
write_config() {
  cat > "$EA_CONFIG_FILE" <<YAML
agent:
  autonomy:
    auto_execute: $1
projects:
  web:
    path: "$TMP/repo"
    tracker: github-issues
    github:
      owner: acme
      repos: ["web"]
${4-$ALLOW}
    qa:
      base_url: "http://localhost:3000"
    jobs:
      - id: auto
        integration: github-issues
        action: implement-next
        every: 30m
        trusted_authors: ${3-[lead, tom]}
        board: { owner: acme, number: 3 }
        guards: { daily_cap: 5 }
        rules:
          - name: ready
            query: '${5-no:assignee label:ready}'
            require: ${2-{ project_statuses: [Ready] }}
            claim: { assign: self, project_status: "In Progress" }
            on_fail: { unassign: true, project_status: "Ready" }
YAML
}

reset() {
  rm -rf "$Q"/*/* "$EA_AGENT_DIR/state" "$ST"/*; mkdir -p "$EA_AGENT_DIR/state" "$TMP/repo"
  : > "$REQ_LOG"; : > "$NOTIFY_LOG"; : > "$CLAUDE_LOG"; : > "$CLAUDE_ARGS"
  mkissue 1; mkissue 2; echo "1 2" > "$ST/search"
}
run_job() { bash "$HANDLER" --job web.auto --errors "$TMP/errors" --items "$TMP/items" 2>/dev/null; }
drafts()  { ls "$Q/drafts" | tr '\n' ' ' | sed 's/ $//'; }
state()   { printf '%s|%s' "$(cat "$ST/$1.assignees")" "$(cat "$ST/$1.status")"; }
writes()  { grep -c . "$REQ_LOG"; }
valid()   { ( . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-jobs.sh"
              rows="$(jobs_enumerate)"; jobs_validate "$(printf '%s\n' "$rows" | head -1)" "$rows" ); }
# verdicts — "<sid> <verdict>" per fetched issue, from a read-only preview.
verdicts() { bash "$REPO_ROOT/scripts/jobs-ctl.sh" preview web.auto 2>&1 | sed -nE 's/^  ([a-z]+\/[a-z]+#[0-9]+)  (.*)$/\1 \2/p'; }

echo "== validation"
write_config "[]"
eq "complete job is valid" "" "$(valid)"
write_config "[]" "{ project_statuses: [Ready] }" "[lead]" ""
eq "no build allowlist refuses the job" \
  "github-issues:implement-next needs projects.web.exec.allowed_commands (build/test commands for the confined run)" "$(valid)"
write_config "[]" "{ project_statuses: [Ready] }" '["le ad"]'
eq "a malformed login is refused" "trusted_authors entry 'le ad' is not a GitHub login" "$(valid)"
write_config "[]" "{ project_status: [Ready] }"
eq "an unknown require key is refused" \
  "rule ready require: unknown key 'project_status' (allowed: labels_any labels_none milestones issue_types project_statuses title_prefixes assignee min_age min_quiet no_open_blockers no_linked_pr has_acceptance_criteria min_body_chars)" "$(valid)"
write_config "[]" "{ milestones: v2 }"
eq "a scalar where a list belongs is refused" "rule ready: require.milestones must be a list" "$(valid)"
write_config "[]"; sed -i.bak 's/^        board: .*$//' "$EA_CONFIG_FILE"
eq "board statuses without a board are refused" "rule ready: require.project_statuses needs the job's board (owner, number)" "$(valid)"
write_config "[]"
sed -i.bak 's/tracker: github-issues/tracker: jira/' "$EA_CONFIG_FILE"
eq "a non-github project is refused" "github-issues:implement-next needs a project with tracker github-issues" "$(valid)"

echo "== predicates"
reset; write_config "[]" "{ assignee: empty, labels_none: [blocked], milestones: [v2], issue_types: [Bug], project_statuses: [Ready], no_linked_pr: true, no_open_blockers: true, has_acceptance_criteria: true, min_body_chars: 5, min_age: 1d, min_quiet: 1h }" "[lead]" "$ALLOW" "label:ready"
mkissue 1 lead "ready" '.milestone = {title: "v2"}'
mkissue 2 lead "ready,blocked" '.milestone = {title: "v2"}'
mkissue 3 lead "ready" '.milestone = {title: "v1"}'
mkissue 4 lead "ready" '.milestone = {title: "v2"} | .issueType = {name: "Feature"}'
mkissue 5 lead "ready" '.milestone = {title: "v2"} | .closedByPullRequestsReferences.totalCount = 1'
mkissue 6 lead "ready" '.milestone = {title: "v2"} | .xrefs = {totalCount: 1, nodes: [{source: {state: "OPEN"}}]}'
mkissue 7 lead "ready" '.milestone = {title: "v2"} | .xrefs = {totalCount: 1, nodes: [{source: {state: "MERGED"}}]}'
mkissue 8 lead "ready" '.milestone = {title: "v2"} | .blockedBy = {totalCount: 1, nodes: [{state: "OPEN"}]}'
mkissue 9 lead "ready" '.milestone = {title: "v2"} | .blockedBy = {totalCount: 60, nodes: []}'
mkissue 10 lead "ready" '.milestone = {title: "v2"} | .body = "Just do it"'
mkissue 11 lead "ready" '.milestone = {title: "v2"} | .updatedAt = "2025-11-11T05:30:00Z"'
mkissue 12 lead "ready" '.milestone = {title: "v2"} | .repository.nameWithOwner = "evil/other"'
GH_STUB_STATUS="Todo" mkissue 13 lead "ready" '.milestone = {title: "v2"}'
mkissue 14 lead "ready,spike" '.milestone = {title: "v2"}'
mkissue 15 lead "ready" '.milestone = {title: "v2"} | .title = "Investigate slow checkout"'
mkissue 16 lead "ready" '.milestone = {title: "v2"} | .createdAt = "2025-11-10T12:00:00Z"'
echo "16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1" > "$ST/search"
V="$(verdicts)"
want="acme/web#16 skip  min_age: created only 64740s ago (< 1d)
acme/web#15 skip  title may be an investigation (leading 'Investigate'); queue it with add-ticket --implement
acme/web#14 skip  investigation kind (label spike); implement-next only implements
acme/web#13 skip  project_statuses: 'Todo' not in list
evil/other#12 skip  repo: evil/other is not one of the project's github.repos
acme/web#11 skip  min_quiet: updated only 1740s ago (< 1h)
acme/web#10 skip  has_acceptance_criteria: none found in body
acme/web#9 skip  no_open_blockers: blockers unavailable
acme/web#8 skip  no_open_blockers: 1 open blocker(s)
acme/web#7 PICK
acme/web#6 skip  no_linked_pr: 0 closing PR(s), 0 branch(es), 1 open referencing PR(s)
acme/web#5 skip  no_linked_pr: 1 closing PR(s), 0 branch(es), 0 open referencing PR(s)
acme/web#4 skip  issue_types: 'Feature' not in list
acme/web#3 skip  milestones: 'v1' not in list
acme/web#2 skip  labels_none: has label 'blocked'
acme/web#1 eligible"
eq "each predicate decides in both directions" "$want" "$V"
grep -qF "label:ready repo:acme/web is:issue is:open" "$ST/queries" \
  && ok "query restricted to the project's repos and open issues" || bad "query: $(cat "$ST/queries")"

reset; write_config "[]" "{ project_statuses: [Ready] }" "[lead]" "$ALLOW" "label:ready"
echo tom > "$ST/me"; echo "other" > "$ST/1.assignees"; echo "tom" > "$ST/2.assignees"
eq "assignee defaults to me when the query does not say no:assignee" \
  "acme/web#1 skip  assignee: not assigned to me|acme/web#2 PICK" "$(verdicts | paste -sd'|' -)"

reset; write_config "[]" '{ title_prefixes: ["[Web]"] }' "[lead]" "$ALLOW" "no:assignee label:ready"
mkissue 1 lead "ready" '.title = "[web] Fix nav"'
mkissue 2 lead "ready" '.title = "[Wayfinder] [Web] Fix nav"'
echo "2 1" > "$ST/search"
eq "title_prefixes matches only the start of the title, case-insensitively" \
  "acme/web#2 skip  title_prefixes: title does not start with any|acme/web#1 PICK" "$(verdicts | paste -sd'|' -)"

echo "== claim / release"
reset; write_config "[]"
ITEM="$Q/drafts/x-ticket-gh-1.md"
printf -- '---\ntype: ticket\nsource_id: "acme/web#1"\n---\n' > "$ITEM"
claim() { bash "$CLAIM" "$1" --job web.auto --rule ready --key "acme/web#1" --item "$ITEM" --run-id r1 "${@:2}" 2>/dev/null; }
claim claim; eq "refused without github-claim or --approved" "4|0" "$?|$(writes)"
claim claim --approved; eq "approved claim succeeds" "0" "$?"
eq "assigned to me and moved on the board" "tom|In Progress" "$(state 1)"
claim release; eq "release exits 0" "0" "$?"
eq "release undoes both" "|Ready" "$(state 1)"

reset; write_config "[github-claim]"; printf -- '---\ntype: ticket\nsource_id: "acme/web#1"\n---\n' > "$ITEM"
GH_STUB_STATUS="" mkissue 1
claim claim; eq "an issue not on the board is added, then moved" "0|tom|In Progress|1" "$?|$(state 1)|$(grep -c '^ADD 1' "$REQ_LOG")"

reset; write_config "[github-claim]"; printf -- '---\ntype: ticket\nsource_id: "acme/web#1"\n---\n' > "$ITEM"
echo other > "$ST/1.assignees"
claim claim; eq "race lost before the claim: skip, no writes" "3|0" "$?|$(writes)"

reset; write_config "[github-claim]"; printf -- '---\ntype: ticket\nsource_id: "acme/web#1"\n---\n' > "$ITEM"
touch "$ST/race_on_assign"
claim claim; eq "race lost during the claim exits 3" "3" "$?"
eq "only my own assignment is undone" "other" "$(cat "$ST/1.assignees")"
claim release; eq "release refuses after a lost race" "3" "$?"

reset; write_config "[github-claim]"; printf -- '---\ntype: ticket\nsource_id: "acme/web#1"\n---\n' > "$ITEM"
echo CLOSED > "$ST/1.state"
claim claim; eq "a closed issue is skipped" "3|0" "$?|$(writes)"

reset; write_config "[github-claim]"; printf -- '---\ntype: ticket\nsource_id: "acme/web#1"\n---\n' > "$ITEM"
claim claim; echo Done > "$ST/1.status"; : > "$REQ_LOG"
claim release
eq "release leaves a status someone else changed" "|Done|1" "$(state 1)|$(grep -c '^UNASSIGN' "$REQ_LOG")"

reset; write_config "[github-claim]"; printf -- '---\ntype: ticket\nsource_id: "acme/web#2"\n---\n' > "$ITEM"
claim claim; eq "key must match the item's source_id" "2|0" "$?|$(writes)"
reset; write_config "[github-claim]"; printf -- '---\ntype: ticket\nsource_id: "evil/other#1"\n---\n' > "$ITEM"
bash "$CLAIM" claim --job web.auto --rule ready --key "evil/other#1" --item "$ITEM" --run-id r1 2>/dev/null
eq "a repo outside the project is refused" "2|0" "$?|$(writes)"

echo "== job: gate"
reset; write_config "[implement]"
run_job; eq "exits ok" "0" "$?"
ITEM="$(drafts)"
case "$ITEM" in *-ticket-gh-1.md) ok "first eligible issue queued in drafts/" ;; *) bad "drafts/ holds [$ITEM]" ;; esac
eq "item fields" "github|acme/web#1|#1|true|web.auto|ready|drafted" \
  "$(for k in source source_id ticket_key autopilot autopilot_job autopilot_rule status; do awk -F': ' -v k=$k '$1==k {gsub(/"/,"",$2); printf "%s|", $2}' "$Q/drafts/$ITEM"; done | sed 's/|$//')"
eq "ledger records the pick with its tracker" "${ITEM}	web.auto	ready	acme/web#1	github" "$(cat "$EA_AGENT_DIR/state/autopilot-items.tsv")"
grep -q -- "--item-id ${ITEM} --source-url https://github.com/acme/web/issues/1" "$NOTIFY_LOG" \
  && ok "Approve/Reject push sent" || bad "Approve/Reject push ($(cat "$NOTIFY_LOG"))"
eq "nothing claimed, nothing implemented" "0|0" "$(writes)|$(grep -c . "$CLAUDE_LOG")"
: > "$ST/queries"; run_job
eq "a pick awaiting a decision blocks the next pick" "0|0" "$(cat "$TMP/items")|$(grep -c . "$ST/queries")"

echo "== job: trusted authorship"
untrusted_case() {  # untrusted_case <name> <reason> [trusted_authors]
  write_config "[implement, github-claim]" "{ project_statuses: [Ready] }" "${3-[lead, tom]}"
  run_job
  eq "$1: nothing claimed or implemented" "0|0" "$(writes)|$(grep -c . "$CLAUDE_LOG")"
  grep -qF "$2" "$NOTIFY_LOG" && grep -q -- "--item-id" "$NOTIFY_LOG" && ok "$1: pushed for Approve with the reason" || bad "$1: push ($(cat "$NOTIFY_LOG"))"
  grep -qF "Unattended run not allowed: $2" "$Q/drafts/"*.md && ok "$1: reason shown at the gate" || bad "$1: reason in item"
  eq "$1: no ticket text kept for the review guard" 0 "$(find "$EA_AGENT_DIR/state" -name ticket.md 2>/dev/null | wc -l | tr -d ' ')"
}
reset; mkissue 1 stranger "ready"
untrusted_case "untrusted author" "created by stranger, not a trusted author"
reset; mkissue 1 lead "" '.userContentEdits = {totalCount: 1, nodes: [{editor: {login: "stranger"}}]}'
untrusted_case "body edited by an untrusted login" "edited by stranger, not a trusted author"
reset; mkissue 1 lead "" '.edits = {totalCount: 1, nodes: [{__typename: "RenamedTitleEvent", actor: {login: "stranger"}}]}'
untrusted_case "title renamed by an untrusted login" "edited by stranger, not a trusted author"
reset; mkissue 1 lead "" '.edits = {totalCount: 1, nodes: [{__typename: "LabeledEvent", actor: null}]}'
untrusted_case "labeled by a deleted account" "edited by (deleted user), not a trusted author"
reset; mkissue 1 lead "" '.userContentEdits = {totalCount: 200, nodes: []}'
untrusted_case "truncated edit history" "edit history truncated; cannot verify edits"
reset
untrusted_case "no trusted_authors" "no trusted_authors configured" "[]"

echo "== job: full autonomy"
reset; mkissue 1 Lead "" '.edits = {totalCount: 1, nodes: [{__typename: "LabeledEvent", actor: {login: "TOM"}}]}'
write_config "[implement, github-claim]"
run_job; eq "implemented run exits ok" "0" "$?"
eq "issue claimed and moved (logins compared case-insensitively)" "tom|In Progress" "$(state 1)"
case "$(ls "$Q/completed")" in *-ticket-gh-1.md) ok "completed/ record present" ;; *) bad "completed/ holds [$(ls "$Q/completed")]" ;; esac
eq "drafts/ reconciled" "" "$(drafts)"
eq "the trusted ticket text is kept for the review guard" "$(printf '# Fix thing 1\n\nDo it.\n- [ ] works')" \
  "$(cat "$EA_AGENT_DIR/state/pr-pipeline/$(ls "$Q/completed" | sed "s/\.md$//")/ticket.md" 2>/dev/null)"
grep -q "Autopilot implemented acme/web#1" "$NOTIFY_LOG" && ok "success push" || bad "success push"
for r in "Bash(gh issue view" "Bash(gh pr view" "Bash(gh pr list" "Bash(gh api" "Bash(curl"; do
  grep -qF -- "$r" "$CLAUDE_ARGS" && bad "unattended run grants $r" || ok "unattended run omits $r"
done

printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$TMP/pipeline.log" > "$TMP/bin/pipeline"; chmod +x "$TMP/bin/pipeline"
export EA_PR_PIPELINE_BIN="$TMP/bin/pipeline" EA_PR_PIPELINE_FOREGROUND=1
: > "$TMP/pipeline.log"; reset; write_config "[implement, github-claim]"; run_job
eq "no after_pr: no pipeline" "" "$(cat "$TMP/pipeline.log")"
reset; write_config "[implement, github-claim]"
awk '{print} /^        guards: /{print "        after_pr: { mark_ready: true }"}' "$EA_CONFIG_FILE" > "$TMP/c" && mv "$TMP/c" "$EA_CONFIG_FILE"
run_job
case "$(cat "$TMP/pipeline.log")" in "--item "*-ticket-gh-1.md) ok "after_pr launches the pipeline for the item" ;; *) bad "pipeline args [$(cat "$TMP/pipeline.log")]" ;; esac
: > "$TMP/pipeline.log"; reset; write_config "[implement, github-claim]"
awk '{print} /^        guards: /{print "        after_pr: { mark_ready: true }"}' "$EA_CONFIG_FILE" > "$TMP/c" && mv "$TMP/c" "$EA_CONFIG_FILE"
FAKE_IMPL=fail run_job
eq "a failed implementation launches no pipeline" "" "$(cat "$TMP/pipeline.log")"

. "$SCRIPT_DIR/lib-resume-fixture.sh"
: > "$TMP/pipeline.log"; reset; write_config "[implement, github-claim]"
awk '{print} /^        guards: /{print "        after_pr: { mark_ready: true }"}' "$EA_CONFIG_FILE" > "$TMP/c" && mv "$TMP/c" "$EA_CONFIG_FILE"
stopped_pipeline_fixture web.auto stopped-ticket-gh-9.md
PATH="$TMP/resume-bin:$PATH" run_job
eq "a stopped pipeline whose branch moved resumes, even when no new pick is allowed" \
  "--item stopped-ticket-gh-9.md --expect-head $RESUME_NEW|0" "$(cat "$TMP/pipeline.log")|$(grep -c . "$CLAUDE_LOG")"
unset EA_PR_PIPELINE_BIN EA_PR_PIPELINE_FOREGROUND

reset; write_config "[implement, github-claim]"
FAKE_IMPL=fail run_job; eq "failed implementation exits 1" "1" "$?"
eq "claim rolled back" "|Ready" "$(state 1)"
case "$(drafts)" in *-ticket-gh-1.md) ok "item left in drafts/" ;; *) bad "drafts/ holds [$(drafts)]" ;; esac
grep -q "did not complete; claim rolled back" "$TMP/errors" && ok "error recorded for the receipt" || bad "error recorded"

reset; write_config "[implement, github-claim]"; touch "$ST/race_on_assign"
run_job; eq "lost race exits ok" "0" "$?"
eq "lost race: rejected, nothing implemented, other assignee kept" "1|0|other" \
  "$(ls "$Q/rejected" | grep -c ticket-gh-1)|$(grep -c . "$CLAUDE_LOG")|$(cat "$ST/1.assignees")"

reset; write_config "[implement, github-claim]"; touch "$ST/search_fail"
run_job; eq "a failed search is an error, never a fall-through" "1|" "$?|$(drafts)"

echo "== dispatcher"
reset; write_config "[implement, github-claim]"
bash "$REPO_ROOT/scripts/jobs-tick.sh" --only web.auto --force --foreground
R="$EA_AGENT_DIR/state/jobs/web.auto.receipt"
eq "receipt ok with one item" "ok|1" "$(awk -F': ' '/^status:/ {gsub(/"/,"",$2); s=$2} /^items:/ {i=$2} END {print s "|" i}' "$R")"

echo "== listener Approve"
export EA_NTFY_SERVER="https://example.invalid" EA_NTFY_TOPIC="t" EA_NTFY_COMMAND_TOPIC="c" EA_NTFY_AUTH_TOKEN=""
msg() { jq -nc --arg id "$1" --arg m "$2" '{event:"message",id:$id,time:1,message:$m}'; }
reset; write_config "[]"
run_job; ITEM="$(drafts)"; : > "$REQ_LOG"
( source "$REPO_ROOT/scripts/approval-listener.sh"; handle_line "$(msg m1 "approve|$ITEM")" ) >/dev/null 2>&1
eq "Approve claims without the github-claim tier" "tom|In Progress" "$(state 1)"
eq "Approve implements it" "1|" "$(ls "$Q/completed" | grep -c ticket-gh-1)|$(drafts)"

reset; write_config "[]"
printf -- '---\ntype: ticket\nsource: github\nsource_id: "acme/web#2"\nproject: "web"\nautopilot: true\nautopilot_job: "web.auto"\nautopilot_rule: "ready"\n---\n' \
  > "$Q/drafts/20251110-000000-ticket-gh-2.md"
( source "$REPO_ROOT/scripts/approval-listener.sh"; handle_line "$(msg m2 "approve|20251110-000000-ticket-gh-2.md")" ) >/dev/null 2>&1
eq "frontmatter alone never triggers a GitHub claim" "0|Ready" "$(writes)|$(cat "$ST/2.status")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
