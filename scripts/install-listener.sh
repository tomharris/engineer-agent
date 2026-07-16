#!/bin/bash
# install-listener.sh — run approval-listener.sh as a long-lived background service
# so ntfy phone approvals are acted on in near-real-time and survive reboots/crashes.
#
# Prefers a systemd user service; falls back to a nohup-managed background process on
# hosts without systemd. Companion to install-cron.sh.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
source "${PLUGIN_ROOT}/scripts/lib-paths.sh"
AGENT_DIR="$EA_AGENT_DIR"
LISTENER="${PLUGIN_ROOT}/scripts/approval-listener.sh"
SERVICE_NAME="engineer-agent-listener"

mkdir -p "${AGENT_DIR}/state"
chmod +x "$LISTENER"

# Preflight: jq and a configured command_topic are required for the listener to do anything.
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required (the listener parses ntfy's JSON stream with it)." >&2
  echo "  Install jq, then re-run this script." >&2
  exit 1
}
if ! grep -q "command_topic" "${AGENT_DIR}/engineer.yaml" 2>/dev/null; then
  echo "WARNING: agent.notify.ntfy.command_topic not found in ${AGENT_DIR}/engineer.yaml." >&2
  echo "  The listener will exit immediately until you configure it (see /engineer-agent setup)." >&2
fi

# Headless auth: like the cron poll, a supervised listener (systemd/nohup) runs outside the GUI
# login session and cannot read the macOS login keychain, so approvals will fail with "Not
# logged in". A launchd LaunchAgent runs in the GUI session but still fails if the keychain
# locks. A keychain-independent OAuth token (loaded from auth.env by lib-paths.sh) covers all
# cases. Warn if neither the file nor an env token is present.
if [ ! -f "${AGENT_DIR}/auth.env" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "NOTE: no headless auth token found. A supervised run may fail with 'Not logged in' (it" >&2
  echo "      cannot read the login keychain). Run 'claude setup-token' (paid plan required)," >&2
  echo "      then: printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\\n' '<token>' > ${AGENT_DIR}/auth.env && chmod 600 ${AGENT_DIR}/auth.env" >&2
fi

# cron/systemd/launchd do not inherit the interactive shell environment. If CLAUDE_BIN
# is set at install time, bake it into the service definition so the listener resolves the
# same binary override when it runs supervised. Each block carries its own trailing newline
# so that when CLAUDE_BIN is unset the generated unit/plist is byte-for-byte unchanged.
SYSTEMD_ENV=""
LAUNCHD_ENV=""
if [ -n "${CLAUDE_BIN:-}" ]; then
  SYSTEMD_ENV="Environment=CLAUDE_BIN=${CLAUDE_BIN}"$'\n'
  LAUNCHD_ENV="    <key>EnvironmentVariables</key>
    <dict>
        <key>CLAUDE_BIN</key>
        <string>${CLAUDE_BIN}</string>
    </dict>
"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_DIR="${HOME}/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "${UNIT_DIR}/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=engineer-agent ntfy approval listener
After=network-online.target

[Service]
ExecStart=${LISTENER}
${SYSTEMD_ENV}Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE_NAME}.service"

  echo "Engineer-agent approval listener installed as a systemd user service:"
  echo "  Unit:   ${UNIT_DIR}/${SERVICE_NAME}.service"
  echo "  Log:    ${AGENT_DIR}/state/approval-listener.log"
  echo ""
  echo "Status:  systemctl --user status ${SERVICE_NAME}"
  echo "Logs:    journalctl --user -u ${SERVICE_NAME} -f"
  echo "Stop:    systemctl --user stop ${SERVICE_NAME}"
  echo "Remove:  systemctl --user disable --now ${SERVICE_NAME} && rm ${UNIT_DIR}/${SERVICE_NAME}.service"
  echo ""
  echo "Tip: for the service to keep running after you log out, enable lingering:"
  echo "  loginctl enable-linger \$USER"
elif [ "$(uname)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  # macOS: register a launchd LaunchAgent. Like the systemd path, this restarts
  # the listener on crash (KeepAlive) and starts it at login (RunAtLoad).
  LA_DIR="${HOME}/Library/LaunchAgents"
  PLIST="${LA_DIR}/${SERVICE_NAME}.plist"
  LOG_FILE="${AGENT_DIR}/state/approval-listener.log"
  DOMAIN="gui/$(id -u)"
  mkdir -p "$LA_DIR"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${LISTENER}</string>
    </array>
${LAUNCHD_ENV}    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
PLISTEOF

  # Reload idempotently: bootout any prior instance, then bootstrap + kickstart.
  # Fall back to the legacy load/unload API on older macOS where bootstrap is absent.
  launchctl bootout "${DOMAIN}/${SERVICE_NAME}" >/dev/null 2>&1 || true
  if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    launchctl kickstart -k "${DOMAIN}/${SERVICE_NAME}" >/dev/null 2>&1 || true
  else
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST"
  fi

  echo "Engineer-agent approval listener installed as a launchd LaunchAgent:"
  echo "  Plist:  ${PLIST}"
  echo "  Log:    ${LOG_FILE}"
  echo ""
  echo "Status:  launchctl print ${DOMAIN}/${SERVICE_NAME}"
  echo "Logs:    tail -f ${LOG_FILE}"
  echo "Stop:    launchctl bootout ${DOMAIN}/${SERVICE_NAME}"
  echo "Remove:  launchctl bootout ${DOMAIN}/${SERVICE_NAME}; rm ${PLIST}"
  echo ""
  echo "The LaunchAgent starts at login and restarts on crash automatically."
else
  # Fallback: nohup-managed background process.
  PID_FILE="${AGENT_DIR}/state/approval-listener.pid"
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Listener already running (PID $(cat "$PID_FILE")). Stop it first:"
    echo "  kill \$(cat ${PID_FILE})"
    exit 0
  fi
  nohup "$LISTENER" >> "${AGENT_DIR}/state/approval-listener.log" 2>&1 &
  echo $! > "$PID_FILE"
  echo "systemd not available — started listener via nohup:"
  echo "  PID:  $(cat "$PID_FILE") (saved to ${PID_FILE})"
  echo "  Log:  ${AGENT_DIR}/state/approval-listener.log"
  echo "  Stop: kill \$(cat ${PID_FILE})"
  echo ""
  echo "NOTE: a nohup process does NOT survive reboot. Re-run this script after reboot,"
  echo "      or add an @reboot crontab entry pointing at ${LISTENER}."
fi
