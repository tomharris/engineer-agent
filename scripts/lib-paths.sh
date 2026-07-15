#!/bin/bash
# lib-paths.sh — single source of truth for engineer-agent's runtime storage location.
# Source this; it defines EA_AGENT_DIR, EA_CONFIG_FILE, and EA_LEGACY_AGENT_DIR.
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

# Pre-relocation location, kept only so migrate-storage.sh and the setup/status commands
# can detect an un-migrated install and say so.
EA_LEGACY_AGENT_DIR="${HOME}/.claude/engineer-agent"
