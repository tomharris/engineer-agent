#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="${1:-.}"

# Resolve project directory to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
AGENT_DIR="${PROJECT_DIR}/.claude/engineer-agent"
LOG_FILE="${AGENT_DIR}/state/cron-poll.log"

# Ensure state directory exists
mkdir -p "${AGENT_DIR}/state"

echo "--- Poll started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"

# Run claude headlessly with the poll command
cd "$PROJECT_DIR"
claude -p \
  --plugin-dir "$PLUGIN_ROOT" \
  --model sonnet \
  --max-budget-usd 0.50 \
  "Run the engineer poll workflow for all configured sources. Read config from .claude/engineer-agent/engineer.yaml. Check all configured sources (GitHub, Slack, Jira, Slite) for new items since the last poll recorded in .claude/engineer-agent/state/last-poll.yaml. For each new item, create a queue file in .claude/engineer-agent/queue/incoming/ with the standard frontmatter format documented in CLAUDE.md, then generate a draft and move it to .claude/engineer-agent/queue/drafts/. Update last-poll.yaml when done. Be concise." \
  >> "$LOG_FILE" 2>&1

echo "--- Poll finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"
