#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
source "${PLUGIN_ROOT}/scripts/lib-paths.sh"
INTERVAL="${1:-15}"

AGENT_DIR="$EA_AGENT_DIR"

# Validate interval
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 1 ]; then
  echo "Usage: $0 [interval_minutes]"
  echo "  interval_minutes:  polling interval in minutes (default: 15, minimum: 1)"
  exit 1
fi

# Create required directories
mkdir -p "${AGENT_DIR}/queue/"{incoming,drafts,completed,rejected}
mkdir -p "${AGENT_DIR}/state"

# Initialize last-poll.yaml if missing
if [ ! -f "${AGENT_DIR}/state/last-poll.yaml" ]; then
  cat > "${AGENT_DIR}/state/last-poll.yaml" <<'YAML'
projects: {}
YAML
  echo "Initialized ${AGENT_DIR}/state/last-poll.yaml"
fi

# Make cron-poll.sh executable
chmod +x "${PLUGIN_ROOT}/scripts/cron-poll.sh"

# Install crontab entry (remove any old/commented entry first if it exists).
# Prefix PATH so cron can find the `claude` CLI (commonly in ~/.local/bin). cron-poll.sh
# also exports PATH itself, but setting it here keeps the entry robust on its own.
# cron does not inherit the interactive shell environment, so if CLAUDE_BIN is set at
# install time, bake it into the entry so cron-poll.sh sees the same binary override.
CLAUDE_BIN_PREFIX=""
[ -n "${CLAUDE_BIN:-}" ] && CLAUDE_BIN_PREFIX="CLAUDE_BIN=${CLAUDE_BIN} "
CRON_CMD="*/${INTERVAL} * * * * ${CLAUDE_BIN_PREFIX}PATH=${HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin ${PLUGIN_ROOT}/scripts/cron-poll.sh"
(crontab -l 2>/dev/null | grep -v "engineer-agent.*cron-poll.sh" || true; echo "$CRON_CMD") | crontab -

echo "Engineer-agent cron installed:"
echo "  Config: ${AGENT_DIR}/engineer.yaml"
echo "  Interval: every ${INTERVAL} minutes"
echo "  Script: ${PLUGIN_ROOT}/scripts/cron-poll.sh"
echo "  Log: ${AGENT_DIR}/state/cron-poll.log"
echo ""

# Headless auth check: a cron job runs outside the GUI login session and cannot read the macOS
# login keychain, so the poll will fail with "Not logged in" unless a keychain-independent
# credential is available. Point the user at the supported fix rather than letting the first
# poll silently fail. (See scripts/lib-paths.sh for how auth.env is consumed.)
if [ ! -f "${AGENT_DIR}/auth.env" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "NOTE: no headless auth token found. On macOS, cron cannot read the login keychain, so"
  echo "      the poll will fail with 'Not logged in'. Run 'claude setup-token' (paid plan"
  echo "      required), then write the token to a mode-600 file:"
  echo "        printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\\n' '<token>' > ${AGENT_DIR}/auth.env"
  echo "        chmod 600 ${AGENT_DIR}/auth.env"
  echo ""
fi

echo "To verify: crontab -l | grep engineer-agent"
echo "To remove: crontab -l | grep -v engineer-agent | crontab -"
