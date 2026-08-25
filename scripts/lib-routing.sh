#!/bin/bash
# lib-routing.sh — the deterministic tiers of references/routing-ladder.md: which project does this
# ticket belong to?
#
# Implements Tier 0 (candidate set), Tier 1 (title prefix), Tier 2 (config filters), Tier 3a
# (deterministic hints) and Tier 4 (unrouted). Tier 3b — semantic inference against
# routing.description — is NOT implemented here; it is the one tier that requires judgment, and the
# spec is explicit that abstaining beats guessing ("a tie falls to Tier 4, never to a coin flip").
# When 3a leaves things unresolved AND at least one candidate carries a routing block, this library
# reports needs_inference=1 so the caller can hand exactly those to a model.
#
# OUTPUT — one tab-separated line: <slug>\t<method>\t<rationale>\t<needs_inference>\t<matched>
#   slug             the routed project, or "_unrouted"
#   method           single-candidate | prefix | filters | keyword | "" (when unrouted)
#   rationale        one line naming the evidence (only meaningful for keyword/inferred)
#   needs_inference  1 when Tier 3b could still resolve this and a model should be asked
#   matched          space-separated candidate slugs (becomes matched_projects: on an unrouted item)
#
# INJECTION CONTAINMENT, preserved structurally: the candidate set is computed from CONFIG ALONE
# (Tier 0), and every later tier can only narrow it. So this library can only ever emit a slug the
# config already permits — an injected payload can at worst shuffle a ticket between projects that
# already legitimately watch that repo. Ticket text is matched as DATA (topic only); imperatives
# inside it ("assign this to X") are never executed, because the only thing text can do here is
# match or fail to match a config-supplied string.
#
# Requires a normalized config view on stdin-free lookup: set EA_CFG to the output of
# `ea-config.sh dump` before calling, or export it once per run.

# _rt_lower <s>
_rt_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
_rt_trim()  { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# _rt_cfg_get <path> / _rt_cfg_list <path> — read the normalized config held in $EA_CFG.
_rt_cfg_get()  { printf '%s\n' "${EA_CFG:-}" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }
_rt_cfg_list() { printf '%s\n' "${EA_CFG:-}" | awk -v p="$1[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}'; }

# _rt_has_word <text> <word> — case-insensitive WHOLE-WORD match.
#
# Whole-word is load-bearing and called out in the spec: "so `void` does not fire on `avoid`".
# A substring test here silently misroutes tickets between projects that share a repo, and the
# result looks like a confident decision rather than a bug.
_rt_has_word() {
  local text word
  text="$(_rt_lower "$1")"; word="$(_rt_lower "$2")"
  [ -n "$word" ] || return 1
  # Pad so a match at either end still has a boundary, then require non-alphanumeric neighbours.
  printf ' %s ' "$text" | grep -qE "[^[:alnum:]_]$(printf '%s' "$word" | sed 's/[][\.*^$/+?(){}|]/\\&/g')[^[:alnum:]_]"
}

# _rt_path_hit <text> <glob> — does any file-path-looking token in the text match this glob?
# Paths appear in stack traces, `code spans`, and prose ("in app/payroll/void.rb"), so candidate
# tokens are extracted first rather than globbing the whole blob.
_rt_path_hit() {
  local text="$1" glob="$2" tok
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    # shellcheck disable=SC2254
    case "$tok" in $glob) return 0 ;; esac
  done < <(printf '%s' "$text" | tr -c '[:alnum:]_./-' '\n' | grep -E '^[[:alnum:]_.-]+(/[[:alnum:]_.-]+)+$')
  return 1
}

# _rt_list_has <needle> <list-on-stdin> — case-insensitive whole-string membership.
_rt_list_has() {
  local needle item
  needle="$(_rt_lower "$(_rt_trim "$1")")"
  while IFS= read -r item || [ -n "$item" ]; do
    [ -n "$item" ] || continue
    [ "$(_rt_lower "$(_rt_trim "$item")")" = "$needle" ] && return 0
  done
  return 1
}

# route_candidates_github <owner> <repo> — Tier 0 for GitHub. Every project whose tracker resolves
# to github-issues, whose github.owner matches, and whose github.repos contains the repo.
route_candidates_github() {
  local owner="$1" repo="$2" slug
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    [ "$(_rt_cfg_get "projects.${slug}.tracker")" = "github-issues" ] || continue
    [ "$(_rt_lower "$(_rt_cfg_get "projects.${slug}.github.owner")")" = "$(_rt_lower "$owner")" ] || continue
    _rt_cfg_list "projects.${slug}.github.repos" | _rt_list_has "$repo" || continue
    printf '%s\n' "$slug"
  done < <(_rt_cfg_list project)
}

# route_candidates_github_prs <owner> <repo> — Tier 0 for PR review. Same shape, but PR review is
# not gated on the tracker (a project can review PRs while tracking work in Jira), so the predicate
# is the github section alone.
route_candidates_github_prs() {
  local owner="$1" repo="$2" slug
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    [ "$(_rt_lower "$(_rt_cfg_get "projects.${slug}.github.owner")")" = "$(_rt_lower "$owner")" ] || continue
    _rt_cfg_list "projects.${slug}.github.repos" | _rt_list_has "$repo" || continue
    printf '%s\n' "$slug"
  done < <(_rt_cfg_list project)
}

# _rt_title_prefix <title> — the leading [<token>], trimmed. Empty when absent.
_rt_title_prefix() {
  local t; t="$(_rt_trim "$1")"
  case "$t" in
    "["*) t="${t#\[}"; case "$t" in *"]"*) _rt_trim "${t%%]*}"; return 0 ;; esac ;;
  esac
  return 0
}

# route_ticket — the ladder. Named arguments:
#   --candidates "<slug> <slug> ..."   (required; from a route_candidates_* helper)
#   --title <title>
#   --body <body>
#   --labels-file <file>               GitHub labels, one per line (Tier 2)
#
# Jira's Tier 2 (source.components / source.labels) is intentionally absent: Jira polling stays
# model-driven, and a half-implemented Jira path would be worse than none — it would look supported.
route_ticket() {
  local cands="" title="" body="" f_labels=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --candidates) cands="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      --labels-file) f_labels="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local list=() s
  for s in $cands; do list+=("$s"); done
  local n=${#list[@]}
  local matched="${cands}"

  # --- Tier 0 ------------------------------------------------------------------------------
  # Exactly one candidate routes for free. "It must stay free" — a project that is the sole
  # watcher of its repo pays nothing for any of the machinery below.
  if [ "$n" -eq 0 ]; then printf '_unrouted\t\t\t0\t\n'; return 0; fi
  if [ "$n" -eq 1 ]; then printf '%s\tsingle-candidate\t\t0\t%s\n' "${list[0]}" "$matched"; return 0; fi

  # --- Tier 1: title prefix ----------------------------------------------------------------
  local token hits=() slug
  token="$(_rt_title_prefix "$title")"
  if [ -n "$token" ]; then
    for slug in "${list[@]}"; do
      if [ "$(_rt_lower "$slug")" = "$(_rt_lower "$token")" ]; then hits+=("$slug"); continue; fi
      if _rt_cfg_list "projects.${slug}.github.repos" | _rt_list_has "$token"; then hits+=("$slug"); fi
    done
    # Exactly one, or the prefix is ignored entirely. The token must equal an already-configured
    # slug or repo, so this tier cannot be steered somewhere the config does not already permit.
    if [ "${#hits[@]}" -eq 1 ]; then printf '%s\tprefix\ttitle prefix [%s]\t0\t%s\n' "${hits[0]}" "$token" "$matched"; return 0; fi
  fi

  # --- Tier 2: explicit config filters -----------------------------------------------------
  # github.issues.labels applied HERE as a routing predicate against an already-fetched issue —
  # never as a `gh issue list --label` flag, which means AND and cannot union several watchers.
  hits=()
  for slug in "${list[@]}"; do
    local want; want="$(_rt_cfg_list "projects.${slug}.github.issues.labels")"
    if [ -z "$want" ]; then hits+=("$slug"); continue; fi     # absent/empty => catch-all
    if [ -n "${f_labels:-}" ] && [ -f "$f_labels" ]; then
      local l
      while IFS= read -r l || [ -n "$l" ]; do
        [ -n "$l" ] || continue
        if printf '%s\n' "$want" | _rt_list_has "$l"; then hits+=("$slug"); break; fi
      done < "$f_labels"
    fi
  done
  if [ "${#hits[@]}" -eq 1 ]; then printf '%s\tfilters\tlabel filter\t0\t%s\n' "${hits[0]}" "$matched"; return 0; fi

  # --- Tier 3a: deterministic hints --------------------------------------------------------
  # Skipped ENTIRELY when no candidate has a routing block: inference is opt-in, and this is what
  # keeps installs that never add hints behaving exactly as they did before the ladder existed.
  local any_hints=0 text; text="${title} ${body}"
  for slug in "${list[@]}"; do
    if [ -n "$(_rt_cfg_get "projects.${slug}.routing.description")" ] \
       || [ -n "$(_rt_cfg_list "projects.${slug}.routing.keywords")" ] \
       || [ -n "$(_rt_cfg_list "projects.${slug}.routing.paths")" ]; then any_hints=1; break; fi
  done
  if [ "$any_hints" -eq 0 ]; then printf '_unrouted\t\t\t0\t%s\n' "$matched"; return 0; fi

  hits=(); local why=""
  for slug in "${list[@]}"; do
    local hit=0 kw pth
    while IFS= read -r kw; do
      [ -n "$kw" ] || continue
      if _rt_has_word "$text" "$kw"; then hit=1; why="keyword '$kw'"; break; fi
    done < <(_rt_cfg_list "projects.${slug}.routing.keywords")
    if [ "$hit" -eq 0 ]; then
      while IFS= read -r pth; do
        [ -n "$pth" ] || continue
        if _rt_path_hit "$text" "$pth"; then hit=1; why="path '$pth'"; break; fi
      done < <(_rt_cfg_list "projects.${slug}.routing.paths")
    fi
    [ "$hit" -eq 1 ] && hits+=("$slug")
  done
  if [ "${#hits[@]}" -eq 1 ]; then printf '%s\tkeyword\t%s\t0\t%s\n' "${hits[0]}" "$why" "$matched"; return 0; fi

  # --- Tier 3b is a model's job; Tier 4 is the human's ------------------------------------
  # Report unrouted AND flag that inference could still resolve it. The caller writes the item as
  # project: _unrouted with matched_projects, which is exactly the shape the documented
  # "incoming/ + _unrouted -> update in place" reconciliation branch already knows how to finish.
  printf '_unrouted\t\t\t1\t%s\n' "$matched"
}
