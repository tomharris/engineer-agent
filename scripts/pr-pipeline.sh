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

ITEM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --item) ITEM="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$ITEM" =~ ^[A-Za-z0-9._-]+\.md$ ]] || { echo "--item must be a queue file name" >&2; exit 2; }

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
# stop <message> — the one failure exit: record, push once, leave the PR in draft.
stop() { result stopped "$1"; push_ack urgent "⚠️ PR pipeline stopped on ${KEY:-$ITEM}${PR_URL:+ (${PR_URL})}: $1"; exit 1; }
refuse() { log "not runnable: $1"; result refused "$1"; exit 2; }

# --- resolve: ledger -> job -> project, branch, repo, PR (all bash-derived) ------------------------
jobs_cfg_load   # here, not inside the first $(...), or every later lookup reloads and fails
row="$(autopilot_lookup "$ITEM")" || refuse "not an autopilot item"
IFS="	" read -r JOB _ KEY _ <<< "$row"
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
       --json number,url,isDraft --jq '.[] | "\(.number)\t\(.url)\t\(.isDraft)"' 2>>"$LOG_FILE")"
[ "$(printf '%s' "$pr" | grep -c .)" = 1 ] || stop "expected one open PR for ${BRANCH}, found $(printf '%s' "$pr" | grep -c .)"
IFS="	" read -r PR PR_URL PR_DRAFT <<< "$pr"
[[ "$PR" =~ ^[0-9]+$ ]] || stop "unreadable PR number"
case "$PR_URL" in "https://github.com/${REPO}/pull/${PR}") ;; *) PR_URL="https://github.com/${REPO}/pull/${PR}" ;; esac
log "PR #${PR} (${BRANCH}) in ${REPO}"

BASE="$(git -C "$PROJECT_PATH" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
BASE="${BASE:-main}"
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
trap '[ -z "$WATCHDOG" ] || kill "$WATCHDOG" 2>/dev/null; cleanup; inflight_end "${ITEM%.md}.pipeline"; rm -rf "$D/lock"' EXIT
# The watchdog kills our children too: a TERM trap waits for the foreground command to finish.
trap 'cleanup; stop "exceeded after_pr.max_runtime"' TERM
MAX="$(jobs_duration_seconds "$(_arc "$P.max_runtime")")"; MAX="${MAX:-7200}"
( me="$BASHPID"; sleep "$MAX"
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
    | "\($b)\t\(.name // .context // "")\t\(.detailsUrl // .targetUrl // "")"' 2>/dev/null)"
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

# ci_logs — failing checks and the tail of each failed Actions run's log, into $D/ci-failure.log.
ci_logs() {
  local name link run
  : > "$D/ci-failure.log"
  while IFS="	" read -r _ name link; do
    printf '=== FAILED CHECK: %s (%s)\n' "$name" "$link" >> "$D/ci-failure.log"
  done < "$D/ci.fail"
  sed -nE 's#.*/actions/runs/([0-9]+).*#\1#p' "$D/ci.fail" | sort -u | while IFS= read -r run; do
    printf '\n=== LOG (failed steps) for run %s\n' "$run" >> "$D/ci-failure.log"
    with_timeout "$GH_TIMEOUT" gh run view "$run" --repo "$REPO" --log-failed 2>&1 | tail -n 400 >> "$D/ci-failure.log"
  done
}

# fix_run — one confined fix attempt; sets NEW_SHA to the new remote head, or empty.
# Globals, not $(...): a subshell would not run cleanup when the watchdog fires.
fix_run() {
  local before after
  NEW_SHA=""
  ci_logs
  before="$(remote_head)"
  branch_worktree || { log "could not create a worktree on ${BRANCH}"; return 0; }
  project_build_rules "$SLUG"
  local tools=( Read Edit Write Glob Grep "${CONFINED_GIT_WRITE_RULES[@]}" ${BUILD_RULES[@]+"${BUILD_RULES[@]}"} "Bash(echo:*)" )
  local prompt="CI failed on pull request #${PR} for branch ${BRANCH}. The failing checks and the tail of their logs are in ${D}/ci-failure.log — read it first. \
The current working directory is a git worktree checked out on ${BRANCH}; stay inside it. Reproduce the failure with the project's build/test commands where you can, fix the root cause, and commit. \
Never skip, delete or weaken a test, lint rule or type check to get green. Do not edit CI configuration. \
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
browser_test() {
  local url setup serve ready t0 code nonce instr dev
  url="$(_arc "$P.browser.url")"; setup="$(_arc "$P.browser.setup")"; serve="$(_arc "$P.browser.serve")"
  instr="$(_arc "$P.browser.instructions")"
  # Claude in Chrome drives whichever connected browser was picked last, which may be on another
  # machine where localhost is not this one. chrome_device pins it.
  dev="$(_arc "$P.browser.chrome_device")"
  [ -z "$dev" ] || instr="FIRST call mcp__claude-in-chrome__select_browser with deviceId ${dev}; if that fails, stop: the verdict is fail. ${instr}"
  ready="$(jobs_duration_seconds "$(_arc "$P.browser.ready_timeout")")"; ready="${ready:-180}"
  branch_worktree || { BT="could not create a worktree on ${BRANCH}"; return; }
  if [ -n "$setup" ]; then
    ( cd "$WT" && with_timeout 1200 bash -c "$setup" ) </dev/null >> "$D/serve.log" 2>&1 \
      || { cleanup; BT="browser.setup failed (see ${D}/serve.log)"; return; }
  fi
  ( cd "$WT" && exec bash -c "$serve" ) </dev/null >> "$D/serve.log" 2>&1 &
  SRV=$!
  t0="$(date +%s)"
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)"
    [[ "$code" =~ ^[234] ]] && break
    kill -0 "$SRV" 2>/dev/null || { cleanup; BT="browser.serve exited before ${url} answered (see ${D}/serve.log)"; return; }
    [ $(( $(date +%s) - t0 )) -lt "$ready" ] || { cleanup; BT="${url} did not answer within ${ready}s"; return; }
    sleep "$(( POLL < 5 ? POLL : 5 ))"
  done
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

# --- run ------------------------------------------------------------------------------------------
sha="$(with_timeout "$GH_TIMEOUT" gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null)"
[ -n "$sha" ] || stop "could not read the PR head"
attempts="$(_arc "$P.ci.fix_attempts")"; attempts="${attempts:-1}"
n=0
while :; do
  ci="$(ci_wait "$sha")"
  log "CI on ${sha:0:7}: ${ci}"
  [ "$ci" = fail ] && [ "$n" -lt "$attempts" ] || break
  n=$((n+1))
  fix_run
  [ -n "$NEW_SHA" ] || stop "CI failed and fix attempt ${n} pushed nothing"
  sha="$NEW_SHA"
done
case "$ci" in
  pass) ;;
  fail)    stop "CI still failing after ${n} fix attempt(s): $(cut -f2 "$D/ci.fail" | paste -sd, -)" ;;
  none)    stop "no CI checks reported on the PR" ;;
  timeout) stop "CI did not finish within after_pr.ci.timeout" ;;
esac

if [ -n "$(_arc "$P.browser.serve")" ]; then
  browser_test
  case "$BT" in
    pass) log "browser test passed" ;;
    fail) stop "browser test failed — report: ${D}/browser-report.md" ;;
    *)    stop "browser test could not run: ${BT}" ;;
  esac
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
if [ "$PR_DRAFT" = true ]; then
  with_timeout "$GH_TIMEOUT" gh pr ready "$PR" --repo "$REPO" >>"$LOG_FILE" 2>&1
fi
[ "$(with_timeout "$GH_TIMEOUT" gh pr view "$PR" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)" = false ] \
  || stop "gh pr ready did not take"
result ready "PR #${PR} marked ready for review"
push_ack normal "🚀 ${KEY}: CI green${BT:+, browser test passed} — PR #${PR} is ready for review: ${PR_URL}"
exit 0
