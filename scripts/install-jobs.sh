#!/bin/bash
# install-jobs.sh — install the scheduled-jobs dispatcher (scripts/jobs-tick.sh) to fire every 60s.
#
# Separate from install-cron.sh: jobs run ALONGSIDE the global poll, and each can be installed or
# removed without touching the other. Same platform split and for the same reason (see
# install-cron.sh): macOS uses a gui-session LaunchAgent so `claude` can read the login keychain;
# Linux uses crontab.
#
# The tick itself is cheap (a config read when nothing is due); per-job cadence comes from
# projects.<slug>.jobs[].every, not from this schedule.
#
# Usage: install-jobs.sh [--uninstall]
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
source "${PLUGIN_ROOT}/scripts/lib-paths.sh"
AGENT_DIR="$EA_AGENT_DIR"
TICK_SCRIPT="${PLUGIN_ROOT}/scripts/jobs-tick.sh"
SERVICE_NAME="engineer-agent-jobs"
UNINSTALL=0
[ "${1:-}" = "--uninstall" ] && UNINSTALL=1

mkdir -p "${AGENT_DIR}/state/jobs" "${AGENT_DIR}/queue/"{incoming,drafts,completed,rejected}
chmod +x "$TICK_SCRIPT"

if [ "$(uname)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  PLIST="${HOME}/Library/LaunchAgents/${SERVICE_NAME}.plist"
  DOMAIN="gui/$(id -u)"
  launchctl bootout "${DOMAIN}/${SERVICE_NAME}" >/dev/null 2>&1 || true
  if [ "$UNINSTALL" -eq 1 ]; then
    rm -f "$PLIST"; echo "Removed ${SERVICE_NAME}."; exit 0
  fi

  LAUNCHD_ENV=""
  if [ -n "${CLAUDE_BIN:-}" ]; then
    LAUNCHD_ENV="        <key>CLAUDE_BIN</key>
        <string>${CLAUDE_BIN}</string>
"
  fi
  mkdir -p "$(dirname "$PLIST")"
  # AbandonProcessGroup: the tick launches each due job detached and exits. Without this launchd
  # kills the whole process group when the tick exits, killing every running job with it.
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${TICK_SCRIPT}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
${LAUNCHD_ENV}        <key>PATH</key>
        <string>${HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${AGENT_DIR}/state/jobs-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${AGENT_DIR}/state/jobs-launchd.log</string>
</dict>
</plist>
PLISTEOF
  # bootout + bootstrap, never kickstart: launchd caches the job definition (including
  # EnvironmentVariables) at load time, so an edited plist is inert until re-read.
  if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST"
  fi
  echo "Scheduled-jobs dispatcher installed as a launchd LaunchAgent (every 60s):"
  echo "  Plist:  ${PLIST}"
  echo "  Log:    ${AGENT_DIR}/state/jobs.log"
  echo "  Status: launchctl print ${DOMAIN}/${SERVICE_NAME} | grep -E 'state|CLAUDE_BIN'"
  echo "  Remove: $0 --uninstall"
else
  if [ "$UNINSTALL" -eq 1 ]; then
    (crontab -l 2>/dev/null | grep -v "engineer-agent.*jobs-tick.sh" || true) | crontab -
    echo "Removed the ${SERVICE_NAME} crontab entry."; exit 0
  fi
  CLAUDE_BIN_PREFIX=""
  [ -n "${CLAUDE_BIN:-}" ] && CLAUDE_BIN_PREFIX="CLAUDE_BIN=${CLAUDE_BIN} "
  CRON_CMD="* * * * * ${CLAUDE_BIN_PREFIX}PATH=${HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin ${TICK_SCRIPT} >/dev/null 2>&1"
  (crontab -l 2>/dev/null | grep -v "engineer-agent.*jobs-tick.sh" || true; echo "$CRON_CMD") | crontab -
  echo "Scheduled-jobs dispatcher installed as a crontab entry (every minute):"
  echo "  Script: ${TICK_SCRIPT}"
  echo "  Log:    ${AGENT_DIR}/state/jobs.log"
  echo "  Remove: $0 --uninstall"
fi
