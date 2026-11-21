#!/bin/bash
# Tests for the github-issues address-feedback job: the reopened_with_feedback predicate, the
# per-reopen queue identity, the feedback trust gate, the queue item's feedback, and the branch the
# confined run lands on. Same stubs as github-implement-next.test.sh (gh is stateful; git, claude
# and notify are stubbed; the clock is frozen).
#
# Run: bash tests/github-address-feedback.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HANDLER="$REPO_ROOT/scripts/job-github-implement-next.sh"
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
export CLAUDE_ARGS="$TMP/claude.args" GIT_LOG="$TMP/git.log"
export ST="$TMP/gh" REQ_LOG="$TMP/req.log" NOTIFY_LOG="$TMP/notify.log" CLAUDE_LOG="$TMP/claude.log"
export EA_NOTIFY_BIN="$TMP/bin/notify" NOTIFY_BIN="$TMP/bin/notify" CLAUDE_BIN="$TMP/bin/claude"
mkdir -p "$ST"
gh_stub_install "$TMP/bin"

printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$NOTIFY_LOG"\n' > "$TMP/bin/notify"; chmod +x "$TMP/bin/notify"
cat > "$TMP/bin/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GIT_LOG"
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[i]}" in
    symbolic-ref) echo "origin/main"; exit 0;;
    rev-parse) echo "deadbee"; exit 0;;
    checkout) [ -n "${GIT_FAIL_CHECKOUT:-}" ] && exit 1; exit 0;;
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

R1=1762596000   # 2025-11-08T10:00:00Z, the default reopen
R2=1762682400   # 2025-11-09T10:00:00Z, a later reopen

# write_config <auto_execute> [require flow map] [action] [trusted_authors]
write_config() {
  cat > "$EA_CONFIG_FILE" <<YAML
agent:
  branch_prefix: "tom"
  autonomy:
    auto_execute: $1
projects:
  web:
    path: "$TMP/repo"
    tracker: github-issues
    github:
      owner: acme
      repos: ["web"]
    exec:
      allowed_commands:
        - "make"
    jobs:
      - id: fb
        integration: github-issues
        action: ${3-address-feedback}
        every: 30m
        trusted_authors: ${4-[lead, tom]}
        board: { owner: acme, number: 3 }
        guards: { daily_cap: 5 }
        rules:
          - name: reopened
            query: 'label:web'
            require: ${2-{ assignee: any, project_statuses: [Ready], reopened_with_feedback: true }}
            claim: { assign: self, project_status: "In Progress" }
            on_fail: { unassign: false, project_status: "Ready" }
YAML
}

# fb_issue <N> [jq filter] — an issue closed on 11-05, reopened by lead on 11-08 10:00, with one
# comment before the close and one feedback comment after the reopen, closed by merged PR #7.
fb_issue() {
  mkissue "$1" lead "" '
    .reopens = {nodes: [
      {__typename: "ClosedEvent", createdAt: "2025-11-05T10:00:00Z"},
      {__typename: "ReopenedEvent", createdAt: "2025-11-08T10:00:00Z", actor: {login: "lead"}}]}
    | .comments = {totalCount: 2, nodes: [
      {createdAt: "2025-11-04T10:00:00Z", body: "Looks good before the close", author: {login: "stranger"}, userContentEdits: {totalCount: 0, nodes: []}},
      {createdAt: "2025-11-08T11:00:00Z", body: "The button is misaligned on mobile", author: {login: "lead"}, userContentEdits: {totalCount: 0, nodes: []}}]}
    | .feedbackPrs = {nodes: [
      {number: 7, state: "MERGED", merged: true, isCrossRepository: false, headRefName: "tom/issue-1-fix", createdAt: "2025-11-02T10:00:00Z",
       repository: {nameWithOwner: "acme/web"}, headRepository: {nameWithOwner: "acme/web"}}]}'
  [ -z "${2:-}" ] || { jq "$2" "$ST/issues/$1.json" > "$ST/x" && mv "$ST/x" "$ST/issues/$1.json"; }
  echo tom > "$ST/$1.assignees"
}
OPEN_PR='.feedbackPrs.nodes += [{number: 9, state: "OPEN", merged: false, isCrossRepository: false, headRefName: "tom/issue-1-fix-thing-1", createdAt: "2025-11-03T10:00:00Z", repository: {nameWithOwner: "acme/web"}, headRepository: {nameWithOwner: "acme/web"}}]'

reset() {
  rm -rf "$Q"/*/* "$EA_AGENT_DIR/state" "$ST"/*; mkdir -p "$EA_AGENT_DIR/state" "$TMP/repo"
  : > "$REQ_LOG"; : > "$NOTIFY_LOG"; : > "$CLAUDE_LOG"; : > "$CLAUDE_ARGS"; : > "$GIT_LOG"
  fb_issue 1; echo "1" > "$ST/search"
  echo '[{"actor": {"login": "Tom"}}, {"actor": {"login": "tom"}}]' > "$ST/activity"
}
run_job() { bash "$HANDLER" --job web.fb --errors "$TMP/errors" --items "$TMP/items" 2>/dev/null; }
drafts()  { ls "$Q/drafts" | tr '\n' ' ' | sed 's/ $//'; }
done_item() { ls "$Q/completed" | head -1; }
state()   { printf '%s|%s' "$(cat "$ST/$1.assignees")" "$(cat "$ST/$1.status")"; }
valid()   { ( . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-jobs.sh"
              rows="$(jobs_enumerate)"; jobs_validate "$(printf '%s\n' "$rows" | head -1)" "$rows" ); }
verdicts() { bash "$REPO_ROOT/scripts/jobs-ctl.sh" preview web.fb 2>&1 | sed -nE 's/^  ([a-z]+\/[a-z]+#[0-9]+)  (.*)$/\1 \2/p'; }
fm_of()   { awk -F': ' -v k="$2" '$1==k {gsub(/"/,"",$2); print $2; exit}' "$1"; }
branch_row() { cat "$EA_AGENT_DIR/state/pr-pipeline/${1%.md}/feedback_branch" 2>/dev/null; }

echo "== validation"
write_config "[]"
eq "complete address-feedback job is valid" "" "$(valid)"
write_config "[]" "{ project_statuses: [Ready] }"
eq "address-feedback without the reopen predicate is refused" \
  "rule reopened: address-feedback rules need require.reopened_with_feedback: true" "$(valid)"
write_config "[]" "{ reopened_with_feedback: true, no_linked_pr: true }"
eq "no_linked_pr is refused on address-feedback" \
  "rule reopened: require.no_linked_pr cannot be used with address-feedback" "$(valid)"
write_config "[]" "{ reopened_with_feedback: true }" implement-next
eq "the reopen predicate is refused on implement-next" \
  "rule reopened: require.reopened_with_feedback is only for address-feedback jobs" "$(valid)"
write_config "[]" "{ reopened_with_feedback: yes }"
eq "the reopen predicate must be a boolean" "rule reopened: require.reopened_with_feedback 'yes' must be true or false" "$(valid)"

echo "== predicate"
reset; write_config "[]"
mkissue 1; echo tom > "$ST/1.assignees"
fb_issue 2 '.comments.nodes |= map(select(.createdAt < "2025-11-08"))'
fb_issue 3 '.reopens.nodes += [{__typename: "ClosedEvent", createdAt: "2025-11-09T10:00:00Z"}]'
fb_issue 4
echo "1 2 3 4" > "$ST/search"
eq "never reopened, no feedback, closed again, and eligible" \
  "acme/web#1 skip  reopened_with_feedback: never reopened|acme/web#2 skip  reopened_with_feedback: no comment since the last reopen|acme/web#3 skip  reopened_with_feedback: closed again since the last reopen|acme/web#4 PICK" \
  "$(verdicts | paste -sd'|' -)"

echo "== per-reopen identity"
reset; write_config "[]"
printf -- '---\ntype: ticket\nsource_id: "acme/web#1"\n---\n' > "$Q/completed/old-ticket-gh-1.md"
eq "an issue handled before its reopen is eligible again" "acme/web#1 PICK" "$(verdicts)"
printf -- '---\ntype: ticket\nsource_id: "acme/web#1@reopen-%s"\n---\n' "$R1" > "$Q/completed/fb-ticket-gh-1-feedback.md"
eq "the same reopen is never picked twice" "acme/web#1 skip  already queued (completed)" "$(verdicts)"
fb_issue 1 '.reopens.nodes += [{__typename: "ClosedEvent", createdAt: "2025-11-08T20:00:00Z"}, {__typename: "ReopenedEvent", createdAt: "2025-11-09T10:00:00Z", actor: {login: "lead"}}]
            | .comments.nodes += [{createdAt: "2025-11-09T11:00:00Z", body: "Still off", author: {login: "lead"}, userContentEdits: {totalCount: 0, nodes: []}}]'
eq "a later reopen is a new cycle" "acme/web#1 PICK" "$(verdicts)"

echo "== job: full autonomy, merged PR -> new branch"
reset; write_config "[implement, github-claim]"
run_job; eq "run exits ok" "0" "$?"
ITEM="$(done_item)"
case "$ITEM" in *-ticket-gh-1-feedback.md) ok "completed/ record present" ;; *) bad "completed/ holds [$ITEM]" ;; esac
eq "item keyed per reopen" "acme/web#1@reopen-${R1}|${R1}" \
  "$(fm_of "$Q/completed/$ITEM" source_id)|$(fm_of "$Q/completed/$ITEM" feedback_reopen)"
grep -qF "The button is misaligned on mobile" "$Q/completed/$ITEM" && ok "feedback comment in the item" || bad "feedback comment in the item"
grep -qF "Looks good before the close" "$Q/completed/$ITEM" && bad "pre-reopen comment leaked into the item" || ok "pre-reopen comment left out"
grep -qF "The button is misaligned on mobile" "$EA_AGENT_DIR/state/pr-pipeline/${ITEM%.md}/ticket.md" \
  && ok "feedback kept in the review guard's ticket text" || bad "feedback in ticket.md"
eq "ledger keeps the plain issue key" "${ITEM}	web.fb	reopened	acme/web#1	github" "$(cat "$EA_AGENT_DIR/state/autopilot-items.tsv")"
eq "new branch named from the issue and reopen, original PR remembered" \
  "new|tom/issue-1-fix-thing-1-feedback-${R1}|7" "$(branch_row "$ITEM")"
grep -qF "Create the branch 'tom/issue-1-fix-thing-1-feedback-${R1}'" "$CLAUDE_ARGS" \
  && ok "prompt names the new branch" || bad "prompt: $(cat "$CLAUDE_ARGS")"
grep -qF "references #7" "$CLAUDE_ARGS" && ok "prompt references the original PR" || bad "prompt original PR"
grep -q -- "checkout --quiet -B" "$GIT_LOG" && bad "new-branch run checked out an existing branch" || ok "new-branch run stays at the base"
eq "already mine: still assigned, moved on the board" "tom|In Progress" "$(state 1)"
grep -q "Autopilot addressed feedback on acme/web#1" "$NOTIFY_LOG" && ok "success push" || bad "success push"
: > "$CLAUDE_LOG"; run_job
eq "the next run does not pick the same reopen" "0|0" "$(cat "$TMP/items")|$(grep -c . "$CLAUDE_LOG")"

echo "== job: open PR -> push to its branch"
reset; fb_issue 1 "$OPEN_PR"; write_config "[implement, github-claim]"
run_job; ITEM="$(done_item)"
eq "open same-repo prefixed PR is reused" "reuse|tom/issue-1-fix-thing-1|9" "$(branch_row "$ITEM")"
grep -qF -- "checkout --quiet -B tom/issue-1-fix-thing-1 origin/tom/issue-1-fix-thing-1" "$GIT_LOG" \
  && ok "worktree checked out on the PR branch before the run" || bad "git: $(cat "$GIT_LOG")"
grep -qF "already checked out on 'tom/issue-1-fix-thing-1'" "$CLAUDE_ARGS" && grep -qF "do NOT open a new pull request" "$CLAUDE_ARGS" \
  && ok "prompt says commit there, no new PR" || bad "prompt: $(cat "$CLAUDE_ARGS")"
grep -qF "repos/acme/web/activity?ref=refs/heads/tom/issue-1-fix-thing-1&per_page=100" "$ST/activity_reqs" \
  && ok "pushers checked on the PR's branch" || bad "activity requests: $(cat "$ST/activity_reqs" 2>/dev/null)"

pusher_case() {  # pusher_case <name> <activity JSON, or "" for an API error>
  reset; fb_issue 1 "$OPEN_PR"; write_config "[implement, github-claim]"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$ST/activity"; else rm -f "$ST/activity"; fi
  run_job
  eq "$1: falls back to a new branch" "new|tom/issue-1-fix-thing-1-feedback-${R1}|9" "$(branch_row "$(done_item)")"
  grep -q -- "checkout --quiet -B" "$GIT_LOG" && bad "$1: the untrusted branch was checked out" || ok "$1: the branch is never checked out"
}
pusher_case "pushed by someone else" '[{"actor": {"login": "tom"}}, {"actor": {"login": "stranger"}}]'
pusher_case "pusher unknown" '[{"actor": null}]'
pusher_case "activity unavailable" ""
pusher_case "no activity recorded" '[]'
pusher_case "activity truncated" "$(jq -nc '[range(100) | {actor: {login: "tom"}}]')"

reset; fb_issue 1 "$OPEN_PR | .feedbackPrs.nodes[1].isCrossRepository = true"; write_config "[implement, github-claim]"
run_job; eq "a fork PR is never reused" "new|tom/issue-1-fix-thing-1-feedback-${R1}|9" "$(branch_row "$(done_item)")"
reset; fb_issue 1 "$OPEN_PR | .feedbackPrs.nodes[1].headRefName = \"someone/fix\""; write_config "[implement, github-claim]"
run_job; eq "a branch outside the prefix is never reused" "new|tom/issue-1-fix-thing-1-feedback-${R1}|9" "$(branch_row "$(done_item)")"
reset; fb_issue 1 "$OPEN_PR | .feedbackPrs.nodes[1].repository.nameWithOwner = \"evil/other\" | .feedbackPrs.nodes[1].headRepository.nameWithOwner = \"evil/other\""
write_config "[implement, github-claim]"
run_job; eq "a PR outside the project's repos is ignored" "new|tom/issue-1-fix-thing-1-feedback-${R1}|7" "$(branch_row "$(done_item)")"

reset; fb_issue 1 "$OPEN_PR"; write_config "[implement, github-claim]"
GIT_FAIL_CHECKOUT=1 run_job; eq "a branch that cannot be checked out fails the run" "1" "$?"
eq "nothing implemented; claim rolled back without unassigning" "0|tom|Ready" "$(grep -c . "$CLAUDE_LOG")|$(state 1)"
case "$(drafts)" in *-ticket-gh-1-feedback.md) ok "item left in drafts/" ;; *) bad "drafts/ holds [$(drafts)]" ;; esac

echo "== job: feedback trust"
untrusted_case() {  # untrusted_case <name> <reason>
  write_config "[implement, github-claim]"
  run_job
  eq "$1: nothing claimed or implemented" "0|0" "$(grep -c . "$REQ_LOG")|$(grep -c . "$CLAUDE_LOG")"
  grep -qF "Unattended run not allowed: $2" "$Q/drafts/"*.md && ok "$1: reason shown at the gate" || bad "$1: reason ($(grep -h 'not allowed' "$Q/drafts/"*.md))"
  grep -q -- "--item-id" "$NOTIFY_LOG" && ok "$1: pushed for Approve" || bad "$1: push"
}
reset; fb_issue 1 '.comments.nodes[1].author.login = "stranger"'
untrusted_case "untrusted feedback author" "feedback comment by stranger, not a trusted author"
reset; fb_issue 1 '.comments.nodes[1].userContentEdits = {totalCount: 1, nodes: [{editor: {login: "stranger"}}]}'
untrusted_case "feedback edited by an untrusted login" "feedback comment by stranger, not a trusted author"
reset; fb_issue 1 '.reopens.nodes[1].actor.login = "stranger"'
untrusted_case "untrusted reopener" "reopened by stranger, not a trusted author"
reset; fb_issue 1 '.comments.totalCount = 300 | .comments.nodes = [.comments.nodes[1]]'
untrusted_case "comment history truncated past the reopen" "comment history truncated; cannot verify feedback"
reset; fb_issue 1 '.comments.nodes[1].userContentEdits = {totalCount: 40, nodes: []}'
untrusted_case "comment edit history truncated" "comment edit history truncated; cannot verify edits"

reset; fb_issue 1 '.comments.totalCount = 300'; write_config "[implement, github-claim]"
run_job; eq "truncation before the reopen does not hide feedback" "1" "$(grep -c . "$CLAUDE_LOG")"

echo "== dispatcher"
reset; write_config "[implement, github-claim]"
bash "$REPO_ROOT/scripts/jobs-tick.sh" --only web.fb --force --foreground
R="$EA_AGENT_DIR/state/jobs/web.fb.receipt"
eq "receipt ok with one item" "ok|1" "$(awk -F': ' '/^status:/ {gsub(/"/,"",$2); s=$2} /^items:/ {i=$2} END {print s "|" i}' "$R")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
