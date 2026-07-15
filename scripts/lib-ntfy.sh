#!/bin/bash
# lib-ntfy.sh — shared ntfy config resolution for engineer-agent scripts.
# Source this; it defines yaml_ntfy_get() and resolve_ntfy_settings().
#
# resolve_ntfy_settings sets these globals (env vars override config):
#   NTFY_SERVER, NTFY_TOPIC, NTFY_COMMAND_TOPIC, NTFY_AUTH_TOKEN

# EA_AGENT_DIR / EA_CONFIG_FILE come from lib-paths.sh (single source of truth).
# shellcheck source=lib-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-paths.sh"

# Read a scalar key from the agent.notify.ntfy block of the YAML config.
# Dependency-free: finds the `ntfy:` line and reads the more-indented block under it.
yaml_ntfy_get() {
  local key="$1"
  [ -f "$EA_CONFIG_FILE" ] || return 0
  awk -v key="$key" '
    !found && $1=="ntfy:" { found=1; match($0, /^ */); base=RLENGTH; next }
    found {
      match($0, /^ */); ind=RLENGTH
      if (length($0) == 0) next
      if (ind <= base) { exit }
      line=$0; sub(/^ +/, "", line)
      k=line; sub(/:.*/, "", k)
      if (k==key) {
        v=substr(line, index(line, ":")+1)
        sub(/^ +/, "", v); sub(/ +$/, "", v)
        sub(/^"/, "", v); sub(/"$/, "", v)
        print v; exit
      }
    }
  ' "$EA_CONFIG_FILE"
}

resolve_ntfy_settings() {
  NTFY_SERVER="${EA_NTFY_SERVER:-$(yaml_ntfy_get server)}"
  NTFY_TOPIC="${EA_NTFY_TOPIC:-$(yaml_ntfy_get topic)}"
  NTFY_COMMAND_TOPIC="${EA_NTFY_COMMAND_TOPIC:-$(yaml_ntfy_get command_topic)}"
  NTFY_AUTH_TOKEN="${EA_NTFY_AUTH_TOKEN:-$(yaml_ntfy_get auth_token)}"
  NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
  NTFY_SERVER="${NTFY_SERVER%/}"
}
