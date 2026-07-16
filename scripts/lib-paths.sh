#!/bin/bash
# lib-paths.sh — single source of truth for engineer-agent's runtime storage location,
# and the shared headless-environment normalization every unattended entry point needs.
# Source this; it defines EA_AGENT_DIR, EA_CONFIG_FILE, EA_LEGACY_AGENT_DIR, and normalizes
# USER/LOGNAME (see below).
#
# WHY NOT ~/.claude/engineer-agent/ (where this used to live):
# Claude Code guards everything under a `.claude/` directory as sensitive. The Edit and
# Write tools are refused there even with an explicit `--allowedTools "Edit(...)"` rule --
# allow rules do not override the guard. (Bash writes are not caught, but reaching for
# that is routing around a safety mechanism, not a fix.)
#
# The guard is invisible interactively, because a human is present to approve the prompt.
# It is fatal headlessly: cron-poll.sh and approval-listener.sh have nobody to ask, so a
# denied write just... does nothing. Both ran for a month doing exactly nothing -- the
# cron polled every 15 minutes and could never record state or queue an item.
#
# So: runtime data (config, queue, state) lives outside ~/.claude/, under XDG_DATA_HOME.
# Do not move it back.
#
# Precedence: EA_AGENT_DIR env override > $XDG_DATA_HOME/engineer-agent
#                                       > ~/.local/share/engineer-agent

EA_AGENT_DIR="${EA_AGENT_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/engineer-agent}"
EA_CONFIG_FILE="${EA_AGENT_DIR}/engineer.yaml"

# cron/launchd/systemd hand a headless run a minimal environment. macOS cron sets LOGNAME
# but NOT USER, and the Claude Code CLI keys its credential lookup on $USER -- a missing
# USER yields "Not logged in - Please run /login" even when valid credentials are present
# and work interactively (this silently broke every cron poll after a CLI update changed
# credential resolution to depend on $USER). Same class of bug as the minimal-PATH guard
# in cron-poll.sh. Derive it at runtime rather than capturing it at install time: unlike
# CLAUDE_BIN (a user choice), USER is always recoverable via `id -un`.
export USER="${USER:-$(id -un)}"
export LOGNAME="${LOGNAME:-$USER}"

# Headless auth: on macOS the primary Anthropic credential lives in the login keychain, and a
# cron/launchd job runs OUTSIDE the user's GUI (Aqua) login session, so it cannot read that
# keychain -- the CLI then reports "Not logged in - Please run /login" even with USER correct
# (this is a THIRD, distinct trigger of that message, after the remote-settings.json shim and
# the USER fix above -- both of which were validated interactively, inside the GUI session, and
# so never held under real cron). The supported headless path is a long-lived OAuth token from
# `claude setup-token`, consumed via CLAUDE_CODE_OAUTH_TOKEN, which is keychain/session
# independent. Load it from a mode-600 file so the secret stays out of the crontab. An
# already-set env var wins (never clobbered), and when no file exists nothing changes -- so
# interactive keychain auth is untouched. Only engineer-agent scripts source this file (not the
# user's shell rc), so a human typing `claude` interactively is unaffected.
EA_AUTH_FILE="${EA_AGENT_DIR}/auth.env"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$EA_AUTH_FILE" ]; then
  set -a; . "$EA_AUTH_FILE"; set +a
fi

# Pre-relocation location, kept only so migrate-storage.sh and the setup/status commands
# can detect an un-migrated install and say so.
EA_LEGACY_AGENT_DIR="${HOME}/.claude/engineer-agent"
