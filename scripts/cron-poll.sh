#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${PLUGIN_ROOT}/state"
LOG_FILE="${STATE_DIR}/cron-poll.log"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

echo "--- Poll started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"

# Run claude headlessly with the poll command
claude -p \
  --plugin-dir "$PLUGIN_ROOT" \
  --model sonnet \
  --max-budget-usd 0.50 \
  "Run the engineer poll workflow for all configured sources. Read config from ${PLUGIN_ROOT}/config/engineer.yaml. Check all configured sources (GitHub, Slack, Jira, Slite) for new items since the last poll recorded in ${PLUGIN_ROOT}/state/last-poll.yaml. For each new item, create a queue file in ${PLUGIN_ROOT}/queue/incoming/ with the standard frontmatter format documented in CLAUDE.md, then generate a draft and move it to ${PLUGIN_ROOT}/queue/drafts/. Update last-poll.yaml when done. Be concise." \
  >> "$LOG_FILE" 2>&1

echo "--- Poll finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"
