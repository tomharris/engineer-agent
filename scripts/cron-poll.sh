#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="${HOME}/.claude/engineer-agent"
LOG_FILE="${AGENT_DIR}/state/cron-poll.log"

# Ensure state directory exists
mkdir -p "${AGENT_DIR}/state"

echo "--- Poll started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"

# Run claude headlessly with the poll command
claude -p \
  --plugin-dir "$PLUGIN_ROOT" \
  --model sonnet \
  --max-budget-usd 0.50 \
  "Run the engineer poll workflow for all configured sources. Read config from ~/.claude/engineer-agent/engineer.yaml. Iterate over all projects in the config. For each project, check all configured sources (GitHub, Slack, Jira, Slite) for new items since the last poll recorded in ~/.claude/engineer-agent/state/last-poll.yaml under that project's key. For each new item, create a queue file in ~/.claude/engineer-agent/queue/incoming/ with the standard frontmatter format documented in CLAUDE.md (include the project slug in the frontmatter), then generate a draft and move it to ~/.claude/engineer-agent/queue/drafts/. Update last-poll.yaml when done. Be concise." \
  >> "$LOG_FILE" 2>&1

echo "--- Poll finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"
