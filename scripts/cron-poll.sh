#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
source "${PLUGIN_ROOT}/scripts/lib-paths.sh"
AGENT_DIR="$EA_AGENT_DIR"
LOG_FILE="${AGENT_DIR}/state/cron-poll.log"

# cron runs with a minimal PATH that usually omits ~/.local/bin (where the claude
# CLI is commonly installed), causing "claude: command not found". Make sure it's
# findable regardless of how the script is invoked.
export PATH="${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"
# CLAUDE_BIN can be set in the environment to select a specific Claude Code binary
# (e.g. a version shim or non-standard install path); otherwise discover it on PATH.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "${HOME}/.local/bin/claude")}"
# Per-run budget cap for the headless poll. A full 6-project × 4-source poll (GitHub + Jira +
# Slack + Slite) that reads live Slack channels and may draft a PR review / ticket intent inline
# can exceed a low cap; when it does, claude -p aborts mid-run, writes no receipt, and the next
# fire re-attempts the same work (a $2 default did exactly this after Slack reads started
# working, 2026-07-22). Override with EA_POLL_BUDGET_USD; install-cron.sh bakes it into launchd.
POLL_BUDGET_USD="${EA_POLL_BUDGET_USD:-6.00}"

# Ensure state directory exists
mkdir -p "${AGENT_DIR}/state"

# Single-run lock: a scheduled poll normally finishes in minutes, but a slow run (large
# backlog, many Slack reads) can still be in flight when the next fire lands — and a manual
# run can collide with a scheduled one. Two concurrent polls thrash the same state/receipt
# files and each burns the full budget racing the other (observed 2026-07-22). Take a PID
# lock and exit early if another poll holds it; a stale lock (dead PID) is reclaimed.
LOCK_FILE="${AGENT_DIR}/state/cron-poll.lock"
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
  echo "--- Poll skipped at $(date -u +%Y-%m-%dT%H:%M:%SZ): another poll (PID $(cat "$LOCK_FILE")) is running ---" >> "$LOG_FILE"
  exit 0
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

echo "--- Poll started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"

# LIVENESS, not dedup state. `claude -p` exits 0 whenever the CLI ran, regardless of
# whether the work happened, so the exit code is worthless as a health signal — this
# script reported success on every run for a month while every poll was being denied.
# We prove the run reached its final step by making the model echo back a token only THIS
# run knows: the script mints RUN_ID below and the prompt requires the model to copy it
# verbatim into a receipt file. Freshness is proven by the id, not by content mutation.
#
# This replaced a sha256 fingerprint of last-poll.yaml, which was wrong twice over:
#   - last-poll.yaml is a semantic dedup cutoff, not a health signal. poll-slack's
#     last_checked_ts is the highest Slack message ts seen, so a legitimate zero-message
#     poll CANNOT advance it — a Slack-only config false-warned on every quiet poll.
#   - The values are model-authored and were observed fabricated (a real run wrote a
#     last_checked 40 minutes in the future, rounded to the half hour). Content-change is
#     only a freshness signal if the content is reliably distinct per run. It isn't.
# Both files still matter — they answer different questions. Keep them separate.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECEIPT_FILE="${AGENT_DIR}/state/last-poll-receipt.yaml"

# Dependency-free top-level scalar reader (same approach as lib-ntfy.sh's yaml_ntfy_get).
# Deliberately NOT jq: cron-poll.sh has no jq dependency and install-cron.sh does not check
# for one — only the separately-installed approval-listener.sh requires it. Single awk
# process, no pipeline, so `set -euo pipefail` can't trip on SIGPIPE.
receipt_field() {
  [ -f "$RECEIPT_FILE" ] || return 0
  awk -v k="$1" '
    index($0, k ":") == 1 {
      v = substr($0, length(k) + 2)
      sub(/^ +/, "", v); sub(/ +$/, "", v)
      gsub(/^"|"$/, "", v)
      print v; exit
    }' "$RECEIPT_FILE"
}

# List the entries of the receipt's `errors:` block (one per line, quotes stripped).
# Same dependency-free awk approach as receipt_field. An inline `errors: []` yields
# nothing, which callers treat as "no detail available".
receipt_errors() {
  [ -f "$RECEIPT_FILE" ] || return 0
  awk '
    /^errors:/ { in_block = 1; next }
    in_block && /^[^ ]/ { in_block = 0 }
    in_block && /^ *- / {
      v = $0
      sub(/^ *- */, "", v)
      gsub(/^"|"$/, "", v)
      print v
    }' "$RECEIPT_FILE"
}

# The log is append-only, so any cause-extraction grep over the whole file can resurrect
# a PREVIOUS run's error line and report it as this run's cause. Record where this run's
# lines start; run_log yields only the slice this run appended.
LOG_START_LINE="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"
run_log() { tail -n "+$((LOG_START_LINE + 1))" "$LOG_FILE"; }

# Run claude headlessly with the poll command.
#
# IMPORTANT: this is a non-interactive batch run. The agent must DO the work, not
# describe a plan. We invoke the /engineer-agent poll command directly and forbid
# plan mode, and pin a non-interactive permission mode so the run never inherits the
# user's global `permissions.defaultMode` (e.g. "plan"), in which claude -p just prints
# a plan and exits 0 without doing anything.
#
# --permission-mode alone is NOT enough: `gh` is not one of the Bash commands Claude Code
# treats as built-in read-only, so it prompts in every mode — and a prompt in `-p` is a
# denial. Without the allowlist below every poll silently failed on every `gh` call.
#
# The allowlist is deliberately READ-ONLY for every integration. Polling only discovers
# work and drafts responses; posting is execute-item's job, behind the human approval
# gate. Since poll ingests untrusted text (PR/issue bodies, Slack messages), a
# prompt-injection payload must not be able to reach a write verb. So `gh pr create`,
# `gh pr review`, `gh issue create` and the Slack `send` verb (spy or slack-mcp.sh) are all
# unmatched here, as is `gh api` (`gh api -X POST` writes). Anything unmatched fails
# non-interactively, which the no-progress check below surfaces as a WARN rather than a silent
# no-op.
#
# Three gotchas encoded below, each of which silently broke a real run:
#   1. Bash rules match the literal command text, so `mv *` -- a `~/`-prefixed pattern
#      would miss the absolute paths the model actually writes.
#   2. Use Edit(...), never Write(...): the CLI rejects Write(path) rules outright ("only
#      Edit(path) rules are [matched by file permission checks]"), and one Edit rule
#      covers every file-editing tool, Write included.
#   3. Path rules need `//abs` to anchor at the filesystem root; a single leading `/`
#      anchors to the cwd instead. AGENT_DIR is already absolute, hence the extra slash
#      in "Edit(/${AGENT_DIR}/**)".
#   4. MCP tools are denied unless named explicitly, exactly like `gh`. The Jira and
#      Slite pollers drive MCP servers (there is no read-only Bash verb for them), so
#      without the entries below `poll-jira`/`poll-slite` silently skip every run —
#      Jira tickets never get queued even though auth and everything else work. Only
#      the READ verbs are listed (search + fetch); the write tools (createJiraIssue,
#      editJiraIssue, transitionJiraIssue, addComment*, slite create/edit/append) stay
#      unmatched, keeping posting behind the execute-item gate as with `gh`/`spy`.
#
# The Slack read verbs are keyed off the effective Slack binary, which depends on
# agent.slack.method (resolved in plain bash below, before claude starts):
#   - method: spy (default)  -> `spy`
#   - method: mcp-proxy      -> the bundled scripts/slack-mcp.sh (Enterprise Grid; reuses the
#                               Keychain OAuth token). It runs as ONE Bash invocation, so its
#                               internal curl/jq/security subprocesses need no separate rule —
#                               one rule covers the whole call. No `Bash(curl *)`.
# Either way only `read`/`thread` are listed; `<bin> send` stays UNMATCHED, so posting remains
# execute-item's job behind the approval gate — identical to the gh read-vs-write split above.
#
# mcp-proxy gotcha (this silently broke the first poll after Slack channels were configured, AND
# a first attempted fix that added an unexpanded `${CLAUDE_PLUGIN_ROOT}` literal rule — see below):
# poll-slack references the shim as `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh` (SKILL.md §1 — the
# plugin-root var, not an absolute path). Two facts, each confirmed from a real failing run's
# transcript, decide the rule shape:
#   1. The MODEL expands ${CLAUDE_PLUGIN_ROOT} to an absolute path before Bash sees it — it does
#      NOT pass the literal `${CLAUDE_PLUGIN_ROOT}` token. So a single-quoted literal rule never
#      matches; that earlier fix was dead code.
#   2. When the plugin is installed via marketplace it SHADOWS our `--plugin-dir`, so that expanded
#      root is the INSTALLED cache path (…/plugins/cache/engineer-agent/engineer-agent/<ver>), NOT
#      this script's dev-repo PLUGIN_ROOT. So a rule built only from PLUGIN_ROOT also misses.
# Fix: allowlist the shim's EXPANDED path for BOTH candidate roots — our script-derived PLUGIN_ROOT
# and resolve_installed_plugin_root() (the cache path the runtime actually resolves) — so whichever
# one applies, a rule matches. The spy/bin backend needs none of this: `spy` is a bare literal
# identical in rule and call.
SLACK_METHOD="$(yaml_agent_slack method)"; SLACK_METHOD="${SLACK_METHOD:-spy}"
if [ "$SLACK_METHOD" = "mcp-proxy" ]; then
  SLACK_BIN="${PLUGIN_ROOT}/scripts/slack-mcp.sh"
else
  SLACK_BIN="$(yaml_agent_slack bin)"; SLACK_BIN="${SLACK_BIN:-spy}"
fi
allowed_tools=(
  "Bash(gh pr list:*)" "Bash(gh pr view:*)" "Bash(gh pr diff:*)"
  "Bash(gh issue list:*)" "Bash(gh issue view:*)"
  "Bash(${SLACK_BIN} read:*)" "Bash(${SLACK_BIN} thread:*)" "Bash(${SLACK_BIN} auth:*)"
  mcp__atlassian__searchJiraIssuesUsingJql mcp__atlassian__getJiraIssue
  mcp__slite__search-notes mcp__slite__get-note mcp__slite__get-note-children
  "Bash(${PLUGIN_ROOT}/scripts/notify.sh *)"
  "Bash(mv *)"
  Read Glob Grep
  "Edit(/${AGENT_DIR}/**)"
)
# See the mcp-proxy gotcha above: the model emits the shim's expanded abs path, resolved against
# whichever plugin root the runtime uses. That root is NOT stable — across real polls it has been
# the dev-repo PLUGIN_ROOT (our --plugin-dir), the installed cache, AND the marketplace checkout
# (…/plugins/marketplaces/engineer-agent). Allowlist read/thread/auth for EVERY candidate root so
# whichever the runtime resolves, a rule matches. `auth` is included because the model runs it as a
# read-only token preflight before reading (observed getting denied and cascading to a doomed
# direct-connector fallback when only read/thread were allowed). notify.sh is added for the extra
# roots too as cheap insurance, in case a skill invokes it via ${CLAUDE_PLUGIN_ROOT} rather than
# the pre-expanded path this script injects into the prompt.
if [ "$SLACK_METHOD" = "mcp-proxy" ]; then
  for EXTRA_ROOT in "$(resolve_installed_plugin_root)" "$(resolve_marketplace_plugin_root)"; do
    [ -n "$EXTRA_ROOT" ] && [ "$EXTRA_ROOT" != "$PLUGIN_ROOT" ] || continue
    allowed_tools+=(
      "Bash(${EXTRA_ROOT}/scripts/slack-mcp.sh read:*)"
      "Bash(${EXTRA_ROOT}/scripts/slack-mcp.sh thread:*)"
      "Bash(${EXTRA_ROOT}/scripts/slack-mcp.sh auth:*)"
      "Bash(${EXTRA_ROOT}/scripts/notify.sh *)"
    )
  done
fi

# --add-dir: acceptEdits only auto-accepts edits under the working directory, and cron
# runs from $HOME. Naming the agent dir explicitly (alongside the scoped Edit rule above)
# is what lets the run record state and move queue files.
# `|| POLL_STATUS=$?` is required: under `set -e` a non-zero exit here (budget exhausted,
# CLI error) would abort the script before the health check below could report it — the
# loudest failures would stay the most invisible.
#
# Argument order matters: --allowedTools takes a variable number of values, so it must not
# be the last flag before the prompt or it swallows the prompt as another rule (the run
# then dies with "Input must be provided ... when using --print"). Keep a single-value
# flag between the allowlist and the prompt.
POLL_STATUS=0
"$CLAUDE_BIN" -p \
  --plugin-dir "$PLUGIN_ROOT" \
  --add-dir "$AGENT_DIR" \
  --model sonnet \
  --permission-mode acceptEdits \
  --allowedTools "${allowed_tools[@]}" \
  --max-budget-usd "$POLL_BUDGET_USD" \
  "Execute now — do NOT enter plan mode, do NOT output a plan, do NOT ask questions. Perform the work directly and report the results when finished.

You ARE the scheduled poll for this cycle, not an observer of it. Do NOT check whether a poll has already run, and do NOT skip a source because recent queue items or a recent last_checked suggest it was already covered. Poll every configured source yourself, now.

Run the /engineer-agent poll command for all configured sources (equivalent to '/engineer-agent poll all'). Read config from ${AGENT_DIR}/engineer.yaml and follow commands/poll.md and the per-source poll skills. Iterate over all projects in the config. For each project, check all configured sources (GitHub, Slack, Jira, Slite) for new items since the last poll recorded in ${AGENT_DIR}/state/last-poll.yaml. For each new item, create a queue file in ${AGENT_DIR}/queue/incoming/ with the standard frontmatter format documented in CLAUDE.md (include the project slug in the frontmatter), then generate a draft and move it to ${AGENT_DIR}/queue/drafts/. For EACH newly drafted item, send a push notification by running: ${PLUGIN_ROOT}/scripts/notify.sh --title '<type>: <title>' --message '<project> — <short summary>' --priority '<priority from frontmatter>' --item-id '<the queue filename>' --source-url '<source_url from frontmatter>' --tags 'inbox_tray'. (notify.sh no-ops safely if ntfy is not configured, so always call it.)

STATE: use exactly ${RUN_TS} as this poll's timestamp — do not compute or guess one. After polling each source, set that source's last_checked in ${AGENT_DIR}/state/last-poll.yaml to exactly ${RUN_TS}, WHETHER OR NOT it produced any items: a source that found zero items was still polled successfully and must have its cutoff advanced. (Exception: Slack's last_checked_ts tracks the highest Slack message timestamp actually seen — leave it unchanged when no messages were read.)

FINAL STEP — do this last, always, even if you found zero items and even if some sources failed. Write ${AGENT_DIR}/state/last-poll-receipt.yaml, replacing any existing content, with exactly this shape:

run_id: \"${RUN_ID}\"
finished_at: \"${RUN_TS}\"
status: ok
items_queued: 0
sources_polled:
  - <project-slug>/<source>
skipped: []
errors: []

Rules: copy run_id verbatim — it is how the cron proves this receipt came from THIS run and not a previous one. items_queued is the number of items you moved into drafts/ this run (0 is a normal, successful result). Every source belongs in exactly ONE of three buckets; never claim a source you did not query:
- sources_polled: a source you actually issued a query for in THIS run.
- skipped: a source that is NOT configured or NOT enabled for that project — with a one-line reason. This covers Jira when the project's tracker is not 'jira' or it has no jira section; Slite when there is no slite section; Slack when slack.channels is empty; GitHub Issues when there is no github.issues section; and the like. A skipped source is a normal, expected result and MUST NOT affect status.
- errors: a CONFIGURED source that you attempted and that FAILED (auth error, API error, or a required tool missing for an enabled source) — with a one-line reason.
status is computed over CONFIGURED sources only: 'ok' if every configured source was queried without error (skipped sources are fine); 'partial' if at least one configured source failed while at least one other configured source succeeded; 'error' if no configured source could be polled.

Be concise." \
  </dev/null >> "$LOG_FILE" 2>&1 || POLL_STATUS=$?

# A bare `[ ... ] && echo` would abort the script under `set -e` whenever the test is
# false, since the list then exits non-zero. Use an explicit if.
if [ "$POLL_STATUS" -ne 0 ]; then
  echo "WARN: claude exited ${POLL_STATUS}" >> "$LOG_FILE"
fi

# Trust the filesystem, not the exit code (same principle as approval-listener.sh).
# The receipt is model-written, so it is an ATTESTATION, not a measurement: it cannot catch
# a model that confidently lies. It reliably catches every mechanical failure — execution
# error, plan mode, denied Edit, budget exhaustion, hard no-op — because all of them leave
# no receipt or a stale run_id, and RUN_ID is a value only this run knows.
FAIL_REASON=""
if [ ! -f "$RECEIPT_FILE" ]; then
  FAIL_REASON="no receipt written — the run never reached its final step"
elif [ "$(receipt_field run_id)" != "$RUN_ID" ]; then
  FAIL_REASON="receipt is stale (run_id '$(receipt_field run_id)', expected '${RUN_ID}') — this run wrote nothing"
fi

if [ -n "$FAIL_REASON" ]; then
  echo "WARN: poll did not complete: ${FAIL_REASON} — see $LOG_FILE" >> "$LOG_FILE"
  # Surface the underlying cause in the alert itself, not just the log. The receipt check tells
  # us the run didn't finish; the actual reason (an API failure: "API Error: … ENOTFOUND", a
  # misauthed CLI: "Not logged in", "command not found", budget exhaustion) is usually the last
  # recognizable error line this run logged. Prefer a real cause line; fall back to the generic
  # exit-code WARN, then "unknown" so the message is never empty. Each grep is `|| true`-guarded:
  # under pipefail a no-match grep would otherwise abort the script before the notify fires.
  LAST_ERR="$(run_log | grep -E 'API Error|Not logged in|command not found|No such file|Execution error' | tail -1 || true)"
  LAST_ERR="${LAST_ERR:-$(run_log | grep 'WARN: claude exited' | tail -1 || true)}"
  LAST_ERR="${LAST_ERR:-unknown (see log)}"
  LAST_ERR="${LAST_ERR:0:200}"
  # --priority urgent, not "high": notify.sh maps engineer-agent priorities
  # (urgent|normal|low) onto ntfy's, and an unrecognized value silently becomes
  # "default" — which would quietly downgrade this very alert.
  "${PLUGIN_ROOT}/scripts/notify.sh" \
    --title 'engineer-agent: poll failed' \
    --message "Poll did not complete (${FAIL_REASON}). Last error: ${LAST_ERR}. See state/cron-poll.log." \
    --priority urgent --tags warning --fyi >> "$LOG_FILE" 2>&1 || true
else
  RECEIPT_STATUS="$(receipt_field status)"
  echo "poll completed: status=${RECEIPT_STATUS:-unknown} items_queued=$(receipt_field items_queued)" >> "$LOG_FILE"
  # A zero-item poll is a SUCCESS: fresh receipt, status ok -> silent. Partial failure (a
  # source that errored while others succeeded) is something the old hash check could never
  # detect — a real run advanced github state while skipping github_issues entirely and
  # sailed through the fingerprint clean. A partial/error self-heals next cycle, so it goes
  # out at --priority normal, not urgent — it shouldn't wake anyone.
  if [ "$RECEIPT_STATUS" != "ok" ]; then
    echo "WARN: poll reported status=${RECEIPT_STATUS:-unknown} — see $LOG_FILE" >> "$LOG_FILE"
    # Say WHAT failed, not just that something did: inline the receipt's first errors:
    # entry (and the count) so the push is actionable from a phone. Empty errors list
    # (defensive — status != ok should always carry entries) keeps the generic wording.
    ERR_LIST="$(receipt_errors)"
    if [ -n "$ERR_LIST" ]; then
      ERR_COUNT="$(printf '%s\n' "$ERR_LIST" | wc -l)"
      FIRST_ERR="$(printf '%s\n' "$ERR_LIST" | head -1)"
      FIRST_ERR="${FIRST_ERR:0:180}"
      STATUS_MSG="Poll finished with status=${RECEIPT_STATUS:-unknown} — ${ERR_COUNT} configured source(s) failed. First: ${FIRST_ERR}. See state/last-poll-receipt.yaml."
    else
      STATUS_MSG="Poll finished with status=${RECEIPT_STATUS:-unknown}. Check state/last-poll-receipt.yaml."
    fi
    "${PLUGIN_ROOT}/scripts/notify.sh" \
      --title 'engineer-agent: poll incomplete' \
      --message "$STATUS_MSG" \
      --priority normal --tags warning --fyi >> "$LOG_FILE" 2>&1 || true
  fi
fi

echo "--- Poll finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"
