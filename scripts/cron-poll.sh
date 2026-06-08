#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="${HOME}/.claude/engineer-agent"
LOG_FILE="${AGENT_DIR}/state/cron-poll.log"

# cron runs with a minimal PATH that usually omits ~/.local/bin (where the claude
# CLI is commonly installed), causing "claude: command not found". Make sure it's
# findable regardless of how the script is invoked.
export PATH="${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"
CLAUDE_BIN="$(command -v claude || echo "${HOME}/.local/bin/claude")"

# Ensure state directory exists
mkdir -p "${AGENT_DIR}/state"

echo "--- Poll started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"

# Run claude headlessly with the poll command.
#
# IMPORTANT: this is a non-interactive batch run. The agent must DO the work, not
# describe a plan. We invoke the /engineer-agent poll command directly and forbid
# plan mode, and use a non-interactive permission mode so queue file writes and the
# notify.sh call are not blocked.
"$CLAUDE_BIN" -p \
  --plugin-dir "$PLUGIN_ROOT" \
  --model sonnet \
  --max-budget-usd 0.50 \
  --permission-mode acceptEdits \
  "Execute now — do NOT enter plan mode, do NOT output a plan, do NOT ask questions. Perform the work directly and report the results when finished.

Run the /engineer-agent poll command for all configured sources (equivalent to '/engineer-agent poll all'). Read config from ~/.claude/engineer-agent/engineer.yaml and follow commands/poll.md and the per-source poll skills. Iterate over all projects in the config. For each project, check all configured sources (GitHub, Slack, Jira, Slite) for new items since the last poll recorded in ~/.claude/engineer-agent/state/last-poll.yaml. For each new item, create a queue file in ~/.claude/engineer-agent/queue/incoming/ with the standard frontmatter format documented in CLAUDE.md (include the project slug in the frontmatter), then generate a draft and move it to ~/.claude/engineer-agent/queue/drafts/. For EACH newly drafted item, send a push notification by running: ${PLUGIN_ROOT}/scripts/notify.sh --title '<type>: <title>' --message '<project> — <short summary>' --priority '<priority from frontmatter>' --item-id '<the queue filename>' --source-url '<source_url from frontmatter>' --tags 'inbox_tray'. (notify.sh no-ops safely if ntfy is not configured, so always call it.) Update last-poll.yaml when done. Be concise." \
  >> "$LOG_FILE" 2>&1

echo "--- Poll finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"
