#!/bin/bash
# ea-config.sh — normalize engineer.yaml into a flat, greppable view for the scripted pollers.
#
# WHY A NORMALIZER RATHER THAN LETTING EACH SCRIPT READ THE YAML: the rules that turn raw config
# into effective config are subtle, and they are currently restated in prose in every poll skill —
# tracker inference (poll-github-issues step 3, poll-jira step 3), the investigation REPLACE-not-
# merge override (references/ticket-kind.md), the agent-vs-project Slack workspace fallback
# (poll-slack step 1), and the per-source "is this even configured" test that produces the receipt's
# `skipped:` bucket. Restating those in each collector would recreate exactly the drift CLAUDE.md
# warns about. Resolve them ONCE, here, and let every consumer grep the result.
#
# SECURITY — this deliberately emits a CURATED view, not the whole document. agent.notify.ntfy.*
# (topic, command_topic, auth_token) is omitted: on public ntfy.sh a topic name is effectively a
# password, and a poller has no use for one (notify.sh resolves its own settings via lib-ntfy.sh).
# Keeping secrets out of the normalized view means the output can be logged, cached in a variable,
# or dumped while debugging without leaking the remote-approval credential.
#
# Usage:
#   ea-config.sh dump                 all normalized keys
#   ea-config.sh projects             one project slug per line
#   ea-config.sh get <path>           a single scalar
#   ea-config.sh list <path>          a list, one item per line
#   ea-config.sh sources <slug>       "<source>\t<configured|skipped:<reason>>" per source
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "${SCRIPT_DIR}/lib-paths.sh"
# shellcheck source=lib-yaml.sh
. "${SCRIPT_DIR}/lib-yaml.sh"

# Shipped investigation defaults. These MUST match references/ticket-kind.md and
# config/engineer.example.yaml; tests/ea-config.test.sh pins them against the example file so the
# three cannot drift apart.
DEFAULT_JIRA_TYPES="Spike Decision Task"
DEFAULT_GITHUB_LABELS="spike research investigation decision adr rfc discovery"
DEFAULT_TITLE_KEYWORDS="spike decision adr rfc investigate research evaluate compare assess determine"

# Parse the document once. Every lookup below reads this cache instead of re-running awk, which
# matters: a 6-project config with 5 sources each would otherwise re-parse the file ~100 times per
# poll.
YAML_DUMP_CACHE="$(yaml_dump "$EA_CONFIG_FILE")"
export YAML_DUMP_CACHE

_get()  { yaml_get "$1"; }
_list() { yaml_get_list "$1"; }
_has()  { yaml_has_list "$1"; }

# _emit_list <out_path> <yaml_path> — copy a list through, preserving the empty-vs-absent
# distinction so downstream consumers can still tell "explicitly disabled" from "not set".
_emit_list() {
  local out="$1" src="$2" n=0 item
  while IFS= read -r item; do [ -n "$item" ] || continue; printf '%s[]=%s\n' "$out" "$item"; n=1; done < <(_list "$src")
  [ "$n" -eq 0 ] && _has "$src" && printf '%s[]#empty\n' "$out"
  return 0
}

# _effective_kind_list <slug> <key> <shipped default...>
# references/ticket-kind.md: effective(k) = projects.<slug>.investigation.k ?? agent.investigation.k
#                                        ?? shipped default
# REPLACE, not merge — a project narrows a list by restating it, which is the operation that fixes a
# false positive. An explicitly empty list DISABLES that tier, which is why presence (not just
# content) is tested here; collapsing empty into absent would make the tier impossible to switch off.
_effective_kind_list() {
  local slug="$1" key="$2" shipped="$3" src="" w
  if _has "projects.${slug}.investigation.${key}"; then src="projects.${slug}.investigation.${key}"
  elif _has "agent.investigation.${key}";          then src="agent.investigation.${key}"
  fi
  if [ -n "$src" ]; then
    local n=0 item
    while IFS= read -r item; do [ -n "$item" ] || continue; printf '%s\n' "$item"; n=1; done < <(_list "$src")
    # Present but empty => the tier is deliberately off. Emit nothing, and do NOT fall back.
    return 0
  fi
  for w in $shipped; do printf '%s\n' "$w"; done
}

# _tracker <slug> — explicit projects.<slug>.tracker, else inferred exactly as poll-github-issues
# step 3 and poll-jira step 3 describe: a jira section wins, then a github.issues section, else none.
_tracker() {
  local slug="$1" t
  t="$(_get "projects.${slug}.tracker")"
  if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
  if printf '%s\n' "$YAML_DUMP_CACHE" | grep -q "^projects\.${slug}\.jira{}$"; then printf 'jira'; return 0; fi
  if printf '%s\n' "$YAML_DUMP_CACHE" | grep -q "^projects\.${slug}\.github\.issues{}$"; then printf 'github-issues'; return 0; fi
  printf 'none'
}

# _source_state <slug> <source> — "configured" or "skipped:<reason>".
#
# This is the single source of truth for the receipt's `skipped:` bucket. cron-poll.sh's prompt
# currently makes the MODEL decide which of three buckets each source belongs in, and the rule it
# must apply ("a skipped source is a normal, expected result and MUST NOT affect status") is exactly
# the kind of bookkeeping a script does not get wrong. The reason strings match the wording already
# appearing in state/last-poll-receipt.yaml so the change is invisible in the receipt's diff.
_source_state() {
  local slug="$1" src="$2" tracker; tracker="$(_tracker "$slug")"
  case "$src" in
    github)
      [ -n "$(_get "projects.${slug}.github.owner")" ] || { printf 'skipped:no github section configured'; return 0; }
      [ -n "$(_list "projects.${slug}.github.repos")" ] || { printf 'skipped:github.repos is empty'; return 0; }
      [ -n "$(_get "projects.${slug}.github.review_requested_for")" ] || { printf 'skipped:github.review_requested_for is unset'; return 0; }
      printf 'configured' ;;
    github_issues)
      [ "$tracker" = "github-issues" ] || { printf 'skipped:tracker is %s' "$tracker"; return 0; }
      [ -n "$(_get "projects.${slug}.github.issues.assignee")" ] || { printf 'skipped:no github.issues section'; return 0; }
      printf 'configured' ;;
    slack)
      [ -n "$(_list "projects.${slug}.slack.channels")" ] || { printf 'skipped:slack.channels is empty'; return 0; }
      printf 'configured' ;;
    jira)
      # Wording matched to what the model has been writing, so switching to the scripted path
      # produces no spurious diff in state/last-poll-receipt.yaml.
      [ "$tracker" = "jira" ] || { printf 'skipped:tracker is %s, no jira section' "$tracker"; return 0; }
      printf 'configured' ;;
    slite)
      printf '%s\n' "$YAML_DUMP_CACHE" | grep -q "^projects\.${slug}\.slite{}$" || { printf 'skipped:no slite section configured'; return 0; }
      [ -n "$(_list "projects.${slug}.slite.doc_labels")" ] || { printf 'skipped:slite.doc_labels is empty'; return 0; }
      printf 'configured' ;;
    *) printf 'skipped:unknown source' ;;
  esac
}

cmd_projects() { yaml_keys projects; }

cmd_dump() {
  local slug w

  # --- agent-level, with the defaults the skills currently state in prose -------------------
  local v
  v="$(_get agent.branch_prefix)";       printf 'agent.branch_prefix=%s\n'      "${v:-engineer-agent}"
  v="$(_get agent.max_pr_files)";        printf 'agent.max_pr_files=%s\n'       "${v:-50}"
  v="$(_get agent.max_issue_age_days)";  printf 'agent.max_issue_age_days=%s\n' "${v:-0}"
  v="$(_get agent.slack.method)";        printf 'agent.slack.method=%s\n'       "${v:-spy}"
  v="$(_get agent.slack.bin)";           printf 'agent.slack.bin=%s\n'          "${v:-spy}"
  printf 'agent.slack.workspace=%s\n'    "$(_get agent.slack.workspace)"
  _emit_list agent.autonomy.auto_execute agent.autonomy.auto_execute
  # Which sources are collected by a deterministic script instead of by the model. Absent or empty
  # => today's prompt-driven path, unchanged. Deny-by-default, matching the posture of
  # agent.autonomy.auto_execute and projects.<slug>.exec.allowed_commands.
  _emit_list agent.poll.scripted_sources agent.poll.scripted_sources

  # --- per project ---------------------------------------------------------------------------
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    printf 'project[]=%s\n' "$slug"
    printf 'projects.%s.path=%s\n'    "$slug" "$(_get "projects.${slug}.path")"
    printf 'projects.%s.tracker=%s\n' "$slug" "$(_tracker "$slug")"

    printf 'projects.%s.github.owner=%s\n'                 "$slug" "$(_get "projects.${slug}.github.owner")"
    printf 'projects.%s.github.review_requested_for=%s\n'  "$slug" "$(_get "projects.${slug}.github.review_requested_for")"
    printf 'projects.%s.github.issues.assignee=%s\n'       "$slug" "$(_get "projects.${slug}.github.issues.assignee")"
    _emit_list "projects.${slug}.github.repos"          "projects.${slug}.github.repos"
    _emit_list "projects.${slug}.github.ignore_labels"  "projects.${slug}.github.ignore_labels"
    _emit_list "projects.${slug}.github.issues.labels"  "projects.${slug}.github.issues.labels"

    # Effective Slack workspace: project overrides agent (poll-slack step 1).
    v="$(_get "projects.${slug}.slack.workspace")"
    [ -n "$v" ] || v="$(_get agent.slack.workspace)"
    printf 'projects.%s.slack.workspace=%s\n' "$slug" "$v"
    v="$(_get "projects.${slug}.slack.ignore_bots")"
    printf 'projects.%s.slack.ignore_bots=%s\n' "$slug" "${v:-true}"
    _emit_list "projects.${slug}.slack.channels" "projects.${slug}.slack.channels"
    _emit_list "projects.${slug}.slack.keywords" "projects.${slug}.slack.keywords"

    printf 'projects.%s.routing.description=%s\n' "$slug" "$(_get "projects.${slug}.routing.description")"
    _emit_list "projects.${slug}.routing.keywords" "projects.${slug}.routing.keywords"
    _emit_list "projects.${slug}.routing.paths"    "projects.${slug}.routing.paths"

    # Effective (already-resolved) kind lists — consumers must never re-apply the override rule.
    while IFS= read -r w; do [ -n "$w" ] && printf 'projects.%s.investigation.jira_types[]=%s\n'     "$slug" "$w"; done < <(_effective_kind_list "$slug" jira_types     "$DEFAULT_JIRA_TYPES")
    while IFS= read -r w; do [ -n "$w" ] && printf 'projects.%s.investigation.github_labels[]=%s\n'  "$slug" "$w"; done < <(_effective_kind_list "$slug" github_labels  "$DEFAULT_GITHUB_LABELS")
    while IFS= read -r w; do [ -n "$w" ] && printf 'projects.%s.investigation.title_keywords[]=%s\n' "$slug" "$w"; done < <(_effective_kind_list "$slug" title_keywords "$DEFAULT_TITLE_KEYWORDS")
    printf 'projects.%s.investigation.on_complete_status=%s\n' "$slug" "$(_get "projects.${slug}.investigation.on_complete_status")"

    for w in github github_issues slack jira slite; do
      printf 'projects.%s.source.%s=%s\n' "$slug" "$w" "$(_source_state "$slug" "$w")"
    done
  done < <(yaml_keys projects)
}

cmd_sources() {
  local slug="$1" s
  for s in github github_issues slack jira slite; do
    printf '%s\t%s\n' "$s" "$(_source_state "$slug" "$s")"
  done
}

case "${1:-}" in
  dump)     cmd_dump ;;
  projects) cmd_projects ;;
  get)      _get "${2:-}" ;;
  list)     _list "${2:-}" ;;
  sources)  [ -n "${2:-}" ] || { echo "ea-config.sh sources <slug>" >&2; exit 2; }; cmd_sources "$2" ;;
  ""|-h|--help)
    sed -n '/^# Usage:/,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1 ;;
  *) echo "ea-config.sh: unknown command '$1'" >&2; exit 2 ;;
esac
