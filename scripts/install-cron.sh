#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="${1:-.}"
INTERVAL="${2:-15}"

# Resolve project directory to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
AGENT_DIR="${PROJECT_DIR}/.claude/engineer-agent"

# Validate interval
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 1 ]; then
  echo "Usage: $0 [project_dir] [interval_minutes]"
  echo "  project_dir:      path to your project (default: current directory)"
  echo "  interval_minutes:  polling interval in minutes (default: 15, minimum: 1)"
  exit 1
fi

# Create required directories
mkdir -p "${AGENT_DIR}/queue/"{incoming,drafts,completed,rejected}
mkdir -p "${AGENT_DIR}/state"

# Initialize last-poll.yaml if missing
if [ ! -f "${AGENT_DIR}/state/last-poll.yaml" ]; then
  cat > "${AGENT_DIR}/state/last-poll.yaml" <<'YAML'
github:
  last_checked: "1970-01-01T00:00:00Z"
  seen_prs: []
slack:
  last_checked_ts: "0"
jira:
  last_checked: "1970-01-01T00:00:00Z"
  seen_tickets: []
slite:
  last_checked: "1970-01-01T00:00:00Z"
  seen_docs: []
YAML
  echo "Initialized ${AGENT_DIR}/state/last-poll.yaml"
fi

# Make cron-poll.sh executable
chmod +x "${PLUGIN_ROOT}/scripts/cron-poll.sh"

# Install crontab entry (remove old entry first if exists)
CRON_CMD="*/${INTERVAL} * * * * ${PLUGIN_ROOT}/scripts/cron-poll.sh ${PROJECT_DIR}"
(crontab -l 2>/dev/null | grep -v "engineer-agent.*cron-poll.sh" || true; echo "$CRON_CMD") | crontab -

echo "Engineer-agent cron installed:"
echo "  Project: ${PROJECT_DIR}"
echo "  Interval: every ${INTERVAL} minutes"
echo "  Script: ${PLUGIN_ROOT}/scripts/cron-poll.sh"
echo "  Log: ${AGENT_DIR}/state/cron-poll.log"
echo ""
echo "To verify: crontab -l | grep engineer-agent"
echo "To remove: crontab -l | grep -v engineer-agent | crontab -"
