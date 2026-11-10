#!/bin/bash
# lib-gh-assign-rules.sh — which GitHub issue a `github-issues` / `implement-next` job may pick.
#
# The GitHub twin of lib-assign-rules.sh, sharing its config accessors and invariants: rules are
# ordered, the first rule with an eligible issue wins, `query` decides what is FETCHED and `require`
# is re-checked here against the fetched fields. Ticket text is only ever the left side of a
# comparison. Every pick must also be in one of the project's github.repos, whatever the query says.
#
# Read-only: search and reads via `gh api graphql`; gh-claim.sh does the writes.
#
# Requires lib-paths.sh (with_timeout), lib-jobs.sh (which sources lib-assign-rules.sh), lib-time.sh
# and lib-queue.sh; gh and jq at selection time. Callers set TMPD.

GR_RULE_KEYS="name query require ready_check claim on_fail"
GR_REQ_LISTS="labels_any labels_none milestones issue_types project_statuses"
GR_REQ_SCALARS="assignee min_age min_quiet no_open_blockers no_linked_pr has_acceptance_criteria min_body_chars"
GR_CLAIM_KEYS="assign project_status"
GR_ONFAIL_KEYS="unassign project_status"
GR_MAX_RESULTS="${GR_MAX_RESULTS:-30}"
GR_GH_TIMEOUT="${EA_POLL_CMD_TIMEOUT:-120}"

_gr_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# gr_board <slug> <idx> — prints "<owner>\t<number>\t<status field>" for the job's board, or nothing.
gr_board() {
  local p="projects.$1.job.$2.board" o n f
  o="$(_arc "$p.owner")"; n="$(_arc "$p.number")"; f="$(_arc "$p.status_field")"
  [ -n "$o$n" ] || return 0
  printf '%s\t%s\t%s\n' "$o" "$n" "${f:-Status}"
}

# gr_project_repos <slug> — the project's repos as lowercased owner/name, one per line.
gr_project_repos() {
  local owner r
  owner="$(_arc "projects.$1.github.owner")"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in */*) _gr_lower "$r" ;; *) _gr_lower "${owner}/${r}" ;; esac
    echo
  done < <(_arcl "projects.$1.github.repos")
}

# gr_assignee_mode <rule-prefix> — explicit require.assignee, else `empty` only when the query
# itself says `no:assignee`, else `me`. `any` is never inferred.
gr_assignee_mode() {
  local v q
  v="$(_arc "$1.require.assignee")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  q="$(_gr_lower "$(_arc "$1.query")")"
  if [[ "$q" =~ (^|[[:space:]])no:assignee($|[[:space:]]) ]]; then printf 'empty'; else printf 'me'; fi
}

# gr_validate <slug> <idx> — prints a reason and returns 1 if the job's rules must not be used.
gr_validate() {
  local slug="$1" idx="$2" n j p name names="" k v board="" bp
  jobs_cfg_load
  bp="projects.${slug}.job.${idx}.board"
  _ar_check_keys "$bp" "owner number status_field" "board" || return 1
  if [ -n "$(_arc "$bp.owner")$(_arc "$bp.number")" ]; then
    [[ "$(_arc "$bp.owner")" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { echo "board.owner '$(_arc "$bp.owner")' must be a GitHub user or org login"; return 1; }
    [[ "$(_arc "$bp.number")" =~ ^[1-9][0-9]*$ ]] || { echo "board.number '$(_arc "$bp.number")' must be a positive integer"; return 1; }
    board=1
  fi
  n="$(_arc "projects.${slug}.job.${idx}.rule_count")"
  [ "${n:-0}" -gt 0 ] 2>/dev/null || { echo "github-issues:implement-next needs at least one entry in rules"; return 1; }
  j=0
  while [ "$j" -lt "$n" ]; do
    p="$(ar_prefix "$slug" "$idx" "$j")"
    name="$(_arc "$p.name")"
    [[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "rules[${j}].name '${name}' must match ^[a-z0-9-]+\$"; return 1; }
    _ar_in "$name" "$names" && { echo "duplicate rule name '${name}'"; return 1; }
    names="$names $name"
    _ar_check_keys "$p" "$GR_RULE_KEYS" "rule ${name}" || return 1
    [ -n "$(_arc "$p.query")" ] || { echo "rule ${name}: query is required"; return 1; }

    _ar_check_keys "$p.require" "$GR_REQ_LISTS $GR_REQ_SCALARS" "rule ${name} require" || return 1
    for k in $GR_REQ_LISTS; do
      _ar_is_scalar "$p.require.$k" && { echo "rule ${name}: require.${k} must be a list"; return 1; }
    done
    for k in $GR_REQ_SCALARS; do
      _ar_is_list "$p.require.$k" && { echo "rule ${name}: require.${k} must be a single value"; return 1; }
    done
    v="$(_arc "$p.require.assignee")"
    [ -z "$v" ] || _ar_in "$v" "empty me any" || { echo "rule ${name}: require.assignee '${v}' must be empty, me or any"; return 1; }
    for k in min_age min_quiet; do
      v="$(_arc "$p.require.$k")"
      [ -z "$v" ] || [ -n "$(jobs_duration_seconds "$v")" ] || { echo "rule ${name}: require.${k} '${v}' must look like 30m, 2h or 1d"; return 1; }
    done
    for k in no_open_blockers no_linked_pr has_acceptance_criteria; do
      v="$(_arc "$p.require.$k")"
      _ar_bool "$v" || { echo "rule ${name}: require.${k} '${v}' must be true or false"; return 1; }
    done
    v="$(_arc "$p.require.min_body_chars")"
    [ -z "$v" ] || [[ "$v" =~ ^[0-9]+$ ]] || { echo "rule ${name}: require.min_body_chars '${v}' must be an integer"; return 1; }
    if [ -z "$board" ]; then
      [ -z "$(_arcl "$p.require.project_statuses")" ] || { echo "rule ${name}: require.project_statuses needs the job's board (owner, number)"; return 1; }
      for k in claim on_fail; do
        [ -z "$(_arc "$p.$k.project_status")" ] || { echo "rule ${name}: ${k}.project_status needs the job's board (owner, number)"; return 1; }
      done
    fi

    v="$(_arc "$p.ready_check")"
    _ar_bool "$v" || { echo "rule ${name}: ready_check '${v}' must be true or false"; return 1; }
    [ "$v" = true ] && { echo "rule ${name}: ready_check is not built yet; remove it or set it to false"; return 1; }

    _ar_check_keys "$p.claim" "$GR_CLAIM_KEYS" "rule ${name} claim" || return 1
    v="$(_arc "$p.claim.assign")"
    [ -z "$v" ] || _ar_in "$v" "self none" || { echo "rule ${name}: claim.assign '${v}' must be self or none"; return 1; }
    _ar_check_keys "$p.on_fail" "$GR_ONFAIL_KEYS" "rule ${name} on_fail" || return 1
    v="$(_arc "$p.on_fail.unassign")"
    _ar_bool "$v" || { echo "rule ${name}: on_fail.unassign '${v}' must be true or false"; return 1; }
    j=$((j+1))
  done
  return 0
}

# gr_graphql <out> <query> [gh -f/-F args...] — rc 0 only for a response with data and no errors.
gr_graphql() {
  local out="$1" q="$2"; shift 2
  with_timeout "$GR_GH_TIMEOUT" gh api graphql -f query="$q" "$@" > "$out" 2>"$TMPD/gh.err"
  jq -e '(.errors // []) == [] and .data != null' "$out" >/dev/null 2>&1
}
gr_graphql_error() { jq -r '[.errors[]?.message] | join("; ")' "$1" 2>/dev/null | head -c 300; }

# _gr_fields <slug> <idx> — the Issue selection set this job's rules need. Optional parts are
# included only when a rule uses them, so a GHES without (say) issue types still serves the rest.
_gr_fields() {
  local slug="$1" idx="$2" n j p types=0 linked=0 blockers=0 board
  n="$(_arc "projects.${slug}.job.${idx}.rule_count")"; j=0
  while [ "$j" -lt "${n:-0}" ]; do
    p="$(ar_prefix "$slug" "$idx" "$j")"
    [ -n "$(_arcl "$p.require.issue_types")" ] && types=1
    [ "$(_arc "$p.require.no_linked_pr")" = true ] && linked=1
    [ "$(_arc "$p.require.no_open_blockers")" = true ] && blockers=1
    j=$((j+1))
  done
  board="$(gr_board "$slug" "$idx")"
  printf '%s' 'id number title body url state createdAt updatedAt
    repository { nameWithOwner }
    author { login }
    assignees(first: 20) { totalCount nodes { login } }
    labels(first: 50) { nodes { name } }
    milestone { title }'
  [ "$types" = 1 ] && printf '%s' ' issueType { name }'
  [ -n "$board" ] && printf '%s' ' projectItems(first: 20) { nodes { project { number owner { ... on Organization { login } ... on User { login } } } status: fieldValueByName(name: $field) { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }'
  [ "$linked" = 1 ] && printf '%s' ' closedByPullRequestsReferences(first: 1, includeClosedPrs: false) { totalCount } linkedBranches(first: 1) { totalCount } xrefs: timelineItems(itemTypes: [CROSS_REFERENCED_EVENT], last: 100) { totalCount nodes { ... on CrossReferencedEvent { source { ... on PullRequest { state } } } } }'
  [ "$blockers" = 1 ] && printf '%s' ' blockedBy(first: 50) { totalCount nodes { state } }'
  return 0
}

# gr_search_query <slug> <rule-prefix> — the rule's query, restricted to open issues and, when it
# names no repo/org/user, to the project's repos (multiple repo: qualifiers are OR in search).
gr_search_query() {
  local q r
  q="$(_arc "$2.query")"
  if ! [[ " $(_gr_lower "$q")" =~ [[:space:]](repo|org|user): ]]; then
    while IFS= read -r r; do [ -n "$r" ] && q="$q repo:$r"; done < <(gr_project_repos "$1")
  fi
  printf '%s is:issue is:open' "$q"
}

# _gr_facts <issue-json> <board-owner> <board-number> — "name<TAB>value" lines; lists repeat the name.
_gr_facts() {
  jq -r --arg bo "$(_gr_lower "$2")" --arg bn "$3" '
    def l(n; v): "\(n)\t\(v)";
    l("repo"; .repository.nameWithOwner // "" | ascii_downcase),
    l("number"; .number // ""), l("state"; .state // ""),
    l("created"; .createdAt // ""), l("updated"; .updatedAt // ""),
    l("assignee_count"; .assignees.totalCount // 0),
    (.assignees.nodes[]?.login // empty | l("assignee"; ascii_downcase)),
    (.labels.nodes[]?.name // empty | l("label"; .)),
    l("milestone"; .milestone.title // ""),
    l("type"; .issueType.name // ""),
    l("board_status"; if $bn == "" then "" else
        ([.projectItems.nodes[]? | select((.project.number | tostring) == $bn and ((.project.owner.login // "") | ascii_downcase) == $bo)
          | .status.name // ""] | first // "") end),
    l("body_len"; (.body // "" | gsub("^\\s+|\\s+$"; "") | length)),
    l("has_ac"; (.body // "" | test("acceptance criteria"; "i")
                 or test("(^|\n)\\s*([-*#]+\\s*)?\\[[ xX]?\\]")
                 or test("(^|\n)\\s*AC\\s*[:-]"))),
    l("open_blockers"; if .blockedBy == null then "unknown"
        elif (.blockedBy.totalCount // 0) > (.blockedBy.nodes | length) then "unknown"
        else [.blockedBy.nodes[] | select(.state == "OPEN")] | length end),
    l("linked"; if .closedByPullRequestsReferences == null or .xrefs == null then "unknown"
        elif (.xrefs.totalCount // 0) > (.xrefs.nodes | length) then "unknown"
        else "\(.closedByPullRequestsReferences.totalCount) \(.linkedBranches.totalCount // 0) \([.xrefs.nodes[]? | select(.source.state? == "OPEN")] | length)" end)
  ' "$1"
}

# gr_eval <issue-json> <rule-prefix> <slug> <idx> — 0 if eligible; else prints the first failed
# predicate. Uses GR_MY_LOGIN for `assignee: me`.
gr_eval() {
  local file="$1" p="$2" slug="$3" idx="$4" facts v want now ts age x hit bo bn a b c
  IFS="	" read -r bo bn _ <<< "$(gr_board "$slug" "$idx")"
  facts="$(_gr_facts "$file" "${bo:-}" "${bn:-}")" || { echo "unreadable issue JSON"; return 1; }
  now="$(jobs_now)"

  v="$(_ar_fact "$facts" repo)"
  _ar_member "$v" "$(gr_project_repos "$slug")" 0 || { echo "repo: ${v} is not one of the project's github.repos"; return 1; }
  [ "$(_ar_fact "$facts" state)" = OPEN ] || { echo "state: not open"; return 1; }

  case "$(gr_assignee_mode "$p")" in
    empty) [ "$(_ar_fact "$facts" assignee_count)" = 0 ] || { echo "assignee: already assigned"; return 1; } ;;
    me)    [ -n "${GR_MY_LOGIN:-}" ] && _ar_member "$(_gr_lower "$GR_MY_LOGIN")" "$(_ar_factl "$facts" assignee)" 0 \
             || { echo "assignee: not assigned to me"; return 1; } ;;
  esac

  for x in "issue_types type" "milestones milestone" "project_statuses board_status"; do
    want="$(_arcl "$p.require.${x% *}")"
    [ -z "$want" ] && continue
    v="$(_ar_fact "$facts" "${x#* }")"
    [ -n "$v" ] || { echo "${x% *}: none set"; return 1; }
    _ar_member "$v" "$want" 1 || { echo "${x% *}: '${v}' not in list"; return 1; }
  done

  want="$(_arcl "$p.require.labels_any")"
  if [ -n "$want" ]; then
    hit=0
    while IFS= read -r x; do [ -n "$x" ] && _ar_member "$x" "$want" 1 && hit=1; done < <(_ar_factl "$facts" label)
    [ "$hit" = 1 ] || { echo "labels_any: no matching label"; return 1; }
  fi
  want="$(_arcl "$p.require.labels_none")"
  if [ -n "$want" ]; then
    while IFS= read -r x; do
      [ -n "$x" ] && _ar_member "$x" "$want" 1 && { echo "labels_none: has label '${x}'"; return 1; }
    done < <(_ar_factl "$facts" label)
  fi

  for x in "min_age created" "min_quiet updated"; do
    v="$(_arc "$p.require.${x% *}")"
    [ -z "$v" ] && continue
    ts="$(epoch_of_iso "$(_ar_fact "$facts" "${x#* }")")"
    [ -n "$ts" ] || { echo "${x% *}: unparseable ${x#* } timestamp"; return 1; }
    age=$(( now - ts ))
    [ "$age" -ge "$(jobs_duration_seconds "$v")" ] || { echo "${x% *}: ${x#* } only ${age}s ago (< ${v})"; return 1; }
  done

  v="$(_arc "$p.require.min_body_chars")"
  if [ -n "$v" ]; then
    x="$(_ar_fact "$facts" body_len)"
    [ "${x:-0}" -ge "$v" ] || { echo "min_body_chars: ${x:-0} < ${v}"; return 1; }
  fi
  if [ "$(_arc "$p.require.has_acceptance_criteria")" = true ]; then
    [ "$(_ar_fact "$facts" has_ac)" = true ] || { echo "has_acceptance_criteria: none found in body"; return 1; }
  fi
  if [ "$(_arc "$p.require.no_open_blockers")" = true ]; then
    x="$(_ar_fact "$facts" open_blockers)"
    [ "$x" != unknown ] || { echo "no_open_blockers: blockers unavailable"; return 1; }
    [ "$x" = 0 ] || { echo "no_open_blockers: ${x} open blocker(s)"; return 1; }
  fi
  if [ "$(_arc "$p.require.no_linked_pr")" = true ]; then
    x="$(_ar_fact "$facts" linked)"
    [ "$x" != unknown ] || { echo "no_linked_pr: linked PRs unavailable"; return 1; }
    read -r a b c <<< "$x"
    [ "$x" = "0 0 0" ] || { echo "no_linked_pr: ${a} closing PR(s), ${b} branch(es), ${c} open referencing PR(s)"; return 1; }
  fi
  return 0
}

# gr_init — rc 1 with GR_ERR set when gh/jq are missing. Call directly, not in $(...).
gr_init() {
  command -v jq >/dev/null 2>&1 || { GR_ERR="jq not found"; return 1; }
  command -v gh >/dev/null 2>&1 || { GR_ERR="gh not found"; return 1; }
}

# gr_my_login — the gh token owner's login, cached in state/github-login.
gr_my_login() {
  local f="${EA_AGENT_DIR}/state/github-login" l
  if [ -s "$f" ]; then cat "$f"; return 0; fi
  l="$(with_timeout "$GR_GH_TIMEOUT" gh api user --jq .login 2>/dev/null)"
  [[ "$l" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
  mkdir -p "$(dirname "$f")"
  printf '%s' "$l" > "$f"
  printf '%s' "$l"
}

# _gr_kind_skip <issue-json> <slug> — rc 1 with a reason when the kind ladder makes this an
# investigation, or when only a Form B judgment could tell (unattended picks never guess).
_gr_kind_skip() {
  local out
  command -v ticket_kind_classify >/dev/null 2>&1 || return 0
  jq -r '.labels.nodes[]?.name // empty' "$1" > "$TMPD/kind.labels"
  _arcl "projects.$2.investigation.github_labels"  > "$TMPD/kind.ghl"
  _arcl "projects.$2.investigation.title_keywords" > "$TMPD/kind.kw"
  out="$(ticket_kind_classify --tracker github --title "$(jq -r '.title // ""' "$1")" \
          --labels-file "$TMPD/kind.labels" --github-labels-file "$TMPD/kind.ghl" --title-keywords-file "$TMPD/kind.kw")"
  if [ "$(printf '%s' "$out" | cut -f1)" = ticket-investigation ]; then
    echo "investigation kind ($(printf '%s' "$out" | cut -f3)); implement-next only implements"; return 1
  fi
  if [ "$(printf '%s' "$out" | cut -f4)" = 1 ]; then
    echo "title may be an investigation (leading '$(printf '%s' "$out" | cut -f5)'); queue it with add-ticket --implement"; return 1
  fi
}

# gr_select <slug> <idx> — prints "<rule>\t<owner/repo#N>" (rc 0), nothing (rc 1) when none is
# eligible, or a reason (rc 2) on error. A failed search aborts rather than falling through.
# AR_TRACE=1 logs every verdict to stderr; AR_EVAL_ALL=1 keeps evaluating after the pick.
gr_select() {
  local slug="$1" idx="$2" n j p name q count k sid pick="" reason need_me=0 hit fields board bo bn bf
  local -a vars
  jobs_cfg_load
  n="$(_arc "projects.${slug}.job.${idx}.rule_count")"
  j=0
  while [ "$j" -lt "${n:-0}" ]; do
    [ "$(gr_assignee_mode "$(ar_prefix "$slug" "$idx" "$j")")" = me ] && need_me=1
    j=$((j+1))
  done
  if [ "$need_me" = 1 ] && [ -z "${GR_MY_LOGIN:-}" ]; then
    GR_MY_LOGIN="$(gr_my_login)" || { echo "could not resolve own GitHub login (gh api user)"; return 2; }
  fi
  fields="$(_gr_fields "$slug" "$idx")"
  board="$(gr_board "$slug" "$idx")"
  IFS="	" read -r bo bn bf <<< "$board"

  j=0
  while [ "$j" -lt "${n:-0}" ]; do
    p="$(ar_prefix "$slug" "$idx" "$j")"
    name="$(_arc "$p.name")"
    q="$(gr_search_query "$slug" "$p")"
    vars=(-f "q=$q" -F "n=$GR_MAX_RESULTS")
    if [ -n "$board" ]; then
      vars+=(-f "field=$bf")
      gr_graphql "$TMPD/rule.json" "query(\$q: String!, \$n: Int!, \$field: String!) { search(query: \$q, type: ISSUE, first: \$n) { nodes { ... on Issue { $fields } } } }" "${vars[@]}" \
        || { echo "rule ${name}: search failed: $(gr_graphql_error "$TMPD/rule.json")"; return 2; }
    else
      gr_graphql "$TMPD/rule.json" "query(\$q: String!, \$n: Int!) { search(query: \$q, type: ISSUE, first: \$n) { nodes { ... on Issue { $fields } } } }" "${vars[@]}" \
        || { echo "rule ${name}: search failed: $(gr_graphql_error "$TMPD/rule.json")"; return 2; }
    fi
    count="$(jq -r '.data.search.nodes | length' "$TMPD/rule.json" 2>/dev/null)"
    [[ "$count" =~ ^[0-9]+$ ]] || { echo "rule ${name}: unrecognised search response"; return 2; }
    _ar_trace "rule ${name}: ${count} fetched"
    k=0
    while [ "$k" -lt "$count" ]; do
      jq ".data.search.nodes[$k]" "$TMPD/rule.json" > "$TMPD/issue.json"
      k=$((k+1))
      sid="$(jq -r '"\(.repository.nameWithOwner // "")#\(.number // "")"' "$TMPD/issue.json")"
      [[ "$sid" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+#[0-9]+$ ]] || { _ar_trace "  ?  skip  not an issue"; continue; }
      hit="$(queue_lookup ticket "$sid")"
      if [ -n "$hit" ]; then
        _ar_trace "  ${sid}  skip  already queued (${hit%%	*})"
        continue
      fi
      if reason="$(gr_eval "$TMPD/issue.json" "$p" "$slug" "$idx")" && reason="$(_gr_kind_skip "$TMPD/issue.json" "$slug")"; then
        if [ -z "$pick" ]; then
          pick="$(printf '%s\t%s' "$name" "$sid")"
          _ar_trace "  ${sid}  PICK"
          [ "${AR_EVAL_ALL:-0}" = 1 ] || { printf '%s\n' "$pick"; return 0; }
        else
          _ar_trace "  ${sid}  eligible"
        fi
      else
        _ar_trace "  ${sid}  skip  ${reason}"
      fi
    done
    j=$((j+1))
  done
  [ -n "$pick" ] || return 1
  printf '%s\n' "$pick"
}

# gr_issue_fetch <out> <owner/repo> <number> — the issue the queue item and the trust check are
# both built from (one fetch, so the model reads exactly the text that was checked). Includes the
# edit history of every field written into the item: body (userContentEdits), title (renames) and
# labels.
gr_issue_fetch() {
  local out="$1" repo="$2" num="$3"
  gr_graphql "$out" 'query($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) { issue(number: $n) {
      id number title body url state repository { nameWithOwner } author { login }
      labels(first: 50) { nodes { name } }
      userContentEdits(first: 100) { totalCount nodes { editor { login } } }
      edits: timelineItems(itemTypes: [RENAMED_TITLE_EVENT, LABELED_EVENT, UNLABELED_EVENT], first: 100) {
        totalCount nodes { __typename ... on RenamedTitleEvent { actor { login } } ... on LabeledEvent { actor { login } } ... on UnlabeledEvent { actor { login } } } }
    } } }' -f "o=${repo%%/*}" -f "r=${repo#*/}" -F "n=$num"
}

# gr_untrusted_reason <issue-json (gr_issue_fetch)> <trusted-logins newline list> — empty when the
# author and every editor of the title, body and labels is trusted. Logins only, never names.
gr_untrusted_reason() {
  [ -n "$2" ] || { echo "no trusted_authors configured"; return 0; }
  jq -r --arg t "$2" '
    ($t | ascii_downcase | split("\n") | map(select(. != ""))) as $ok
    | .data.repository.issue as $i
    | def trusted(l): (l // "" | ascii_downcase) as $l | $l != "" and ($ok | index($l)) != null;
      if (trusted($i.author.login) | not) then "created by \($i.author.login // "(deleted user)"), not a trusted author"
      elif ($i.userContentEdits.totalCount // 0) > ($i.userContentEdits.nodes | length) then "edit history truncated; cannot verify edits"
      elif ($i.edits.totalCount // 0) > ($i.edits.nodes | length) then "edit history truncated; cannot verify edits"
      else [($i.userContentEdits.nodes[]? | .editor.login), ($i.edits.nodes[]? | .actor.login)
            | select(trusted(.) | not)] as $bad
           | if ($bad | length) == 0 then empty
             else "edited by \($bad[0] // "(deleted user)"), not a trusted author" end
      end' "$1"
}
