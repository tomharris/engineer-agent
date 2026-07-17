#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
source "${PLUGIN_ROOT}/scripts/lib-paths.sh"
INTERVAL="${1:-15}"

AGENT_DIR="$EA_AGENT_DIR"
POLL_SCRIPT="${PLUGIN_ROOT}/scripts/cron-poll.sh"
SERVICE_NAME="engineer-agent-poll"

# Validate interval
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 1 ]; then
  echo "Usage: $0 [interval_minutes]"
  echo "  interval_minutes:  polling interval in minutes (default: 15, minimum: 1)"
  echo ""
  echo "Optional env (macOS launchd only): pin the poll to specific clock hours instead"
  echo "of a fixed interval — useful to confine polling to business hours and cap spend:"
  echo "  EA_POLL_HOURS=9,10,11,13,14,15,16   comma-separated hours (0-23)"
  echo "  EA_POLL_MINUTE=3                     minute within each hour (default: 0)"
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

chmod +x "$POLL_SCRIPT"

# ── Headless auth: why macOS uses launchd, not crontab ────────────────────────────────────
# The poll's `claude -p` needs the login credential. On macOS the primary Anthropic credential
# lives in the *login keychain*, which is only readable from within the user's GUI (Aqua) login
# session. A crontab job runs OUTSIDE that session and cannot read it, so every cron poll dies
# with "Not logged in" (verified: identical crontab poll fails, while the same binary run from a
# gui-session launchd agent authenticates and exits 0). A launchd LaunchAgent bootstrapped into
# `gui/$UID` DOES run in-session and can read the keychain — the approval-listener has used this
# path successfully. So on macOS we install the poll as a LaunchAgent; on Linux we keep crontab
# (there is no per-user GUI-keychain split there).
#
# This supersedes the older "cron AND launchd both fail the keychain" note: only out-of-session
# schedulers fail. (Separately: a `forceLoginOrgUUID` managed policy blocks ALL headless auth,
# keychain and env-token alike — if that policy is present, no scheduler choice helps; resolve it
# with org IT. It is absent on this machine.)
# ──────────────────────────────────────────────────────────────────────────────────────────

# cron/launchd do not inherit the interactive shell environment. If CLAUDE_BIN is set at install
# time, bake it into the definition so the supervised poll resolves the same binary override.
LAUNCHD_ENV=""
if [ -n "${CLAUDE_BIN:-}" ]; then
  LAUNCHD_ENV="        <key>CLAUDE_BIN</key>
        <string>${CLAUDE_BIN}</string>
"
fi

if [ "$(uname)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  LA_DIR="${HOME}/Library/LaunchAgents"
  PLIST="${LA_DIR}/${SERVICE_NAME}.plist"
  DOMAIN="gui/$(id -u)"
  LAUNCHD_LOG="${AGENT_DIR}/state/poll-launchd.log"
  mkdir -p "$LA_DIR"

  # Schedule: EA_POLL_HOURS (clock hours) -> StartCalendarInterval; otherwise StartInterval
  # (every N minutes). StartCalendarInterval lets a schedule be confined to business hours,
  # which caps how much a first poll on a large backlog can spend.
  if [ -n "${EA_POLL_HOURS:-}" ]; then
    POLL_MINUTE="${EA_POLL_MINUTE:-0}"
    SCHEDULE_BLOCK="    <key>StartCalendarInterval</key>
    <array>
"
    IFS=',' read -ra _HOURS <<< "$EA_POLL_HOURS"
    for h in "${_HOURS[@]}"; do
      h="${h// /}"
      [[ "$h" =~ ^[0-9]+$ ]] || { echo "Invalid EA_POLL_HOURS entry: '$h'"; exit 1; }
      SCHEDULE_BLOCK+="        <dict><key>Hour</key><integer>${h}</integer><key>Minute</key><integer>${POLL_MINUTE}</integer></dict>
"
    done
    SCHEDULE_BLOCK+="    </array>"
    SCHEDULE_DESC="hours ${EA_POLL_HOURS} at :$(printf '%02d' "$POLL_MINUTE")"
  else
    SCHEDULE_BLOCK="    <key>StartInterval</key>
    <integer>$((INTERVAL * 60))</integer>"
    SCHEDULE_DESC="every ${INTERVAL} minutes"
  fi

  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${POLL_SCRIPT}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
${LAUNCHD_ENV}        <key>PATH</key>
        <string>${HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
${SCHEDULE_BLOCK}
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LAUNCHD_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCHD_LOG}</string>
</dict>
</plist>
PLISTEOF

  # A launchd LaunchAgent runs whatever it parsed at bootstrap, so reload on every install
  # (bootout + bootstrap), matching install-listener.sh. Fall back to legacy load/unload on
  # older macOS where bootstrap is absent.
  launchctl bootout "${DOMAIN}/${SERVICE_NAME}" >/dev/null 2>&1 || true
  if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    :
  else
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST"
  fi

  # Remove any legacy crontab entry so the poll doesn't run twice (out-of-session crontab
  # runs would only fail auth and spam "poll failed" alerts).
  if crontab -l >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "engineer-agent.*cron-poll.sh" || true) | crontab -
  fi

  echo "Engineer-agent poll installed as a launchd LaunchAgent:"
  echo "  Plist:    ${PLIST}"
  echo "  Schedule: ${SCHEDULE_DESC}"
  echo "  Config:   ${AGENT_DIR}/engineer.yaml"
  echo "  Log:      ${AGENT_DIR}/state/cron-poll.log (launchd stdout: ${LAUNCHD_LOG})"
  echo ""
  echo "The LaunchAgent runs in your GUI login session, so it can read the login keychain"
  echo "the interactive CLI uses — no token on disk. It only polls while you are logged in."
  echo ""
  echo "Run now:  launchctl kickstart -k ${DOMAIN}/${SERVICE_NAME}"
  echo "Status:   launchctl print ${DOMAIN}/${SERVICE_NAME}"
  echo "Logs:     tail -f ${AGENT_DIR}/state/cron-poll.log"
  echo "Stop:     launchctl bootout ${DOMAIN}/${SERVICE_NAME}"
  echo "Remove:   launchctl bootout ${DOMAIN}/${SERVICE_NAME}; rm ${PLIST}"
else
  # Linux / non-macOS: crontab. No per-user GUI-keychain split, so an out-of-session job can
  # use the same credential store as the interactive CLI.
  CLAUDE_BIN_PREFIX=""
  [ -n "${CLAUDE_BIN:-}" ] && CLAUDE_BIN_PREFIX="CLAUDE_BIN=${CLAUDE_BIN} "
  CRON_CMD="*/${INTERVAL} * * * * ${CLAUDE_BIN_PREFIX}PATH=${HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin ${POLL_SCRIPT}"
  (crontab -l 2>/dev/null | grep -v "engineer-agent.*cron-poll.sh" || true; echo "$CRON_CMD") | crontab -

  echo "Engineer-agent poll installed as a crontab entry:"
  echo "  Config:   ${AGENT_DIR}/engineer.yaml"
  echo "  Interval: every ${INTERVAL} minutes"
  echo "  Script:   ${POLL_SCRIPT}"
  echo "  Log:      ${AGENT_DIR}/state/cron-poll.log"
  echo ""
  echo "To verify: crontab -l | grep engineer-agent"
  echo "To remove: crontab -l | grep -v engineer-agent | crontab -"
fi
