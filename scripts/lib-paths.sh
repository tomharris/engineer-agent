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

# NOTE ON HEADLESS AUTH: an `auth.env` / CLAUDE_CODE_OAUTH_TOKEN loader used to live here so a
# cron/launchd job (which runs OUTSIDE the GUI login session and cannot read the login keychain)
# could authenticate. It was removed: a `forceLoginOrgUUID` managed policy rejects ALL environment
# credentials -- including a freshly-minted `claude setup-token` OAuth token -- because org
# membership can't be verified for one, so the token path is a confirmed dead end on any machine
# with that policy. Do not re-add it. See the "headless `claude -p` run" section of CLAUDE.md for
# the full failure analysis and the only surviving headless paths (cloud provider, or an IT
# exemption).

# Pre-relocation location, kept only so migrate-storage.sh and the setup/status commands
# can detect an un-migrated install and say so.
EA_LEGACY_AGENT_DIR="${HOME}/.claude/engineer-agent"

# resolve_installed_plugin_root — the highest-version installed engineer-agent plugin dir, or
# empty if the plugin isn't installed via marketplace (a pure `--plugin-dir` dev machine).
#
# WHY THIS EXISTS: when the plugin is installed via marketplace it SHADOWS a `--plugin-dir`
# pointing at the dev checkout, so a skill's ${CLAUDE_PLUGIN_ROOT} resolves to this cache path,
# NOT the dev repo. The model then EXPANDS that variable to this absolute path before Bash ever
# sees it. So a headless `--allowedTools` rule for a plugin script (slack-mcp.sh) must match this
# expanded cache path, not the dev-repo path nor the unexpanded `${CLAUDE_PLUGIN_ROOT}` literal.
# cron-poll.sh / approval-listener.sh allowlist the shim for BOTH this root and their own
# script-derived PLUGIN_ROOT so whichever one the runtime resolves, a rule matches. See the
# "mcp-proxy gotcha" note in cron-poll.sh and CLAUDE.md.
resolve_installed_plugin_root() {
  local base="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins/cache/engineer-agent/engineer-agent"
  [ -d "$base" ] || return 0
  ls -d "$base"/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/*$::'
}

# resolve_marketplace_plugin_root — the engineer-agent plugin dir inside the marketplace
# CHECKOUT (…/plugins/marketplaces/engineer-agent), or empty if not present.
#
# WHY THIS EXISTS: ${CLAUDE_PLUGIN_ROOT} does NOT resolve to a single stable path. Across real
# headless polls it has expanded to THREE different dirs depending on how the plugin was loaded:
# the script-derived dev-repo PLUGIN_ROOT (a bare --plugin-dir run), the installed cache
# (resolve_installed_plugin_root, when marketplace-installed), AND this marketplace-checkout dir
# — the last one observed emitting `.../marketplaces/engineer-agent/scripts/slack-mcp.sh read …`
# and getting DENIED because the allowlist covered only the first two. The shim allowlist in
# cron-poll.sh / approval-listener.sh must cover all three candidate roots so whichever one the
# runtime resolves, a rule matches. See the "mcp-proxy gotcha" note in cron-poll.sh and CLAUDE.md.
resolve_marketplace_plugin_root() {
  local dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins/marketplaces/engineer-agent"
  [ -d "$dir" ] && [ -f "$dir/scripts/slack-mcp.sh" ] && printf '%s\n' "$dir"
}

# --- Per-project config readers (dependency-free, indent-aware awk) -----------------
# Used by approval-listener.sh to prepare a confined headless ticket implementation:
# it needs the project's checkout path and its allow-listed build commands, both read
# from the YAML in plain bash (the listener is deliberately NOT subject to the claude
# allowlist, so these privileged inputs are resolved before `claude -p` starts). The
# awk mirrors yaml_ntfy_get()'s block-scoping: enter `projects:`, descend into the
# `<slug>:` header at +2, then read the requested field. Config is user-authored and
# trusted; the caller still validates each command against a safe charset as defense
# in depth (an allowlist rule is security-load-bearing).

# yaml_project_scalar <slug> <key> — a scalar directly under projects.<slug>
# (e.g. `path`). Prints the unquoted value, or nothing if absent.
yaml_project_scalar() {
  local slug="$1" key="$2"
  [ -f "$EA_CONFIG_FILE" ] || return 0
  awk -v slug="$slug" -v key="$key" '
    !inproj && $1=="projects:" { inproj=1; match($0,/^ */); pbase=RLENGTH; next }
    inproj {
      match($0,/^ */); ind=RLENGTH
      if (length($0)==0) next
      if ($0 ~ /^[ \t]*#/) next   # full-line comment: skip (a col-0 "#" is NOT a dedent)
      if (ind<=pbase) exit
      line=$0; sub(/^ +/,"",line)
      if (!inslug) { if (ind==pbase+2 && line==slug":") { inslug=1; sbase=ind } ; next }
      if (ind<=sbase) exit
      if (ind==sbase+2) {
        k=line; sub(/:.*/,"",k)
        if (k==key) {
          v=substr(line,index(line,":")+1); sub(/^[ \t]+/,"",v)
          print yaml_scalar(v); exit
        }
      }
    }
    function yaml_scalar(s,   q) {
      # Extract a YAML scalar: quoted ("..."/@apos) -> content between quotes;
      # unquoted -> value up to an inline " #" comment, whitespace-trimmed.
      if (substr(s,1,1)=="\"") { s=substr(s,2); q=index(s,"\""); return (q>0)?substr(s,1,q-1):s }
      if (substr(s,1,1)=="\x27") { s=substr(s,2); q=index(s,"\x27"); return (q>0)?substr(s,1,q-1):s }
      sub(/[ \t]+#.*$/,"",s); sub(/[ \t]+$/,"",s); return s
    }
  ' "$EA_CONFIG_FILE"
}

# yaml_project_subscalar <slug> <parent> <key> — a scalar nested one level deeper than
# yaml_project_scalar, at projects.<slug>.<parent>.<key> (e.g. qa.base_url). Prints the
# unquoted value, or nothing if absent. Same descent as yaml_project_list, but reads the
# scalar at sbase+4 under <parent> instead of collecting list items.
yaml_project_subscalar() {
  local slug="$1" parent="$2" key="$3"
  [ -f "$EA_CONFIG_FILE" ] || return 0
  awk -v slug="$slug" -v parent="$parent" -v key="$key" '
    !inproj && $1=="projects:" { inproj=1; match($0,/^ */); pbase=RLENGTH; next }
    inproj {
      match($0,/^ */); ind=RLENGTH
      if (length($0)==0) next
      if ($0 ~ /^[ \t]*#/) next   # full-line comment: skip (a col-0 "#" is NOT a dedent)
      if (ind<=pbase) exit
      line=$0; sub(/^ +/,"",line)
      if (!inslug) { if (ind==pbase+2 && line==slug":") { inslug=1; sbase=ind } ; next }
      if (ind<=sbase) exit
      if (ind==sbase+2) { inparent=(line==parent":"); next }
      if (inparent && ind==sbase+4) {
        k=line; sub(/:.*/,"",k)
        if (k==key) {
          v=substr(line,index(line,":")+1); sub(/^[ \t]+/,"",v)
          print yaml_scalar(v); exit
        }
      }
    }
    function yaml_scalar(s,   q) {
      if (substr(s,1,1)=="\"") { s=substr(s,2); q=index(s,"\""); return (q>0)?substr(s,1,q-1):s }
      if (substr(s,1,1)=="\x27") { s=substr(s,2); q=index(s,"\x27"); return (q>0)?substr(s,1,q-1):s }
      sub(/[ \t]+#.*$/,"",s); sub(/[ \t]+$/,"",s); return s
    }
  ' "$EA_CONFIG_FILE"
}

# yaml_agent_slack <key> — a scalar directly under agent.slack.<key> (e.g. method, bin).
# Scoping to the agent: block matters because `slack:` ALSO appears under every
# projects.<slug>; a bare "find slack:" would match the wrong one. Descent: agent: (col 0)
# -> slack: (+2) -> <key> (+4). Prints the unquoted value, or nothing if absent.
yaml_agent_slack() {
  local key="$1"
  [ -f "$EA_CONFIG_FILE" ] || return 0
  awk -v key="$key" '
    !inagent && $1=="agent:" { inagent=1; next }
    inagent {
      match($0,/^ */); ind=RLENGTH
      if (length($0)==0) next
      if ($0 ~ /^[ \t]*#/) next
      if (ind==0) exit
      line=$0; sub(/^ +/,"",line)
      h=line; sub(/:.*/,"",h)               # block/key name, trailing comment stripped
      if (ind==2) { inslack=(h=="slack"); next }
      if (inslack && ind==4 && h==key) {
        v=substr(line,index(line,":")+1); sub(/^[ \t]+/,"",v); print yaml_scalar(v); exit
      }
    }
    function yaml_scalar(s,   q) {
      if (substr(s,1,1)=="\"")   { s=substr(s,2); q=index(s,"\"");   return (q>0)?substr(s,1,q-1):s }
      if (substr(s,1,1)=="\x27") { s=substr(s,2); q=index(s,"\x27"); return (q>0)?substr(s,1,q-1):s }
      sub(/[ \t]+#.*$/,"",s); sub(/[ \t]+$/,"",s); return s
    }
  ' "$EA_CONFIG_FILE"
}

# yaml_agent_slack_mcp <key> — a scalar one level deeper, at agent.slack.mcp.<key> (e.g.
# server, server_id). Same agent:-scoped descent as yaml_agent_slack, plus the mcp: level (+6).
yaml_agent_slack_mcp() {
  local key="$1"
  [ -f "$EA_CONFIG_FILE" ] || return 0
  awk -v key="$key" '
    !inagent && $1=="agent:" { inagent=1; next }
    inagent {
      match($0,/^ */); ind=RLENGTH
      if (length($0)==0) next
      if ($0 ~ /^[ \t]*#/) next
      if (ind==0) exit
      line=$0; sub(/^ +/,"",line)
      h=line; sub(/:.*/,"",h)               # block/key name, trailing comment stripped
      if (ind==2) { inslack=(h=="slack"); inmcp=0; next }
      if (inslack && ind==4) { inmcp=(h=="mcp"); next }
      if (inslack && inmcp && ind==6 && h==key) {
        v=substr(line,index(line,":")+1); sub(/^[ \t]+/,"",v); print yaml_scalar(v); exit
      }
    }
    function yaml_scalar(s,   q) {
      if (substr(s,1,1)=="\"")   { s=substr(s,2); q=index(s,"\"");   return (q>0)?substr(s,1,q-1):s }
      if (substr(s,1,1)=="\x27") { s=substr(s,2); q=index(s,"\x27"); return (q>0)?substr(s,1,q-1):s }
      sub(/[ \t]+#.*$/,"",s); sub(/[ \t]+$/,"",s); return s
    }
  ' "$EA_CONFIG_FILE"
}

# yaml_project_list <slug> <parent> <listkey> — items of the list at
# projects.<slug>.<parent>.<listkey> (e.g. exec.allowed_commands). One item per line,
# unquoted, `- ` stripped.
yaml_project_list() {
  local slug="$1" parent="$2" listkey="$3"
  [ -f "$EA_CONFIG_FILE" ] || return 0
  awk -v slug="$slug" -v parent="$parent" -v listkey="$listkey" '
    !inproj && $1=="projects:" { inproj=1; match($0,/^ */); pbase=RLENGTH; next }
    inproj {
      match($0,/^ */); ind=RLENGTH
      if (length($0)==0) next
      if ($0 ~ /^[ \t]*#/) next   # full-line comment: skip (a col-0 "#" is NOT a dedent)
      if (ind<=pbase) exit
      line=$0; sub(/^ +/,"",line)
      if (!inslug) { if (ind==pbase+2 && line==slug":") { inslug=1; sbase=ind } ; next }
      if (ind<=sbase) exit
      if (ind==sbase+2) { inparent=(line==parent":"); inlist=0; next }
      if (inparent && ind==sbase+4) { k=line; sub(/:.*/,"",k); inlist=(k==listkey); next }
      if (inparent && inlist && ind>=sbase+6 && substr(line,1,1)=="-") {
        item=line; sub(/^-[ \t]*/,"",item); item=yaml_scalar(item)
        if (length(item)) print item
      }
    }
    function yaml_scalar(s,   q) {
      if (substr(s,1,1)=="\"") { s=substr(s,2); q=index(s,"\""); return (q>0)?substr(s,1,q-1):s }
      if (substr(s,1,1)=="\x27") { s=substr(s,2); q=index(s,"\x27"); return (q>0)?substr(s,1,q-1):s }
      sub(/[ \t]+#.*$/,"",s); sub(/[ \t]+$/,"",s); return s
    }
  ' "$EA_CONFIG_FILE"
}
