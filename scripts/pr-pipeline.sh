#!/bin/bash
# pr-pipeline.sh — after an autopilot implementation opens a draft PR: wait for CI (with up to
# after_pr.ci.fix_attempts confined fix runs), browser-test the final head, then mark the PR ready.
#
# Usage: pr-pipeline.sh --item <queue item>
# Exit: 0 passed (marked ready, or left draft by config/tier), 1 stopped with a push, 2 not runnable.
#
# Launched detached by pr_pipeline_launch (lib-confined-run.sh) for items in the autopilot ledger
# whose job has an after_pr block. Everything that touches GitHub (find the PR, read checks and
# logs, `gh pr ready`) is bash; the two model runs get no gh verbs at all:
#   - fix run: implementation-shaped sandbox (worktree on the PR branch, build rules, git write,
#     confined-push.sh). Success = the remote branch head moved.
#   - browser run: Read/Grep + git read + Claude in Chrome against a localhost server bash started
#     from after_pr.browser.serve. Success = a final "VERDICT: pass <nonce>" line, nonce minted here.
# Marking ready requests reviews, so it needs `pr-ready` in agent.autonomy.auto_execute.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
. "${PLUGIN_ROOT}/scripts/lib-jobs.sh"
. "${PLUGIN_ROOT}/scripts/lib-confined-run.sh"
. "${PLUGIN_ROOT}/scripts/lib-secret.sh"
. "${PLUGIN_ROOT}/scripts/lib-jira-api.sh"
. "${PLUGIN_ROOT}/scripts/lib-slite-api.sh"
. "${PLUGIN_ROOT}/scripts/lib-review.sh"

ITEM="" EXPECT_HEAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --item) ITEM="$2"; shift 2 ;;
    --expect-head) EXPECT_HEAD="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$ITEM" =~ ^[A-Za-z0-9._-]+\.md$ ]] || { echo "--item must be a queue file name" >&2; exit 2; }
[[ "$EXPECT_HEAD" =~ ^([0-9a-f]{40})?$ ]] || { echo "--expect-head must be a commit sha" >&2; exit 2; }

AGENT_DIR="$EA_AGENT_DIR"
LOG_FILE="${EA_AGENT_DIR}/state/jobs.log"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "${HOME}/.local/bin/claude")}"
NOTIFY="${EA_NOTIFY_BIN:-${PLUGIN_ROOT}/scripts/notify.sh}"
QA_BUDGET_USD="${EA_QA_BUDGET_USD:-2.00}"
POLL="${EA_PR_PIPELINE_POLL:-60}"             # seconds between CI polls
NONE_GRACE="${EA_PR_PIPELINE_NONE_GRACE:-300}" # no checks reported this long => "none"
GH_TIMEOUT="${EA_POLL_CMD_TIMEOUT:-120}"
D="${PR_PIPELINE_DIR}/${ITEM%.md}"
mkdir -p "$D" "$(dirname "$LOG_FILE")"

log() { printf '%s pr-pipeline %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ITEM%.md}" "$*" >> "$LOG_FILE"; }
push_ack() { "$NOTIFY" --fyi --title "engineer-agent" --priority "$1" --message "$2" </dev/null >>"$LOG_FILE" 2>&1 || true; }
result() { printf '%s\t%s\n' "$1" "$2" > "$D/result"; log "result: $1 — $2"; }
# stop <message> — the one failure exit: record, push once, leave the PR in draft. For
# pr_pipeline_resume_stopped: stopped_head is the branch tip now (resume once it moves) and
# trusted_from the head this run started from, so every later push, the run's own fixes included,
# is checked for who made it. A stop before the run started leaves any earlier watch as it was.
START_HEAD=""
stop() {
  local h=""
  if [ -n "$START_HEAD" ]; then
    h="$(remote_head)"
    rm -f "$D/stopped_head" "$D/trusted_from"
    [ -z "$h" ] || { printf '%s\n' "$START_HEAD" > "$D/trusted_from"; printf '%s\n' "$h" > "$D/stopped_head"; }
  fi
  result stopped "$1"; push_ack urgent "⚠️ PR pipeline stopped on ${KEY:-$ITEM}${PR_URL:+ (${PR_URL})}: $1"; exit 1; }
refuse() { log "not runnable: $1"; rm -f "$D/stopped_head" "$D/trusted_from"; result refused "$1"; exit 2; }

# --- resolve: ledger -> job -> project, branch, repo, PR (all bash-derived) ------------------------
jobs_cfg_load   # here, not inside the first $(...), or every later lookup reloads and fails
row="$(autopilot_lookup "$ITEM")" || refuse "not an autopilot item"
IFS="	" read -r JOB _ KEY TRACKER <<< "$row"
IFS='|' read -r SLUG IDX _ <<< "$(jobs_enumerate | awk -F'|' -v k="$JOB" '($1 "." $3) == k { print; exit }')"
[ -n "${SLUG:-}" ] || refuse "job ${JOB} is no longer configured"
P="projects.${SLUG}.job.${IDX}.after_pr"
reason="$(jobs_validate_after_pr "$SLUG" "$IDX")" || refuse "after_pr is invalid: ${reason}"
[ -e "${AGENT_DIR}/queue/completed/${ITEM}" ] || refuse "item is not in completed/"
BRANCH="$(head -1 "$D/branch" 2>/dev/null)"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || refuse "no ticket branch recorded"
PROJECT_PATH="$(yaml_project_scalar "$SLUG" path)"
[ -d "$PROJECT_PATH" ] || refuse "project path '${PROJECT_PATH}' missing"
REPO="$(git -C "$PROJECT_PATH" config --get remote.origin.url 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/|ssh://[^/]+/)##; s#\.git$##' | tr '[:upper:]' '[:lower:]')"
_ar_member "$REPO" "$(gr_project_repos "$SLUG")" 0 || refuse "origin '${REPO}' is not one of the project's github.repos"

# One pipeline per item (mkdir is atomic; flock is not on macOS). A dead holder's lock is taken over.
if ! mkdir "$D/lock" 2>/dev/null; then
  kill -0 "$(cat "$D/lock/pid" 2>/dev/null || echo 0)" 2>/dev/null && { log "already running"; exit 0; }
fi
echo "$$" > "$D/lock/pid"

pr="$(with_timeout "$GH_TIMEOUT" gh pr list --repo "$REPO" --head "$BRANCH" --state open \
       --json number,url,isDraft,baseRefName --jq '.[] | "\(.number)\t\(.url)\t\(.isDraft)\t\(.baseRefName)"' 2>>"$LOG_FILE")"
[ "$(printf '%s' "$pr" | grep -c .)" = 1 ] || stop "expected one open PR for ${BRANCH}, found $(printf '%s' "$pr" | grep -c .)"
IFS="	" read -r PR PR_URL PR_DRAFT BASE <<< "$pr"
[[ "$PR" =~ ^[0-9]+$ ]] || stop "unreadable PR number"
# The PR's own base, not origin/HEAD: a checkout's origin/HEAD is set at clone time and can name a
# branch since deleted upstream.
[[ "$BASE" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || stop "unreadable PR base '${BASE}'"
case "$PR_URL" in "https://github.com/${REPO}/pull/${PR}") ;; *) PR_URL="https://github.com/${REPO}/pull/${PR}" ;; esac
log "PR #${PR} (${BRANCH}) in ${REPO}"
# The ticket comes from the bash-written ledger; its URL is built here, never read from a model.
case "$TRACKER" in
  jira)
    [[ "$KEY" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] || stop "ledger key '${KEY}' is not a Jira key"
    site="$(_arc agent.jira.site)"; site="${site#https://}"; site="${site#http://}"; site="${site%/}"
    TICKET_URL="https://${site}/browse/${KEY}" ;;
  *)
    [[ "$KEY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$ ]] || stop "ledger key '${KEY}' is not a GitHub issue"
    TICKET_URL="https://github.com/${KEY%%#*}/issues/${KEY##*#}" ;;
esac

BUDGET="$(_arc "$P.budget_usd")"; BUDGET="${BUDGET:-3.00}"

# --- watchdog + cleanup ---------------------------------------------------------------------------
WT="" SRV="" BT="" NEW_SHA="" WATCHDOG=""
cleanup() {
  [ -n "$SRV" ] && { jobs_kill_tree "$SRV"; wait "$SRV" 2>/dev/null; SRV=""; }
  if [ -n "$WT" ]; then
    git -C "$PROJECT_PATH" worktree remove --force "$WT" >>"$LOG_FILE" 2>&1 || true
    git -C "$PROJECT_PATH" worktree prune >>"$LOG_FILE" 2>&1 || true
    WT=""
  fi
}
inflight_begin "${ITEM%.md}.pipeline" "$SLUG"
# .done is set before the watchdog is killed: jobs_kill_tree TERMs the watchdog's sleep first, and
# without the marker the watchdog would go on to TERM us mid-exit, overwriting the real result
# with "exceeded after_pr.max_runtime".
rm -f "$D/.done"
trap 'touch "$D/.done"; [ -z "$WATCHDOG" ] || jobs_kill_tree "$WATCHDOG"; cleanup; inflight_end "${ITEM%.md}.pipeline"; rm -rf "$D/lock"' EXIT
# The watchdog kills our children too: a TERM trap waits for the foreground command to finish.
trap 'cleanup; stop "exceeded after_pr.max_runtime"' TERM
MAX="$(jobs_duration_seconds "$(_arc "$P.max_runtime")")"; MAX="${MAX:-7200}"
( me="$(self_pid)"; sleep "$MAX"
  [ -e "$D/.done" ] && exit 0
  kill -TERM "$$" 2>/dev/null
  for c in $(pgrep -P "$$" 2>/dev/null); do [ "$c" = "$me" ] || jobs_kill_tree "$c"; done
) </dev/null >/dev/null 2>&1 &
WATCHDOG=$!

# branch_worktree — a fresh worktree on the PR branch (WT). Not detached: the fix run commits to it.
branch_worktree() {
  WT="${AGENT_DIR}/worktrees/${ITEM%.md}-pr-$(date +%s)"
  mkdir -p "$(dirname "$WT")"
  git -C "$PROJECT_PATH" fetch --quiet origin "$BRANCH" >>"$LOG_FILE" 2>&1 || true
  git -C "$PROJECT_PATH" worktree add "$WT" "$BRANCH" >>"$LOG_FILE" 2>&1 || { WT=""; return 1; }
}
remote_head() { git -C "$PROJECT_PATH" ls-remote origin "refs/heads/${BRANCH}" 2>/dev/null | cut -f1; }
# base_conflicts <sha> — true only when merging origin/<base> into <sha> conflicts (merge-tree exit 1).
base_conflicts() {
  git -C "$PROJECT_PATH" fetch --quiet origin "$BASE" >>"$LOG_FILE" 2>&1 || true
  git -C "$PROJECT_PATH" merge-tree --write-tree --quiet "origin/${BASE}" "$1" >/dev/null 2>>"$LOG_FILE"
  [ $? = 1 ]
}

# --- CI -------------------------------------------------------------------------------------------
# ci_state — pass | fail | pending | none, for the PR's current head. Writes failing rows to $D/ci.fail.
ci_state() {
  local rows
  # statusCheckRollup, not `gh pr checks --json`: that flag is missing from older gh (Ubuntu 2.45).
  rows="$(with_timeout "$GH_TIMEOUT" gh pr view "$PR" --repo "$REPO" --json statusCheckRollup --jq '
    .statusCheckRollup[]? |
    (if .__typename == "StatusContext" then
       ({"SUCCESS": "pass", "PENDING": "pending", "EXPECTED": "pending"}[.state // ""] // "fail")
     elif (.status // "") != "COMPLETED" then "pending"
     else ({"SUCCESS": "pass", "NEUTRAL": "pass", "SKIPPED": "skipping", "CANCELLED": "cancel"}[.conclusion // ""] // "fail")
     end) as $b
    | "\($b)\t\(.name // .context // "")\t\(.detailsUrl // .targetUrl // "")\t\((.description // "") | gsub("[\t\n]"; " "))"' 2>/dev/null)"
  [ -n "$rows" ] || { echo none; return; }
  printf '%s\n' "$rows" | awk -F'\t' '$1=="fail" || $1=="cancel"' > "$D/ci.fail"
  if printf '%s\n' "$rows" | awk -F'\t' '$1=="pending"{f=1} END{exit !f}'; then echo pending
  elif [ -s "$D/ci.fail" ]; then echo fail
  else echo pass; fi
}
# ci_wait <sha> — waits for checks on <sha>; prints pass | fail | none | timeout.
ci_wait() {
  local sha="$1" start now head st deadline t
  t="$(jobs_duration_seconds "$(_arc "$P.ci.timeout")")"
  start="$(date +%s)"; deadline=$(( start + ${t:-1800} ))
  while :; do
    head="$(with_timeout "$GH_TIMEOUT" gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null)"
    if [ "$head" = "$sha" ]; then
      st="$(ci_state)"
      case "$st" in pass|fail) echo "$st"; return ;; esac
      now="$(date +%s)"
      [ "$st" = none ] && [ $(( now - start )) -ge "$NONE_GRACE" ] && { echo none; return; }
    fi
    now="$(date +%s)"
    [ "$now" -lt "$deadline" ] || { echo timeout; return; }
    sleep "$POLL"
  done
}

# ci_logs — failing checks (with a commit status's description, the only log a non-Actions CI
# exposes to gh) and the tail of each failed Actions run's log, into $D/ci-failure.log.
ci_logs() {
  local name link desc run
  : > "$D/ci-failure.log"
  while IFS="	" read -r _ name link desc; do
    printf '=== FAILED CHECK: %s (%s)%s\n' "$name" "$link" "${desc:+: $desc}" >> "$D/ci-failure.log"
  done < "$D/ci.fail"
  sed -nE 's#.*/actions/runs/([0-9]+).*#\1#p' "$D/ci.fail" | sort -u | while IFS= read -r run; do
    printf '\n=== LOG (failed steps) for run %s\n' "$run" >> "$D/ci-failure.log"
    with_timeout "$GH_TIMEOUT" gh run view "$run" --repo "$REPO" --log-failed 2>&1 | tail -n 400 >> "$D/ci-failure.log"
  done
}

# fix_run <task> — one confined fix attempt on the branch; sets NEW_SHA to the new remote head, or
# empty. <task> says what to fix and where its evidence is. Globals, not $(...): a subshell would
# not run cleanup when the watchdog fires.
fix_run() {
  local before after
  NEW_SHA=""
  before="$(remote_head)"
  branch_worktree || { log "could not create a worktree on ${BRANCH}"; return 0; }
  prepare_run_worktree "$SLUG" "$WT"
  project_build_rules "$SLUG"
  project_validate_command "$SLUG"
  local tools=( Read Edit Write Glob Grep "${CONFINED_GIT_WRITE_RULES[@]}" ${BUILD_RULES[@]+"${BUILD_RULES[@]}"} "Bash(echo:*)" )
  local merge=""
  # Bash starts the merge (the run has no `git merge`); the run resolves and finishes it with `git commit`.
  if [ "${MERGE_BASE:-0}" = 1 ]; then
    git -C "$WT" merge --no-edit "origin/${BASE}" >>"$LOG_FILE" 2>&1
    if [ -f "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ]; then
      git -C "$WT" diff --name-only --diff-filter=U > "$D/merge-conflicts.txt"
      merge="A merge of origin/${BASE} into this branch is in progress: the branch conflicts with it, so CI cannot build it. Resolve every conflict first (files: ${D}/merge-conflicts.txt). Where origin/${BASE} already does what the branch did, keep its version and adapt the branch's code to it; check that the merged files don't define anything twice and that nothing still refers to code the resolution dropped. Then \`git add\` them and \`git commit --no-edit\` to finish the merge, before fixing anything else. "
    fi
  fi
  local prompt="${merge}$1 \
The current working directory is a git worktree checked out on ${BRANCH}; stay inside it. Reproduce the problem with the project's build/test commands where you can, fix the root cause, and commit. \
$(validation_prompt) \
Never skip, delete or weaken a test, lint rule or type check, and never suppress a finding instead of fixing it. Do not edit CI configuration. \
PUSH ONLY with: ${PLUGIN_ROOT}/scripts/confined-push.sh --no-verify (plain git push is denied). Do not open, edit or comment on PRs. \
${NO_MEMORY_RULE} Be concise."
  log "fix run on ${BRANCH} (budget ${BUDGET})"
  ( cd "$WT" && "$CLAUDE_BIN" -p --plugin-dir "$PLUGIN_ROOT" --model sonnet --permission-mode acceptEdits \
      --allowedTools "${tools[@]}" --max-budget-usd "$BUDGET" "$prompt" </dev/null ) >> "$LOG_FILE" 2>&1
  cleanup
  after="$(remote_head)"
  [ -n "$after" ] && [ "$after" != "$before" ] && NEW_SHA="$after"
  return 0
}

# --- browser --------------------------------------------------------------------------------------
CHROME_TOOLS=(
  mcp__claude-in-chrome__tabs_context_mcp mcp__claude-in-chrome__tabs_create_mcp
  mcp__claude-in-chrome__tabs_close_mcp mcp__claude-in-chrome__navigate mcp__claude-in-chrome__computer
  mcp__claude-in-chrome__read_page mcp__claude-in-chrome__get_page_text mcp__claude-in-chrome__find
  mcp__claude-in-chrome__form_input mcp__claude-in-chrome__read_console_messages
  mcp__claude-in-chrome__read_network_requests mcp__claude-in-chrome__resize_window
)

# browser_test — sets BT to pass | fail | <reason it could not run>. Report in $D/browser-report.md.
# serve_branch — run browser.setup then browser.serve in WT until browser.url answers. Sets SRV;
# rc 1 with SERVE_ERR otherwise (the caller cleans up).
serve_branch() {
  local url setup serve ready t0 code
  url="$(_arc "$P.browser.url")"; setup="$(_arc "$P.browser.setup")"; serve="$(_arc "$P.browser.serve")"
  ready="$(jobs_duration_seconds "$(_arc "$P.browser.ready_timeout")")"; ready="${ready:-180}"
  if [ -n "$setup" ]; then
    ( cd "$WT" && with_timeout 1200 bash -c "$setup" ) </dev/null >> "$D/serve.log" 2>&1 \
      || { SERVE_ERR="browser.setup failed (see ${D}/serve.log)"; return 1; }
  fi
  ( cd "$WT" && exec bash -c "$serve" ) </dev/null >> "$D/serve.log" 2>&1 &
  SRV=$!
  t0="$(date +%s)"
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)"
    [[ "$code" =~ ^[234] ]] && return 0
    kill -0 "$SRV" 2>/dev/null || { SERVE_ERR="browser.serve exited before ${url} answered (see ${D}/serve.log)"; return 1; }
    [ $(( $(date +%s) - t0 )) -lt "$ready" ] || { SERVE_ERR="${url} did not answer within ${ready}s"; return 1; }
    sleep "$(( POLL < 5 ? POLL : 5 ))"
  done
}

browser_test() {
  local url nonce instr dev
  url="$(_arc "$P.browser.url")"
  instr="$(_arc "$P.browser.instructions")"
  # Claude in Chrome drives whichever connected browser was picked last, which may be on another
  # machine where localhost is not this one. chrome_device pins it.
  dev="$(_arc "$P.browser.chrome_device")"
  [ -z "$dev" ] || instr="FIRST call mcp__claude-in-chrome__select_browser with deviceId ${dev}; if that fails, stop: the verdict is fail. ${instr}"
  branch_worktree || { BT="could not create a worktree on ${BRANCH}"; return; }
  serve_branch || { cleanup; BT="$SERVE_ERR"; return; }
  nonce="$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
  local tools=( Read Glob Grep "${CONFINED_GIT_READ_RULES[@]}" "${CHROME_TOOLS[@]}" )
  # Only with a pinned (dedicated) device: page text could otherwise steer the run onto another
  # connected browser, or run JS in a tab with your sign-ins. Checked against the transcript below.
  [ -z "$dev" ] || tools+=( mcp__claude-in-chrome__select_browser mcp__claude-in-chrome__javascript_tool )
  local prompt="Browser-test the change on this branch before it goes to review. The ticket, with its acceptance criteria, is the queue item ${AGENT_DIR}/queue/completed/${ITEM}; the change is \`git diff origin/${BASE}...HEAD\` in the current directory. \
The branch is being served at ${url}. Use the Claude in Chrome tools: open a NEW tab, visit only URLs under ${url}, and close your tab when done. ${instr} \
Exercise every acceptance criterion and the UI the diff touches, and check the console for errors. Do not modify any file. \
Reply with a short report (what you checked, pass/fail per criterion, problems found), then a final line that is exactly 'VERDICT: pass ${nonce}' or 'VERDICT: fail ${nonce}'. If you could not test something that matters, the verdict is fail. \
${NO_MEMORY_RULE}"
  log "browser test at ${url} (budget ${BUDGET})"
  ( cd "$WT" && "$CLAUDE_BIN" -p --chrome --plugin-dir "$PLUGIN_ROOT" --model sonnet --permission-mode default \
      --allowedTools "${tools[@]}" --output-format stream-json --verbose --max-budget-usd "$BUDGET" "$prompt" \
      </dev/null ) > "$D/browser-run.jsonl" 2>>"$LOG_FILE"
  cleanup
  jq -r 'select(.type == "result") | .result // empty' "$D/browser-run.jsonl" > "$D/browser-report.md" 2>/dev/null
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
         | select(.name | startswith("mcp__claude-in-chrome__"))
         | if .name == "mcp__claude-in-chrome__select_browser" then "select\t\(.input.deviceId // "")"
           elif .name == "mcp__claude-in-chrome__navigate" then "nav\t\(.input.url // "")"
           else "use\t" end' \
      "$D/browser-run.jsonl" > "$D/browser-calls" 2>/dev/null
  # Every navigation must stay on the served origin. Clicked links aren't visible in the transcript;
  # this catches the run being told to go elsewhere.
  local origin bad
  origin="$(printf '%s' "$url" | sed -E 's#^(https?://[^/?#]+).*#\1#')"
  bad="$(awk -F'\t' -v o="$origin" '$1 == "nav" && $2 != "back" && $2 != "forward" \
           && $2 != o && index($2, o "/") != 1 && index($2, o "?") != 1 && index($2, o "#") != 1 \
           { print $2; exit }' "$D/browser-calls")"
  [ -z "$bad" ] || { BT="the browser run navigated outside ${origin}: ${bad}"; return; }
  if [ -n "$dev" ]; then
    # The first Chrome call must select the pinned device, and no call may select another.
    if [ "$(head -1 "$D/browser-calls")" != "select	${dev}" ] \
       || awk -F'\t' -v d="$dev" '$1 == "select" && $2 != d {f=1} END {exit !f}' "$D/browser-calls"; then
      BT="the browser run did not stay on chrome_device ${dev} (see ${D}/browser-run.jsonl)"; return
    fi
  fi
  case "$(grep -E "^VERDICT: (pass|fail) ${nonce}\$" "$D/browser-report.md" | tail -1 | cut -d' ' -f2)" in
    pass) BT=pass ;;
    fail) BT=fail ;;
    *)    BT="the browser run gave no verdict (see ${D}/browser-report.md)" ;;
  esac
}

# --- QA -------------------------------------------------------------------------------------------
# _section <file> <heading> — the body under "## <heading>" up to the next "## ".
_section() { awk -v h="## $2" '$0 == h {f=1; next} /^## / {f=0} f' "$1"; }

# qa_stage — one confined run writes the plan from the trust-checked queue item and the diff (it
# never re-fetches the ticket and gets no tracker, gh or network verb). Success = the plan has its
# three sections and ends with this run's nonce. With browser.serve, bash runs the scripted block
# against the served branch. Sets QA_PASS, QA_FAIL, QA_AUTO, QA_MANUAL.
qa_stage() {
  local plan="$D/qa/plan.md" nonce url last
  rm -rf "$D/qa"; mkdir -p "$D/qa"
  branch_worktree || stop "QA: could not create a worktree on ${BRANCH}"
  nonce="$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
  # Reads are scoped to the worktree, the one queue item and the diff bash wrote: whatever it reads
  # can end up published. No git verb at all — `git diff --no-index` reads any file.
  git -C "$WT" diff "origin/${BASE}...HEAD" > "$D/qa/change.diff" 2>>"$LOG_FILE" \
    || { cleanup; stop "QA: could not diff the branch against origin/${BASE}"; }
  local tools=( "Read(/${WT}/**)" "Read(/${AGENT_DIR}/queue/completed/${ITEM})" "Read(/${D}/qa/change.diff)" "Edit(/${plan})" )
  local prompt="Write a QA plan for the change on this branch. The ticket, with its acceptance criteria, is the queue item ${AGENT_DIR}/queue/completed/${ITEM}; the change is the diff in ${D}/qa/change.diff, and the current directory is the branch. \
Write the plan to ${plan} (a new file; it is the only file you may write) with exactly these sections: \
'## Summary' — 2 to 5 sentences: what changed and how each acceptance criterion is covered, no links; \
'## Scripted Tests' — one \`\`\`json block: an array of at most 50 HTTP checks against the running app, each {\"name\", \"method\" (GET, POST, PUT, PATCH, DELETE or HEAD), \"path\" (starting with /), optional \"body\" (JSON), \"expect_status\", optional \"expect_contains\"}; \
'## Manual Checklist' — '- [ ] ' items only a person can judge. \
End the file with the line 'QA-NONCE: ${nonce}'. ${NO_MEMORY_RULE} Be concise."
  log "QA run on ${sha:0:7} (budget ${QA_BUDGET_USD})"
  ( cd "$WT" && "$CLAUDE_BIN" -p --plugin-dir "$PLUGIN_ROOT" --model sonnet --permission-mode default \
      --allowedTools "${tools[@]}" --max-budget-usd "$QA_BUDGET_USD" "$prompt" </dev/null ) >> "$LOG_FILE" 2>&1
  last="$(grep -v '^[[:space:]]*$' "$plan" 2>/dev/null | tail -1)"
  if [ "$last" != "QA-NONCE: ${nonce}" ] || ! grep -qx '## Summary' "$plan" \
     || ! grep -qx '## Scripted Tests' "$plan" || ! grep -qx '## Manual Checklist' "$plan"; then
    cleanup; stop "QA run produced no plan"
  fi
  QA_MANUAL="$(_section "$plan" "Manual Checklist" | grep -c '^- \[ \]')"
  QA_PASS=0 QA_FAIL=0 QA_AUTO="Automated: not executed — no local server"
  _section "$plan" "Scripted Tests" | awk '/^```/ { if (f) exit; f = 1; next } f' > "$D/qa/checks.json"
  jq -e 'type == "array"' "$D/qa/checks.json" >/dev/null 2>&1 || : > "$D/qa/checks.json"
  if [ -n "$(_arc "$P.browser.serve")" ]; then
    if [ ! -s "$D/qa/checks.json" ]; then
      QA_AUTO="Automated: not executed — the plan's checks are not a JSON list"
    elif serve_branch; then
      url="$(_arc "$P.browser.url")"
      qa_checks "$D/qa/checks.json" "$url" > "$D/qa/tests.out"
      QA_PASS="$(grep -c '^PASS: ' "$D/qa/tests.out")"; QA_FAIL="$(grep -c '^FAIL: ' "$D/qa/tests.out")"
      QA_AUTO="Automated: ${QA_PASS} passed, ${QA_FAIL} failed"
    else
      QA_AUTO="Automated: not executed — ${SERVE_ERR}"
    fi
  fi
  cleanup
}

# qa_checks <checks.json> <base-url> — the plan's checks are data, never shell: each is one curl
# to <base-url><path> with an allowlisted method; a body goes on stdin (so "@file" is just text).
# Prints PASS:/FAIL: lines.
qa_checks() {
  local c name method path want contains code
  local re='^/[A-Za-z0-9._~/?=&%:+,@-]*$'
  jq -c '.[:50][]' "$1" | while IFS= read -r c; do
    name="$(printf '%s' "$c" | jq -r '.name // "unnamed" | tostring' | tr -cd '[:print:]' | cut -c1-120)"
    method="$(printf '%s' "$c" | jq -r '.method // "GET" | tostring')"
    path="$(printf '%s' "$c" | jq -r '.path // "" | tostring')"
    want="$(printf '%s' "$c" | jq -r '.expect_status // 200 | tostring')"
    contains="$(printf '%s' "$c" | jq -r '.expect_contains // "" | tostring')"
    case "$method" in GET|POST|PUT|PATCH|DELETE|HEAD) ;; *) echo "FAIL: ${name} (invalid check)"; continue ;; esac
    if ! [[ "$path" =~ $re ]] || [[ "$path" == *..* ]] || ! [[ "$want" =~ ^[0-9]{3}$ ]]; then
      echo "FAIL: ${name} (invalid check)"; continue
    fi
    : > "$D/qa/resp"
    if printf '%s' "$c" | jq -e 'has("body")' >/dev/null; then
      code="$(printf '%s' "$c" | jq -c '.body' | curl -s -o "$D/qa/resp" -w '%{http_code}' --max-time 20 -X "$method" \
                -H 'Content-Type: application/json' --data-binary @- "${2}${path}" 2>/dev/null)"
    else
      code="$(curl -s -o "$D/qa/resp" -w '%{http_code}' --max-time 20 -X "$method" "${2}${path}" </dev/null 2>/dev/null)"
    fi
    if [ "$code" != "$want" ]; then echo "FAIL: ${name} (expected ${want}, got ${code:-no response})"
    elif [ -n "$contains" ] && ! grep -qF -- "$contains" "$D/qa/resp"; then echo "FAIL: ${name} (response lacks the expected text)"
    else echo "PASS: ${name}"; fi
  done
}

# qa_note_md — the Slite note, rebuilt from validated parts only: bash header, neutralized summary,
# the jq-validated checks (in a code block), "- [ ]" checklist lines, and the harness results.
qa_note_md() {
  local plan="$D/qa/plan.md"
  printf '**Ticket:** %s\n**PR:** %s\n**Branch:** %s (%s)\n**Run:** %s\n\n## Summary\n\n' \
    "$TICKET_URL" "$PR_URL" "$BRANCH" "${sha:0:7}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _section "$plan" "Summary" | _neutral | head -c 2000
  printf '\n\n## Scripted Tests\n\n%s\n' "$QA_AUTO"
  if [ -s "$D/qa/checks.json" ]; then
    printf '\n```json\n'
    # Rebuilt from the documented keys only (a model-chosen key is text too); bodies as JSON text.
    jq 'def inert: gsub("[\\[\\]()<>`|]"; "") | gsub("[A-Za-z][A-Za-z0-9+.-]*://\\S*"; "[link removed]")
                   | gsub("[Ww][Ww][Ww]\\.\\S*"; "[link removed]") | .[:200];
        .[:50] | map(if type == "object" then
          {name, method, path, body: (if has("body") then (.body | tojson) else null end), expect_status, expect_contains}
          | with_entries(select(.value != null))
          | with_entries(.value |= (if type == "string" then inert elif type == "number" then . else "[omitted]" end))
        else "[omitted]" end)' "$D/qa/checks.json"
    printf '```\n'
  fi
  [ -s "$D/qa/tests.out" ] && { printf '\n```\n'; _neutral < "$D/qa/tests.out"; printf '```\n'; }
  printf '\n## Manual Checklist (skipped, unattended)\n\n'
  _section "$plan" "Manual Checklist" | sed -n 's/^- \[ \] //p' | _neutral | head -n 50 | sed 's/^/- [ ] /'
}

# qa_publish — Slite note (qa.document), then the same bash-composed comment on the PR and, for
# Jira, the ticket. Model text reaches them only neutralized and capped. A failed scripted test
# stops after publishing, so the evidence is on the PR.
qa_publish() {
  local plan="$D/qa/plan.md" c="$D/qa/comment.md" body code skipped NOTE_URL=""
  if [ "$(_arc "$P.qa.document")" = true ]; then
    slite_init "$(_arc agent.slite.api_base)" "$(_arc agent.slite.api_key_env)" "$(_arc agent.slite.api_key_file)" \
      || stop "QA: ${SLITE_ERR}"
    body="$(jq -n --arg t "QA Plan: ${KEY} (${BRANCH})" --arg p "$(_arc "projects.${SLUG}.qa.document_parent")" \
      --arg md "$(qa_note_md)" '{title: $t, parentNoteId: $p, markdown: $md}')"
    TMPD="$D/qa"; code="$(slite_api "$D/qa/note.json" /notes POST "$body")"
    [[ "$code" =~ ^20[01]$ ]] || stop "QA: Slite note failed (HTTP ${code})"
    NOTE_URL="$(jq -r '.url // empty' "$D/qa/note.json")"
    [ -n "$NOTE_URL" ] || NOTE_URL="https://app.slite.com/api/s/$(jq -r '.id // empty' "$D/qa/note.json")"
  fi
  {
    printf 'QA summary for %s\n\n' "$KEY"
    _section "$plan" "Summary" | _neutral | head -c 2000
    printf '\n\n%s\nManual checks: %s skipped (unattended)\n' "$QA_AUTO" "$QA_MANUAL"
    skipped="$(jq length "$D/security/skipped.json" 2>/dev/null)"
    [ -z "$skipped" ] || [ "$skipped" = 0 ] || printf 'Security: %s pre-existing finding(s) skipped\n' "$skipped"
    [ -z "$NOTE_URL" ] || printf 'Full plan: %s\n' "$NOTE_URL"
  } > "$c"
  with_timeout "$GH_TIMEOUT" gh pr comment "$PR" --repo "$REPO" --body-file "$c" >>"$LOG_FILE" 2>&1 \
    || stop "QA: PR comment failed"
  if [ "$TRACKER" = jira ]; then
    ar_jira_init || stop "QA: ${AR_ERR}"
    TMPD="$D/qa"; jira_add_comment "$KEY" "$c" || stop "QA: Jira comment failed (HTTP ${JIRA_HTTP})"
  fi
  log "QA published${NOTE_URL:+ (${NOTE_URL})}"
  [ "$QA_FAIL" = 0 ] || stop "QA: ${QA_FAIL} scripted test(s) failed — plan: ${NOTE_URL:-$plan}"
}

# --- security (security.command adapter) -----------------------------------------------------------

pr_head() { with_timeout "$GH_TIMEOUT" gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null; }

# security_stage — review, fix what the PR introduced, re-review; up to security.fix_attempts
# rounds. Advances sha on a fix and sets REVIEWED_SHA to the head that came back clean (or, with
# security.review_last_fix: false, to the last fix's head, unreviewed). Stops on
# anything left, when a review cannot run, or when the head moved under a review (the adapter
# reviews the PR's head at that moment, so the verdict would belong to another commit).
security_stage() {
  local cmd to tries round=0 fixes=0 rc out intro count
  cmd="$(_arc "$P.security.command")"; cmd="${cmd/#\~/$HOME}"
  [ -f "$cmd" ] && [ -x "$cmd" ] || stop "security.command '${cmd}' is not executable"
  to="$(jobs_duration_seconds "$(_arc "$P.security.timeout")")"; to="${to:-1800}"
  tries="$(_arc "$P.security.fix_attempts")"; tries="${tries:-1}"
  mkdir -p "$D/security"
  while :; do
    round=$((round+1)); out="$D/security/round${round}"
    log "security review ${round} on ${sha:0:7}"
    mkdir -p "$out"
    with_timeout "$to" "$cmd" "$REPO" "$PR" "$out" </dev/null >"$out/run.log" 2>&1; rc=$?
    case "$rc" in
      0) ;;
      3) stop "security review needs authentication (security.command exit 3; log: ${out}/run.log)" ;;
      *) stop "security review failed (exit ${rc})" ;;
    esac
    [ "$(pr_head)" = "$sha" ] || stop "the PR head moved during the security review"
    git -C "$PROJECT_PATH" fetch --quiet origin "$BASE" "$BRANCH" >>"$LOG_FILE" 2>&1 || true
    git -C "$PROJECT_PATH" diff --name-only "origin/${BASE}...${sha}" > "$D/security/changed" 2>>"$LOG_FILE" \
      || stop "could not diff ${sha:0:7} against origin/${BASE}"
    intro="$(security_introduced "$out/findings.json" "$D/security/changed")" || stop "unreadable security findings (${out}/findings.json)"
    jq --argjson i "$intro" '[.[] | select(. as $f | $i | index([$f]) | not)]' "$out/findings.json" > "$D/security/skipped.json"
    count="$(printf '%s' "$intro" | jq length)"
    log "security review ${round}: ${count} introduced, $(jq length "$D/security/skipped.json") skipped"
    [ "$count" -gt 0 ] || { REVIEWED_SHA="$sha"; return 0; }
    [ "$fixes" -lt "$tries" ] \
      || stop "security review: ${count} introduced finding(s) remain after ${fixes} fix attempt(s): $(printf '%s' "$intro" | jq -r '[.[].title] | join("; ")') — report: ${out}/report.md"
    printf '%s' "$intro" | jq -r '.[] | "## \(.title // "untitled")\n- severity: \(.severity // "?")\n- file: \(.file // "?")\n- CWE: \(.cwe // "?")\n- impact: \(.impact // "")\n- evidence:\n```\n\(.evidence // "")\n```\n- remediation: \(.remediation // "")\n"' \
      > "$D/security/introduced.md"
    fixes=$((fixes+1))
    fix_run "A security review of pull request #${PR} (branch ${BRANCH}) found ${count} issue(s) this change introduced, listed in ${D}/security/introduced.md — read it first. Fix every one in the code (add a regression test where the remediation calls for one); the full report is ${out}/report.md."
    [ -n "$NEW_SHA" ] || stop "security fix attempt ${fixes} pushed nothing"
    sha="$NEW_SHA"
    if [ "$fixes" -ge "$tries" ] && [ "$(_arc "$P.security.review_last_fix")" = false ]; then
      log "security fix ${fixes} on ${sha:0:7} not re-reviewed (review_last_fix: false)"
      REVIEWED_SHA="$sha"; return 0
    fi
  done
}

# --- run ------------------------------------------------------------------------------------------
sha="$(pr_head)"
[ -n "$sha" ] || stop "could not read the PR head"
# A resume names the head whose pushers it checked; anything else is left for the next sweep.
if [ -n "$EXPECT_HEAD" ] && [ "$sha" != "$EXPECT_HEAD" ]; then
  log "the PR head is ${sha:0:7}, not the checked ${EXPECT_HEAD:0:7}; leaving it to the next sweep"
  exit 0
fi
START_HEAD="$sha"
rm -f "$D/stopped_head" "$D/trusted_from"
HOLD=""   # review stages skipped for a missing tier: the PR must not reach reviewers
SEC=0 REVIEWED_SHA=""
if [ -n "$(_ar_children "$P.security")" ]; then
  if jobs_autonomy_allows security-review; then SEC=1
  else HOLD="${HOLD}${HOLD:+, }security review (add security-review to autonomy.auto_execute)"; fi
fi
attempts="$(_arc "$P.ci.fix_attempts")"; attempts="${attempts:-1}"
n=0 pass=0
# Security and CI must both pass on the SAME head: a CI fix commit is reviewed again, and a security
# fix commit goes through CI again. Bounded, since each fix can provoke the other.
while :; do
  [ "$SEC" = 1 ] && [ "$sha" != "$REVIEWED_SHA" ] && security_stage
  while :; do
    ci="$(ci_wait "$sha")"
    log "CI on ${sha:0:7}: ${ci}"
    [ "$ci" = fail ] && [ "$n" -lt "$attempts" ] || break
    n=$((n+1))
    ci_logs
    MERGE_BASE=0
    if base_conflicts "$sha"; then
      MERGE_BASE=1; log "CI failed and ${sha:0:7} conflicts with origin/${BASE}: the fix run merges it first"
    fi
    fix_run "CI failed on pull request #${PR} for branch ${BRANCH}. The failing checks and the tail of their logs are in ${D}/ci-failure.log — read it first."
    MERGE_BASE=0
    [ -n "$NEW_SHA" ] || stop "CI failed and fix attempt ${n} pushed nothing"
    sha="$NEW_SHA"
  done
  case "$ci" in
    pass) ;;
    fail)    stop "CI still failing after ${n} fix attempt(s): $(cut -f2 "$D/ci.fail" | paste -sd, -)" ;;
    none)    stop "no CI checks reported on the PR" ;;
    timeout) stop "CI did not finish within after_pr.ci.timeout" ;;
  esac
  [ "$SEC" = 1 ] && [ "$sha" != "$REVIEWED_SHA" ] || break
  pass=$((pass+1))
  [ "$pass" -lt 3 ] || stop "fixes kept moving the head: CI and the security review never passed on the same commit"
done

if [ -n "$(_arc "$P.browser.serve")" ]; then
  browser_test
  case "$BT" in
    pass) log "browser test passed" ;;
    fail) stop "browser test failed — report: ${D}/browser-report.md" ;;
    *)    stop "browser test could not run: ${BT}" ;;
  esac
fi

if [ -n "$(_ar_children "$P.qa")" ]; then
  if jobs_autonomy_allows qa-publish; then qa_stage; qa_publish
  else HOLD="${HOLD}${HOLD:+, }QA (add qa-publish to autonomy.auto_execute)"; fi
fi

if [ -n "$HOLD" ]; then
  result passed "CI green; left in draft — skipped: ${HOLD}"
  push_ack normal "✅ ${KEY}: CI green, PR left in draft — skipped ${HOLD}: ${PR_URL}"
  exit 0
fi
if [ "$(_arc "$P.mark_ready")" != true ]; then
  result passed "CI green${BT:+, browser ${BT}}; mark_ready is off"
  push_ack normal "✅ ${KEY}: CI green${BT:+, browser test passed} — PR left in draft: ${PR_URL}"
  exit 0
fi
if ! jobs_autonomy_allows pr-ready; then
  result passed "checks passed; pr-ready tier not set, left in draft"
  push_ack normal "✅ ${KEY}: checks passed — add pr-ready to autonomy.auto_execute, or mark ready yourself: ${PR_URL}"
  exit 0
fi
# Everything above vouched for $sha; a push since then has been through none of it.
[ "$(pr_head)" = "$sha" ] || stop "the PR head moved after it was checked; not marking it ready"
if [ "$PR_DRAFT" = true ]; then
  with_timeout "$GH_TIMEOUT" gh pr ready "$PR" --repo "$REPO" >>"$LOG_FILE" 2>&1
fi
[ "$(with_timeout "$GH_TIMEOUT" gh pr view "$PR" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)" = false ] \
  || stop "gh pr ready did not take"
result ready "PR #${PR} marked ready for review"
push_ack normal "🚀 ${KEY}: CI green${BT:+, browser test passed} — PR #${PR} is ready for review: ${PR_URL}"

# --- after ready: tracker status, team announce. The PR is already in review, so a failure here is
# pushed, never a stop. -----------------------------------------------------------------------------
tr_name="$(_arc "$P.transition")"
if [ -n "$tr_name" ] && [ "$TRACKER" = jira ]; then
  if ! jobs_autonomy_allows jira-transition; then
    push_ack normal "ℹ️ ${KEY}: not moved to \"${tr_name}\" — add jira-transition to autonomy.auto_execute"
  elif ! ar_jira_init; then
    push_ack urgent "⚠️ ${KEY}: could not move to \"${tr_name}\": ${AR_ERR}"
  else
    TMPD="$D"; jira_transition_by_name "$KEY" "$tr_name"; rc=$?
    case "$rc" in
      0) log "moved ${KEY} to ${tr_name}" ;;
      4) push_ack normal "⚠️ ${KEY}: no \"${tr_name}\" transition from its current status; move it yourself: ${TICKET_URL}" ;;
      *) push_ack urgent "⚠️ ${KEY}: moving to \"${tr_name}\" failed (HTTP ${JIRA_HTTP}): ${TICKET_URL}" ;;
    esac
  fi
fi

# announce_prs — this PR first, then every other open PR in the project's repos whose title or
# branch names the Jira key (bounded by non-alphanumerics, any case), excluding fork PRs. URLs are
# rebuilt from gh numbers.
announce_prs() {
  local r lines
  printf '%s\n' "$PR_URL"
  [ "$TRACKER" = jira ] || return 0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    lines="$(with_timeout "$GH_TIMEOUT" gh pr list --repo "$r" --state open --limit 100 \
      --json number,title,headRefName,isCrossRepository \
      --jq '.[] | select(.isCrossRepository != true) | "\(.number)\t\(.title)\t\(.headRefName)"' 2>>"$LOG_FILE")" || continue
    printf '%s\n' "$lines" | awk -F'\t' -v k="$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]')" -v r="$r" '
      function names(s,   i, n) { s = tolower(s); n = length(k)
        for (i = index(s, k); i > 0; ) {
          if ((i == 1 || substr(s, i - 1, 1) !~ /[a-z0-9]/) && substr(s, i + n, 1) !~ /[a-z0-9]/) return 1
          s = substr(s, i + 1); i = index(s, k)
        }
        return 0 }
      $1 ~ /^[0-9]+$/ && (names($2) || names($3)) { print "https://github.com/" r "/pull/" $1 }'
  done < <(gr_project_repos "$SLUG")
}

channel="$(_arc "$P.announce.channel")"
if [ -n "$channel" ]; then
  if ! jobs_autonomy_allows slack-post; then
    push_ack normal "ℹ️ ${KEY}: not announced in Slack — add slack-post to autonomy.auto_execute"
  else
    text="CR+QA: $(announce_prs | awk '!seen[$0]++' | paste -sd' ' -) ${TICKET_URL}"
    w="$(_arc "projects.${SLUG}.slack.workspace")"; [ -n "$w" ] || w="$(_arc agent.slack.workspace)"
    ea_slack_bin "$(_arc agent.slack.method)" "$(_arc agent.slack.bin)" "$w"
    if with_timeout "$GH_TIMEOUT" "$SLACK_BIN" send "$channel" "$text" --json ${SLACK_WS[@]+"${SLACK_WS[@]}"} >>"$LOG_FILE" 2>&1; then
      log "announced in ${channel}: ${text}"
    else
      push_ack urgent "⚠️ ${KEY}: Slack announce failed — post it yourself: ${text}"
    fi
  fi
fi
exit 0
