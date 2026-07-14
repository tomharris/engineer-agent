#!/bin/bash
# install-listener.sh — run approval-listener.sh as a long-lived background service
# so ntfy phone approvals are acted on in near-real-time and survive reboots/crashes.
#
# Prefers a systemd user service; falls back to a nohup-managed background process on
# hosts without systemd. Companion to install-cron.sh.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="${HOME}/.claude/engineer-agent"
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

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_DIR="${HOME}/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "${UNIT_DIR}/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=engineer-agent ntfy approval listener
After=network-online.target

[Service]
ExecStart=${LISTENER}
Restart=always
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
    <key>RunAtLoad</key>
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
