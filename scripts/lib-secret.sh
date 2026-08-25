#!/bin/bash
# lib-secret.sh — resolve the API credentials the Jira and Slite collectors need.
#
# WHY THIS EXISTS AT ALL: GitHub was scriptable for free because `gh` is an already-authenticated
# CLI sitting on the box. Jira and Slite have no CLI, so scripts/poll-jira.sh and
# scripts/poll-slite.sh talk to their REST APIs directly and have to get a token from somewhere.
# That "somewhere" is the whole security surface of this addition, so it lives in one file.
#
# THE CREDENTIAL MUST NEVER BE WRITTEN INTO engineer.yaml. The config names WHERE the secret is,
# never what it is. That is not a style preference: ea-config.sh's `dump` is a curated view whose
# stated purpose is to be safe to log or cache while debugging (it already omits
# agent.notify.ntfy.* for exactly this reason), and engineer.yaml is a file users paste into issues
# when asking for help. A token in the document defeats both.
#
# RESOLUTION ORDER — env var, then file, then Keychain. Explicit beats implicit, so a caller that
# has deliberately exported something wins; the Keychain is the fallback because it is the one
# store that survives the environment a LaunchAgent actually gets.
#
# ⚠ THE LAUNCHD TRAP, which is this repo's signature failure shape (works interactively, silently
# fatal unattended): cron, launchd and systemd hand the run a MINIMAL environment. An
# `export EA_JIRA_API_TOKEN=…` in ~/.zshrc is present in every terminal you test from and ABSENT in
# the supervised poll — so the env-var route resolves fine by hand and yields nothing at 15-minute
# intervals forever, with the collector skipping cleanly and no error anywhere. This is the same
# class of bug as the missing `$USER` that broke every cron poll (see CLAUDE.md → "Export USER").
# So:
#   • On macOS, PREFER THE KEYCHAIN (`ea_secret_store`). The poll already runs as a gui/$UID
#     LaunchAgent precisely so it can read the login keychain — slack-mcp.sh depends on the same
#     property — so this route needs no scheduler change and keeps no secret on disk.
#   • On Linux, prefer the FILE route (`api_token_file`), mode 0600. crontab does not inherit the
#     shell environment either.
#   • The env route is for interactive runs, tests, and containers, where something explicit sets it.
#
# READ-ONLY, like slack-mcp.sh: nothing here ever rewrites or refreshes a stored credential.
# ea_secret_store is the one writer and is only ever called from an interactive setup flow.

# _ea_secret_from_file <path> — read a token from a file, first non-blank non-comment line.
# Trailing newlines are the usual way a pasted token ends up unusable, so the value is trimmed.
_ea_secret_from_file() {
  local f="${1:-}"
  [ -n "$f" ] || return 0
  # Expand a leading ~ by hand: the path comes from YAML, so the shell never got a chance to.
  case "$f" in "~/"*) f="${HOME}/${f#\~/}" ;; esac
  [ -f "$f" ] || return 0
  sed -E '/^[[:space:]]*(#|$)/d' "$f" | head -1 | tr -d '\r\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# _ea_secret_from_keychain <service> [account] — macOS login-keychain generic password, READ ONLY.
# Absent entry, absent `security`, or a locked keychain all yield empty rather than an error: every
# caller treats "no credential" as a clean skip, and a noisy failure here would turn a
# not-configured source into a poll-wide error.
_ea_secret_from_keychain() {
  local service="${1:-}" account="${2:-}"
  [ -n "$service" ] || return 0
  command -v security >/dev/null 2>&1 || return 0
  if [ -n "$account" ]; then
    security find-generic-password -s "$service" -a "$account" -w 2>/dev/null | tr -d '\r\n'
  else
    security find-generic-password -s "$service" -w 2>/dev/null | tr -d '\r\n'
  fi
}

# ea_secret_resolve <env_name> <file_path> <keychain_service> [keychain_account]
# Prints the credential, or nothing. ALWAYS returns 0 — "not configured" is a normal state that
# every caller handles by skipping the source, not by failing the poll.
ea_secret_resolve() {
  local env_name="${1:-}" file_path="${2:-}" kc_service="${3:-}" kc_account="${4:-}" v=""

  # Env: only when the config NAMES a variable. Reading an arbitrary well-known name would make the
  # credential source depend on ambient environment rather than on config.
  if [ -n "$env_name" ]; then
    # Indirect expansion; `${!x}` is a bashism and this file is bash-only (so is every caller).
    v="${!env_name:-}"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi

  v="$(_ea_secret_from_file "$file_path")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }

  v="$(_ea_secret_from_keychain "$kc_service" "$kc_account")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }

  return 0
}

# ea_secret_store <service> <account> <secret> — write a credential to the macOS login keychain.
# INTERACTIVE SETUP ONLY (scripts/setup-credentials.sh). `-U` updates an existing entry rather than
# erroring, and the secret is passed with -w so it never appears in the process list of another user.
ea_secret_store() {
  local service="${1:-}" account="${2:-}" secret="${3:-}"
  [ -n "$service" ] && [ -n "$secret" ] || return 1
  command -v security >/dev/null 2>&1 || { echo "lib-secret: no \`security\` binary (macOS only)" >&2; return 1; }
  security add-generic-password -U -s "$service" -a "${account:-engineer-agent}" -w "$secret" 2>/dev/null
}

# ea_secret_service <kind> — the keychain service name for a credential kind ("jira" | "slite").
# Centralized so the setup script and the collectors cannot disagree about the name, which would
# present as "I stored it and the poll still says not configured".
ea_secret_service() { printf 'engineer-agent-%s' "${1:?}"; }
