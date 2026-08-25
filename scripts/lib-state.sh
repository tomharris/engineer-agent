#!/bin/bash
# lib-state.sh — read/modify/write state/last-poll.yaml (the dedup cutoffs and seen-id sets).
#
# WHY A ROUND-TRIP RATHER THAN AN IN-PLACE EDIT: the state file holds sections this refactor does
# NOT own. Jira and Slite polling stay model-driven, so jira_projects.* and projects.<slug>.slite.*
# keep being written by a model, and the scripted GitHub collectors must leave them byte-equivalent.
# Parsing the whole document to a flat form, changing only the addressed keys, and re-emitting
# guarantees that: an untouched key round-trips because it is copied, not because a targeted awk
# happened not to match it.
#
# PATHS ARE PIPE-SEPARATED, not dot-separated, because a key here can legitimately contain a dot —
# github_repos holds "owner/repo" and a repo may be named "foo.js". A dotted path would silently
# address the wrong node for exactly those repos.
#
# WHAT IS LOST IN THE ROUND-TRIP: comments and key order. state/last-poll.yaml is machine-written
# and machine-read and has never carried comments; the file is re-emitted in sorted order, which is
# stable across runs (so a diff shows only real changes) even though it may differ once from the
# model-written original.
#
# LIVENESS AND DEDUP STAY SEPARATE. This file is a semantic dedup cutoff, NOT a health signal.
# cron-poll.sh learned that the hard way: it used to fingerprint this file and warn when the hash
# was unchanged, which false-warned on every quiet Slack poll and could be defeated by a model
# fabricating a timestamp. Liveness belongs in the receipt; do not overload these values with it.
#
# Requires lib-yaml.sh.

EA_STATE=""

# state_load [file] — parse the state file into the flat form held in $EA_STATE.
state_load() {
  local f="${1:-${EA_AGENT_DIR}/state/last-poll.yaml}"
  EA_STATE="$(YAML_SEP='|' yaml_dump "$f")"
}

# state_get <a|b|c>
state_get() {
  printf '%s\n' "$EA_STATE" | awk -F= -v k="$1" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }'
}

# state_list <a|b|c>
state_list() {
  printf '%s\n' "$EA_STATE" | awk -v p="$1[]=" 'index($0, p) == 1 { print substr($0, length(p) + 1) }'
}

# state_set <a|b|c> <value> — set or replace a scalar, creating parents implicitly.
state_set() {
  local path="$1" val="$2"
  EA_STATE="$(printf '%s\n' "$EA_STATE" | grep -v -x -F "${path}={{X}}" | awk -v p="${path}=" 'index($0,p)!=1')"
  EA_STATE="${EA_STATE}
${path}=${val}"
}

# state_list_add <a|b|c> <item> — append to a list, ignoring duplicates.
#
# seen_* sets are a CHEAP PRE-FILTER, never the invariant: references/queue-reconciliation.md is
# explicit that "a seen_* hit is a reason to skip querying detail, never a substitute for the
# reconciliation lookup", and that "a seen_* miss does not license a write". Keep it that way — the
# filesystem lookup in lib-queue.sh is what actually enforces one-item-per-source_id.
state_list_add() {
  local path="$1" item="$2"
  printf '%s\n' "$EA_STATE" | grep -q -x -F "${path}[]=${item}" && return 0
  EA_STATE="${EA_STATE}
${path}[]=${item}"
}

# state_save [file] — re-emit the flat form as nested YAML.
state_save() {
  local f="${1:-${EA_AGENT_DIR}/state/last-poll.yaml}" tmp
  tmp="$(mktemp)"
  printf '%s\n' "$EA_STATE" \
    | sed -E '/^[[:space:]]*$/d' \
    | grep -v '{}$' \
    | LC_ALL=C sort -u \
    | awk -F'\n' '
      function emit_headers(path,   i, n, segs, indent) {
        n = split(path, segs, "|")
        for (i = 1; i < n; i++) {
          if (open_at[i] != segs[i] || changed) {
            indent = ""
            for (j = 1; j < i; j++) indent = indent "  "
            printf "%s%s:\n", indent, segs[i]
            open_at[i] = segs[i]
            changed = 1
            for (j = i + 1; j <= n; j++) open_at[j] = ""
          }
        }
        return n
      }
      {
        line = $0
        islist = 0
        if (index(line, "[]=") > 0) { islist = 1; eq = index(line, "[]="); key = substr(line, 1, eq - 1); val = substr(line, eq + 3) }
        else if (index(line, "[]#empty") > 0) { islist = 2; key = substr(line, 1, index(line, "[]#empty") - 1); val = "" }
        else { eq = index(line, "="); if (eq == 0) next; key = substr(line, 1, eq - 1); val = substr(line, eq + 1) }

        n = split(key, segs, "|")
        # Emit any parent headers that are not already open.
        for (i = 1; i < n; i++) {
          if (open_at[i] != segs[i]) {
            indent = ""
            for (j = 1; j < i; j++) indent = indent "  "
            printf "%s%s:\n", indent, segs[i]
            open_at[i] = segs[i]
            for (j = i + 1; j <= n; j++) open_at[j] = ""
          }
        }
        indent = ""
        for (j = 1; j < n; j++) indent = indent "  "
        leaf = segs[n]
        if (islist == 1) {
          if (last_list != key) { printf "%s%s:\n", indent, leaf; last_list = key }
          printf "%s  - \"%s\"\n", indent, val
        } else if (islist == 2) {
          printf "%s%s: []\n", indent, leaf; last_list = ""
        } else {
          printf "%s%s: \"%s\"\n", indent, leaf, val; last_list = ""
        }
      }
    ' > "$tmp"
  mkdir -p "$(dirname "$f")"
  mv "$tmp" "$f"
}
