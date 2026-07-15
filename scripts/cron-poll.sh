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

# Ensure state directory exists
mkdir -p "${AGENT_DIR}/state"

echo "--- Poll started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"

# Fingerprint the state file so we can tell afterwards whether the poll actually did
# anything. `claude -p` exits 0 whenever the CLI ran, regardless of whether the work
# happened, so the exit code is worthless as a health signal — this script reported
# success on every run for a month while every poll was being denied. Every successful
# poll advances `last_checked` in last-poll.yaml, even one that finds no new items, so
# an unchanged file means the poll made no progress.
STATE_FILE="${AGENT_DIR}/state/last-poll.yaml"
state_fingerprint() { sha256sum "$STATE_FILE" 2>/dev/null | cut -d' ' -f1 || echo missing; }
STATE_BEFORE="$(state_fingerprint)"

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
# `gh pr review`, `gh issue create` and `spy send` are all unmatched here, as is `gh api`
# (`gh api -X POST` writes). Anything unmatched fails non-interactively, which the
# no-progress check below surfaces as a WARN rather than a silent no-op.
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
allowed_tools=(
  "Bash(gh pr list:*)" "Bash(gh pr view:*)" "Bash(gh pr diff:*)"
  "Bash(gh issue list:*)" "Bash(gh issue view:*)"
  "Bash(spy read:*)" "Bash(spy thread:*)"
  "Bash(${PLUGIN_ROOT}/scripts/notify.sh *)"
  "Bash(mv *)"
  Read Glob Grep
  "Edit(/${AGENT_DIR}/**)"
)

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
  --max-budget-usd 2.00 \
  "Execute now — do NOT enter plan mode, do NOT output a plan, do NOT ask questions. Perform the work directly and report the results when finished.

Run the /engineer-agent poll command for all configured sources (equivalent to '/engineer-agent poll all'). Read config from ${AGENT_DIR}/engineer.yaml and follow commands/poll.md and the per-source poll skills. Iterate over all projects in the config. For each project, check all configured sources (GitHub, Slack, Jira, Slite) for new items since the last poll recorded in ${AGENT_DIR}/state/last-poll.yaml. For each new item, create a queue file in ${AGENT_DIR}/queue/incoming/ with the standard frontmatter format documented in CLAUDE.md (include the project slug in the frontmatter), then generate a draft and move it to ${AGENT_DIR}/queue/drafts/. For EACH newly drafted item, send a push notification by running: ${PLUGIN_ROOT}/scripts/notify.sh --title '<type>: <title>' --message '<project> — <short summary>' --priority '<priority from frontmatter>' --item-id '<the queue filename>' --source-url '<source_url from frontmatter>' --tags 'inbox_tray'. (notify.sh no-ops safely if ntfy is not configured, so always call it.) Update last-poll.yaml when done. Be concise." \
  </dev/null >> "$LOG_FILE" 2>&1 || POLL_STATUS=$?

# A bare `[ ... ] && echo` would abort the script under `set -e` whenever the test is
# false, since the list then exits non-zero. Use an explicit if.
if [ "$POLL_STATUS" -ne 0 ]; then
  echo "WARN: claude exited ${POLL_STATUS}" >> "$LOG_FILE"
fi

# Trust the filesystem, not the exit code (same principle as approval-listener.sh).
if [ "$(state_fingerprint)" = "$STATE_BEFORE" ]; then
  echo "WARN: poll made no state progress (last-poll.yaml unchanged) — see $LOG_FILE" >> "$LOG_FILE"
  # --priority urgent, not "high": notify.sh maps engineer-agent priorities
  # (urgent|normal|low) onto ntfy's, and an unrecognized value silently becomes
  # "default" — which would quietly downgrade this very alert.
  "${PLUGIN_ROOT}/scripts/notify.sh" \
    --title 'engineer-agent: poll failed' \
    --message 'Poll made no state progress. Check state/cron-poll.log.' \
    --priority urgent --tags warning --fyi >> "$LOG_FILE" 2>&1 || true
fi

echo "--- Poll finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"
