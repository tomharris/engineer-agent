#!/bin/bash
# lib-queue-write.sh — construct queue items. Single source of truth for the filename shape, the
# frontmatter, the `## Context` body, and the branch-slug transform.
#
# WHY CENTRALIZE: five poll skills each restate the filename convention and the frontmatter field
# list in prose, and they have already drifted (poll-jira derives a branch as
# "{branch_prefix}/{ticket_key}" while poll-github-issues uses
# "{branch_prefix}/issue-{n}-{slug}"). A queue item with a malformed field is not a loud failure —
# review-queue renders a blank column, or the ntfy listener's item-id regex quietly refuses it.
#
# YAML ESCAPING IS THE REASON THIS IS NOT A HEREDOC. Real issue titles contain double quotes,
# backslashes and colons ("Fix \"null\" handling in Foo::Bar"). Every field below is emitted as a
# double-quoted YAML scalar with " and \ escaped. When the model writes these files by hand it is
# *asked* to quote correctly; here it cannot be otherwise. A broken frontmatter block silently
# truncates every field after it, because the awk readers stop at the first line they cannot parse.

# yaml_escape <s> — escape for a double-quoted YAML scalar, and flatten newlines (frontmatter
# scalars are single-line by construction).
yaml_escape() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r' '  '
}

# yaml_list <item...> — a YAML flow sequence: ["a", "b"] or [].
yaml_list() {
  local out="" i
  for i in "$@"; do
    [ -n "$i" ] || continue
    [ -n "$out" ] && out="${out}, "
    out="${out}\"$(yaml_escape "$i")\""
  done
  printf '[%s]' "$out"
}

# queue_ts [epoch] — the {YYYYMMDD-HHmmss} filename prefix.
queue_ts() {
  if [ -n "${1:-}" ]; then date -u -d "@$1" +%Y%m%d-%H%M%S 2>/dev/null || date -u -r "$1" +%Y%m%d-%H%M%S; \
  else date -u +%Y%m%d-%H%M%S; fi
}

# queue_filename <type> <short_id> [ts] — {YYYYMMDD-HHmmss}-{type}-{short-id}.md
#
# The result must satisfy the ntfy listener's item-id regex ^[A-Za-z0-9._-]+$, because the whole
# filename is what a phone sends back on an Approve tap. Anything outside that set is replaced
# rather than passed through: a rejected id is a silent no-op at the listener, which looks exactly
# like a lost notification.
queue_filename() {
  local typ="$1" short="$2" ts="${3:-$(queue_ts)}"
  short="$(printf '%s' "$short" | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')"
  printf '%s-%s-%s.md' "$ts" "$typ" "$short"
}

# branch_slug <title> — lowercase, non-alphanumeric to hyphen, collapse, truncate 40, strip
# trailing hyphen. (poll-github-issues step 6.3)
branch_slug() {
  printf '%s' "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | sed -E 's/-+/-/g; s/^-//' \
    | cut -c1-40 \
    | sed -E 's/-+$//'
}

# extract_acceptance_criteria <body-file> — pull an "Acceptance Criteria" section, else any
# checkbox list, else a stated absence.
#
# Deliberately conservative. The poll skills ask the model to "extract from body if present,
# otherwise note 'No explicit acceptance criteria'" — a structured heading or a `- [ ]` list is
# mechanically extractable and needs no model; anything less structured is left to the drafting
# phase rather than guessed at here.
extract_acceptance_criteria() {
  local f="$1" out
  out="$(awk '
    tolower($0) ~ /^#+[[:space:]]*acceptance criteria/ { grab=1; next }
    grab && /^#+[[:space:]]/ { exit }
    grab { print }
  ' "$f" | sed -E '/^[[:space:]]*$/d')"
  if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  out="$(grep -E '^[[:space:]]*[-*][[:space:]]+\[[ xX]\]' "$f" 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  printf 'No explicit acceptance criteria found in the issue body.\n'
}

# write_ticket_item — write a ticket / ticket-investigation queue item, for a GitHub issue or a
# Jira ticket. Named arguments:
#   --path <file>            destination (required)
#   --type <t>               ticket | ticket-investigation
#   --source github|jira     which tracker this came from (default github)
#   --source-url --source-id --title --priority --created-at --project --ticket-key
#   --labels-file <file>     labels, one per line (github_labels / jira_labels)
#   --matched <slugs>        space-separated; emitted only for _unrouted items
#   --routing-method --routing-rationale
#   --kind-method --kind-rationale
#   --body-file <file>       raw issue body / Jira description
#   --state <s>              issue state for the Context block (default "Open"); Jira status
#   --components-file <f>    Jira components, one per line   (jira only)
#   --jira-issue-type <n>    the issue type NAME             (jira only)
#   --comments-file <f>      pre-rendered recent comments    (jira only)
#
# ONE FUNCTION, NOT TWO. A separate write_jira_ticket_item would be ~90% identical to this, and
# the header above records what happens to near-identical copies of this particular thing: the
# five poll skills each restated the filename convention and field list in prose and had ALREADY
# drifted. The tracker-specific parts are three frontmatter keys and three Context lines.
#
# Optional fields are OMITTED rather than written empty, matching the reference docs: a
# rationale is only meaningful for the tier that produced it, and an always-present empty key
# invites a reader to treat "" as a value.
write_ticket_item() {
  local path="" typ="ticket" src="github" url="" sid="" title="" prio="normal" created="" project=""
  local tkey="" f_labels="" matched="" rmethod="" rrat="" kmethod="" krat="" f_body="" state="Open"
  local f_comps="" jtype="" f_comments=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) path="$2"; shift 2 ;;            --type) typ="$2"; shift 2 ;;
      --source) src="$2"; shift 2 ;;
      --source-url) url="$2"; shift 2 ;;       --source-id) sid="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;          --priority) prio="$2"; shift 2 ;;
      --created-at) created="$2"; shift 2 ;;   --project) project="$2"; shift 2 ;;
      --ticket-key) tkey="$2"; shift 2 ;;      --labels-file) f_labels="$2"; shift 2 ;;
      --matched) matched="$2"; shift 2 ;;      --routing-method) rmethod="$2"; shift 2 ;;
      --routing-rationale) rrat="$2"; shift 2 ;; --kind-method) kmethod="$2"; shift 2 ;;
      --kind-rationale) krat="$2"; shift 2 ;;  --body-file) f_body="$2"; shift 2 ;;
      --state) state="$2"; shift 2 ;;
      --components-file) f_comps="$2"; shift 2 ;;
      --jira-issue-type) jtype="$2"; shift 2 ;;
      --comments-file) f_comments="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$path" ] || return 1

  local labels=() l
  if [ -n "$f_labels" ] && [ -f "$f_labels" ]; then
    # `|| [ -n "$l" ]` is required, not defensive: `read` returns non-zero on a final line with
    # no trailing newline, so without it the last (often only) label is silently discarded and the
    # item ships with github_labels: [] — a valid-looking value that quietly degrades Tier 2
    # routing and Tier 2 kind classification.
    while IFS= read -r l || [ -n "$l" ]; do [ -n "$l" ] && labels+=("$l"); done < "$f_labels"
  fi
  local comps=() c
  if [ -n "$f_comps" ] && [ -f "$f_comps" ]; then
    while IFS= read -r c || [ -n "$c" ]; do [ -n "$c" ] && comps+=("$c"); done < "$f_comps"
  fi
  local mlist=() m
  for m in $matched; do mlist+=("$m"); done

  {
    echo "---"
    echo "type: $typ"
    echo "source: $src"
    echo "source_url: \"$(yaml_escape "$url")\""
    echo "source_id: \"$(yaml_escape "$sid")\""
    echo "title: \"$(yaml_escape "$title")\""
    echo "priority: $prio"
    echo "created_at: \"$(yaml_escape "$created")\""
    echo "status: incoming"
    echo "project: \"$(yaml_escape "$project")\""
    echo "ticket_key: \"$(yaml_escape "$tkey")\""
    if [ "$src" = "jira" ]; then
      echo "jira_status: \"$(yaml_escape "$state")\""
      # jira_issue_type is the Tier 1 INPUT to references/ticket-kind.md, recorded so the approval
      # gate can audit the decision and not only its output.
      [ -n "$jtype" ] && echo "jira_issue_type: \"$(yaml_escape "$jtype")\""
      echo "jira_components: $(yaml_list "${comps[@]+"${comps[@]}"}")"
      echo "jira_labels: $(yaml_list "${labels[@]+"${labels[@]}"}")"
    else
      echo "github_labels: $(yaml_list "${labels[@]+"${labels[@]}"}")"
    fi
    [ -n "$rmethod" ] && echo "routing_method: \"$(yaml_escape "$rmethod")\""
    # routing_rationale exists ONLY for inferred/keyword routes — the tiers that made a judgment
    # call. That is what makes an auto-routed guess auditable at the approval gate.
    [ -n "$rrat" ]    && echo "routing_rationale: \"$(yaml_escape "$rrat")\""
    # ticket_kind_method is omitted for _unrouted items: the kind lists are per-project, so an
    # item with no slug cannot be classified yet (references/ticket-kind.md, "classified late").
    [ -n "$kmethod" ] && [ "$project" != "_unrouted" ] && echo "ticket_kind_method: \"$(yaml_escape "$kmethod")\""
    [ -n "$krat" ]    && [ "$project" != "_unrouted" ] && echo "ticket_kind_rationale: \"$(yaml_escape "$krat")\""
    [ "$project" = "_unrouted" ] && echo "matched_projects: $(yaml_list "${mlist[@]+"${mlist[@]}"}")"
    echo "---"
    echo
    echo "## Context"
    echo
    echo "**Ticket:** ${tkey} — ${title}"
    echo "**Status:** ${state}"
    [ "$src" = "jira" ] && [ -n "$jtype" ] && echo "**Type:** ${jtype}"
    echo "**Priority:** ${prio}"
    if [ "$src" = "jira" ]; then
      if [ ${#comps[@]} -gt 0 ]; then
        echo "**Components:** $(IFS=,; printf '%s' "${comps[*]}" | sed 's/,/, /g')"
      else
        echo "**Components:** (none)"
      fi
    fi
    if [ "$project" = "_unrouted" ]; then
      echo "**Project:** _unrouted (candidates: ${matched:-none})"
    else
      echo "**Project:** ${project}"
    fi
    if [ ${#labels[@]} -gt 0 ]; then
      echo "**Labels:** $(IFS=,; printf '%s' "${labels[*]}" | sed 's/,/, /g')"
    else
      echo "**Labels:** (none)"
    fi
    [ -n "$rmethod" ] && echo "**Routing:** ${rmethod}${rrat:+ — ${rrat}}"
    if [ "$typ" = "ticket-investigation" ]; then
      echo "**Deliverable:** findings document (no branch, no PR, no QA)"
    else
      echo "**Deliverable:** code change (branch → draft PR)"
    fi
    echo "**URL:** ${url}"
    echo
    echo "### Description"
    if [ -n "$f_body" ] && [ -s "$f_body" ]; then cat "$f_body"; else echo "_No description provided._"; fi
    echo
    echo "### Acceptance Criteria"
    [ -n "$f_body" ] && [ -f "$f_body" ] && extract_acceptance_criteria "$f_body" || echo "No explicit acceptance criteria found in the issue body."
    # Jira only, and only when there are any: poll-jira's item format includes a Recent Comments
    # section, and on a Jira ticket the real acceptance criteria have often ended up there.
    if [ -n "$f_comments" ] && [ -s "$f_comments" ]; then
      echo
      echo "### Recent Comments"
      cat "$f_comments"
    fi
  } > "$path"
}

# write_pr_item — write a pr-review queue item.
#
# Named arguments: --path --source-url --source-id --title --priority --created-at --project
#                  --pr-author --repo --pr-number --head --base --changed-files
#                  --labels-file --body-file
#
# Deliberately does NOT fetch the diff. skills/poll-github/SKILL.md has the poll run `gh pr view`
# and `gh pr diff` and generate a full structured review INLINE, which is the single most expensive
# thing a poll does. Here the collector only establishes that a PR needs review and records the
# metadata; the diff is read once, later, by the drafting phase that actually needs it.
write_pr_item() {
  local path="" url="" sid="" title="" prio="normal" created="" project=""
  local author="" repo="" num="" head="" base="" changed="" f_labels="" f_body=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) path="$2"; shift 2 ;;              --source-url) url="$2"; shift 2 ;;
      --source-id) sid="$2"; shift 2 ;;          --title) title="$2"; shift 2 ;;
      --priority) prio="$2"; shift 2 ;;          --created-at) created="$2"; shift 2 ;;
      --project) project="$2"; shift 2 ;;        --pr-author) author="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;              --pr-number) num="$2"; shift 2 ;;
      --head) head="$2"; shift 2 ;;              --base) base="$2"; shift 2 ;;
      --changed-files) changed="$2"; shift 2 ;;  --labels-file) f_labels="$2"; shift 2 ;;
      --body-file) f_body="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$path" ] || return 1
  local labels=() l
  if [ -n "$f_labels" ] && [ -f "$f_labels" ]; then
    while IFS= read -r l || [ -n "$l" ]; do [ -n "$l" ] && labels+=("$l"); done < "$f_labels"
  fi
  {
    echo "---"
    echo "type: pr-review"
    echo "source: github"
    echo "source_url: \"$(yaml_escape "$url")\""
    echo "source_id: \"$(yaml_escape "$sid")\""
    echo "title: \"$(yaml_escape "$title")\""
    echo "priority: $prio"
    echo "created_at: \"$(yaml_escape "$created")\""
    echo "status: incoming"
    echo "project: \"$(yaml_escape "$project")\""
    echo "pr_author: \"$(yaml_escape "$author")\""
    echo "repo: \"$(yaml_escape "$repo")\""
    echo "pr_number: ${num}"
    echo "github_labels: $(yaml_list "${labels[@]+"${labels[@]}"}")"
    echo "---"
    echo
    echo "## Context"
    echo
    echo "**PR:** #${num} in ${repo} by @${author}"
    echo "**Files changed:** ${changed}"
    echo "**Branch:** ${head} -> ${base}"
    echo "**Project:** ${project}"
    echo "**URL:** ${url}"
    echo
    echo "### Description"
    if [ -n "$f_body" ] && [ -s "$f_body" ]; then cat "$f_body"; else echo "_No description provided._"; fi
  } > "$path"
}

# write_doc_item — write a doc-review queue item for a Slite note.
#
# Shape comes from skills/poll-slite/SKILL.md step 3b. Note `source_id` is "slite:{doc_id}", NOT the
# bare id: CLAUDE.md gives that prefixed form as the one the spec -> design-doc -> ticket-plan
# prior-artifact lookups chain on, so an unprefixed id would break those joins while still looking
# perfectly valid in the queue.
#
# Named arguments:
#   --path --source-url --source-id --title --priority --created-at --project
#   --doc-id <id> --updated-at <iso> --author <name>
#   --labels-file <file>   the doc labels that matched, one per line
#   --label-source <s>     "tags" | "query" — how the label match was established
#   --matched <slugs>      space-separated; emitted only for _unrouted items
#   --body-file <file>     full document text
write_doc_item() {
  local path="" url="" sid="" title="" prio="normal" created="" project=""
  local doc_id="" updated="" author="" f_labels="" f_body="" label_source="" matched=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) path="$2"; shift 2 ;;            --source-url) url="$2"; shift 2 ;;
      --source-id) sid="$2"; shift 2 ;;        --title) title="$2"; shift 2 ;;
      --priority) prio="$2"; shift 2 ;;        --created-at) created="$2"; shift 2 ;;
      --project) project="$2"; shift 2 ;;      --doc-id) doc_id="$2"; shift 2 ;;
      --updated-at) updated="$2"; shift 2 ;;   --author) author="$2"; shift 2 ;;
      --labels-file) f_labels="$2"; shift 2 ;; --body-file) f_body="$2"; shift 2 ;;
      --label-source) label_source="$2"; shift 2 ;;
      --matched) matched="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$path" ] || return 1

  local labels=() l
  if [ -n "$f_labels" ] && [ -f "$f_labels" ]; then
    while IFS= read -r l || [ -n "$l" ]; do [ -n "$l" ] && labels+=("$l"); done < "$f_labels"
  fi

  {
    echo "---"
    echo "type: doc-review"
    echo "source: slite"
    echo "source_url: \"$(yaml_escape "$url")\""
    echo "source_id: \"$(yaml_escape "$sid")\""
    echo "title: \"$(yaml_escape "$title")\""
    echo "priority: $prio"
    echo "created_at: \"$(yaml_escape "$created")\""
    echo "status: incoming"
    echo "project: \"$(yaml_escape "$project")\""
    echo "doc_id: \"$(yaml_escape "$doc_id")\""
    echo "doc_labels: $(yaml_list "${labels[@]+"${labels[@]}"}")"
    # "query" means the Slite API exposed no tag field on this note, so the doc matched only
    # because the label was the search term — a weaker claim than a real tag comparison, and one
    # the approval gate should be able to see rather than infer.
    [ -n "$label_source" ] && echo "label_source: \"$(yaml_escape "$label_source")\""
    # Without this an _unrouted doc reaches review-queue with no candidate list, so the human is
    # asked to assign a project with nothing to choose from.
    if [ "$project" = "_unrouted" ]; then
      local dm=() d
      for d in $matched; do dm+=("$d"); done
      echo "matched_projects: $(yaml_list "${dm[@]+"${dm[@]}"}")"
    fi
    echo "---"
    echo
    echo "## Context"
    echo
    echo "**Document:** ${title}"
    echo "**URL:** ${url}"
    echo "**Project:** ${project}"
    echo "**Last updated:** ${updated:-unknown}"
    echo "**Author:** ${author:-unknown}"
    if [ ${#labels[@]} -gt 0 ]; then
      echo "**Labels:** $(IFS=,; printf '%s' "${labels[*]}" | sed 's/,/, /g')"
    else
      echo "**Labels:** (none)"
    fi
    echo
    echo "### Document Content"
    if [ -n "$f_body" ] && [ -s "$f_body" ]; then cat "$f_body"; else echo "_Document body could not be fetched._"; fi
  } > "$path"
}
