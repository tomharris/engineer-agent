#!/bin/bash
# lib-assign-rules.sh — which Jira ticket a `jira` / `implement-next` job may pick, and why.
#
# A job's `rules` are ordered; the first rule with an eligible ticket wins, and within a rule the
# JQL's ORDER BY decides. JQL decides what is FETCHED; `require` is re-checked here against the
# fetched fields, because a query is easy to write broader than intended and these predicates are
# testable offline. Ticket text is only ever the left side of a comparison.
#
# Read-only: this library searches and reads, it never assigns or transitions (jira-claim.sh does).
#
# Requires lib-paths.sh, lib-jobs.sh (jobs_cfg_load, jobs_duration_seconds, jobs_now), lib-time.sh,
# lib-queue.sh and lib-jira-api.sh; jq and curl at selection time.

AR_RULE_KEYS="name jql require ready_check claim on_fail"
AR_REQ_LISTS="issue_types priorities statuses components_any labels_any labels_none"
AR_REQ_SCALARS="assignee max_story_points min_age min_quiet no_open_blockers no_linked_pr has_acceptance_criteria min_description_chars"
AR_CLAIM_KEYS="assign transition"
AR_ONFAIL_KEYS="unassign transition"
AR_MAX_RESULTS="${AR_MAX_RESULTS:-50}"

# Raw accessors: unlike _jcfg these keep '|' (valid in JQL).
_arc()  { printf '%s\n' "$EA_JOBS_CFG" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }
_arcl() { printf '%s\n' "$EA_JOBS_CFG" | awk -v p="$1[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}'; }
_ar_is_list()   { printf '%s\n' "$EA_JOBS_CFG" | grep -qF -e "$1[]=" -e "$1[]#empty"; }
_ar_is_scalar() { printf '%s\n' "$EA_JOBS_CFG" | awk -v p="$1=" 'index($0,p)==1 {f=1} END {exit !f}'; }

# _ar_children <path> — distinct immediate child keys present under <path>.
_ar_children() {
  printf '%s\n' "$EA_JOBS_CFG" | awk -v p="$1." '
    index($0, p) == 1 {
      r = substr($0, length(p) + 1)
      sub(/(\[\]=.*|\[\]#empty$|\{\}$|=.*|\[[0-9]+\].*|\..*)$/, "", r)
      if (r != "" && !(r in s)) { s[r] = 1; print r }
    }'
}

_ar_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

ar_prefix() { printf 'projects.%s.job.%s.rule.%s' "$1" "$2" "$3"; }

# ar_rule_prefix_by_name <slug> <idx> <name> — the rule's config prefix; rc 1 if no such rule.
ar_rule_prefix_by_name() {
  local n j p
  jobs_cfg_load
  n="$(_arc "projects.$1.job.$2.rule_count")"; j=0
  while [ "$j" -lt "${n:-0}" ]; do
    p="$(ar_prefix "$1" "$2" "$j")"
    [ "$(_arc "$p.name")" = "$3" ] && { printf '%s' "$p"; return 0; }
    j=$((j+1))
  done
  return 1
}

# ar_assignee_mode <rule-prefix> — explicit require.assignee, else `empty` only when the JQL itself
# says `assignee is EMPTY`, else `me`. `any` is never inferred, so a rule cannot take a ticket
# someone else holds by accident.
ar_assignee_mode() {
  local v jql
  v="$(_arc "$1.require.assignee")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  jql="$(_arc "$1.jql" | tr '[:upper:]' '[:lower:]')"
  if [[ "$jql" =~ (^|[^a-z_])assignee[[:space:]]+is[[:space:]]+empty($|[^a-z_]) ]]; then printf 'empty'
  else printf 'me'; fi
}

_ar_check_keys() {
  local path="$1" allowed="$2" what="$3" k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    _ar_in "$k" "$allowed" || { echo "${what}: unknown key '${k}' (allowed: ${allowed})"; return 1; }
  done < <(_ar_children "$path")
}

_ar_bool() { [ -z "$1" ] || [ "$1" = true ] || [ "$1" = false ]; }

# ar_validate <slug> <idx> — prints a reason and returns 1 if the job's rules must not be used.
ar_validate() {
  local slug="$1" idx="$2" n j p name names="" k v sp
  jobs_cfg_load
  n="$(_arc "projects.${slug}.job.${idx}.rule_count")"
  [ "${n:-0}" -gt 0 ] 2>/dev/null || { echo "jira:implement-next needs at least one entry in rules"; return 1; }
  sp="$(_arc agent.jira.story_points_field)"
  j=0
  while [ "$j" -lt "$n" ]; do
    p="$(ar_prefix "$slug" "$idx" "$j")"
    name="$(_arc "$p.name")"
    [[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "rules[${j}].name '${name}' must match ^[a-z0-9-]+\$"; return 1; }
    _ar_in "$name" "$names" && { echo "duplicate rule name '${name}'"; return 1; }
    names="$names $name"
    _ar_check_keys "$p" "$AR_RULE_KEYS" "rule ${name}" || return 1
    [ -n "$(_arc "$p.jql")" ] || { echo "rule ${name}: jql is required"; return 1; }

    _ar_check_keys "$p.require" "$AR_REQ_LISTS $AR_REQ_SCALARS" "rule ${name} require" || return 1
    for k in $AR_REQ_LISTS; do
      _ar_is_scalar "$p.require.$k" && { echo "rule ${name}: require.${k} must be a list"; return 1; }
    done
    for k in $AR_REQ_SCALARS; do
      _ar_is_list "$p.require.$k" && { echo "rule ${name}: require.${k} must be a single value"; return 1; }
    done
    v="$(_arc "$p.require.assignee")"
    [ -z "$v" ] || _ar_in "$v" "empty me any" || { echo "rule ${name}: require.assignee '${v}' must be empty, me or any"; return 1; }
    v="$(_arc "$p.require.max_story_points")"
    if [ -n "$v" ]; then
      [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "rule ${name}: require.max_story_points '${v}' must be a number"; return 1; }
      [ -n "$sp" ] || { echo "rule ${name}: require.max_story_points needs agent.jira.story_points_field (e.g. customfield_10016)"; return 1; }
    fi
    for k in min_age min_quiet; do
      v="$(_arc "$p.require.$k")"
      [ -z "$v" ] || [ -n "$(jobs_duration_seconds "$v")" ] || { echo "rule ${name}: require.${k} '${v}' must look like 30m, 2h or 1d"; return 1; }
    done
    for k in no_open_blockers no_linked_pr has_acceptance_criteria; do
      v="$(_arc "$p.require.$k")"
      _ar_bool "$v" || { echo "rule ${name}: require.${k} '${v}' must be true or false"; return 1; }
    done
    v="$(_arc "$p.require.min_description_chars")"
    [ -z "$v" ] || [[ "$v" =~ ^[0-9]+$ ]] || { echo "rule ${name}: require.min_description_chars '${v}' must be an integer"; return 1; }

    v="$(_arc "$p.ready_check")"
    _ar_bool "$v" || { echo "rule ${name}: ready_check '${v}' must be true or false"; return 1; }
    [ "$v" = true ] && { echo "rule ${name}: ready_check is not built yet; remove it or set it to false"; return 1; }

    _ar_check_keys "$p.claim" "$AR_CLAIM_KEYS" "rule ${name} claim" || return 1
    v="$(_arc "$p.claim.assign")"
    [ -z "$v" ] || _ar_in "$v" "self none" || { echo "rule ${name}: claim.assign '${v}' must be self or none"; return 1; }
    _ar_check_keys "$p.on_fail" "$AR_ONFAIL_KEYS" "rule ${name} on_fail" || return 1
    v="$(_arc "$p.on_fail.unassign")"
    _ar_bool "$v" || { echo "rule ${name}: on_fail.unassign '${v}' must be true or false"; return 1; }
    j=$((j+1))
  done
  return 0
}

# ar_fields_json — the /search fields every predicate needs.
ar_fields_json() {
  local sp; sp="$(_arc agent.jira.story_points_field)"
  jq -nc --arg sp "$sp" '["summary","description","issuetype","components","labels","status","priority","created","updated","assignee","issuelinks"] + (if $sp == "" then [] else [$sp] end)'
}

# _ar_facts <issue-json-file> — one "name<TAB>value" line per fact; list facts repeat the name.
_ar_facts() {
  jq -r --arg sp "$(_arc agent.jira.story_points_field)" '
    def l(n; v): "\(n)\t\(v)";
    .fields as $f
    | l("id"; .id // ""), l("key"; .key // ""),
      l("assignee"; $f.assignee.accountId // ""),
      l("type"; $f.issuetype.name // ""), l("priority"; $f.priority.name // ""),
      l("status"; $f.status.name // ""),
      l("created"; $f.created // ""), l("updated"; $f.updated // ""),
      l("sp"; if $sp == "" then "" else ($f[$sp] // "" | tostring) end),
      ($f.components[]?.name // empty | l("component"; .)),
      ($f.labels[]? // empty | l("label"; .)),
      l("desc_len"; ($f.description // "" | gsub("^\\s+|\\s+$"; "") | length)),
      l("has_ac"; ($f.description // "" | test("acceptance criteria"; "i")
                   or test("(^|\n)\\s*([-*#]+\\s*)?\\[[ xX]?\\]")
                   or test("(^|\n)\\s*AC\\s*[:-]"))),
      l("open_blockers"; [$f.issuelinks[]?
          | select(((.type.inward // "") | ascii_downcase) == "is blocked by" and .inwardIssue != null)
          | select((.inwardIssue.fields.status.statusCategory.key // "") != "done")] | length)
  ' "$1"
}
_ar_fact()  { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k {sub(/^[^\t]*\t/,""); print; exit}'; }
_ar_factl() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k {sub(/^[^\t]*\t/,""); print}'; }

# _ar_member <needle> <list> <ci> — newline list membership; ci=1 compares case-insensitively.
_ar_member() {
  local needle="$1" list="$2" x
  [ "$3" = 1 ] && { needle="$(printf '%s' "$needle" | tr '[:upper:]' '[:lower:]')"; list="$(printf '%s' "$list" | tr '[:upper:]' '[:lower:]')"; }
  while IFS= read -r x; do [ -n "$x" ] && [ "$x" = "$needle" ] && return 0; done <<< "$list"
  return 1
}

# _ar_linked_dev <issue-id> — prints "<prs> <branches>" from the dev panel, or nothing if unavailable.
_ar_linked_dev() {
  local code
  code="$(jira_site_api "$TMPD/dev.json" GET "/rest/dev-status/latest/issue/summary?issueId=$1")"
  [ "$code" = 200 ] || return 0
  jq -r '"\(.summary.pullrequest.overall.count // 0) \(.summary.branch.overall.count // 0)"' "$TMPD/dev.json" 2>/dev/null
}

# ar_eval <issue-json-file> <rule-prefix> — 0 if eligible; else prints the first failed predicate.
# Uses AR_MY_ACCOUNT_ID for `assignee: me`. Cheap predicates first; the dev-panel call is last.
ar_eval() {
  local file="$1" p="$2" facts v want now ts age sp x hit dev
  facts="$(_ar_facts "$file")" || { echo "unreadable issue JSON"; return 1; }
  now="$(jobs_now)"

  v="$(_ar_fact "$facts" assignee)"
  case "$(ar_assignee_mode "$p")" in
    empty) [ -z "$v" ] || { echo "assignee: already assigned"; return 1; } ;;
    me)    [ -n "${AR_MY_ACCOUNT_ID:-}" ] && [ "$v" = "$AR_MY_ACCOUNT_ID" ] || { echo "assignee: not assigned to me"; return 1; } ;;
  esac

  for x in "issue_types type" "priorities priority" "statuses status"; do
    want="$(_arcl "$p.require.${x% *}")"
    [ -z "$want" ] && continue
    v="$(_ar_fact "$facts" "${x#* }")"
    _ar_member "$v" "$want" 1 || { echo "${x% *}: '${v}' not in list"; return 1; }
  done

  want="$(_arcl "$p.require.components_any")"
  if [ -n "$want" ]; then
    hit=0
    while IFS= read -r x; do [ -n "$x" ] && _ar_member "$x" "$want" 1 && hit=1; done < <(_ar_factl "$facts" component)
    [ "$hit" = 1 ] || { echo "components_any: no matching component"; return 1; }
  fi
  want="$(_arcl "$p.require.labels_any")"
  if [ -n "$want" ]; then
    hit=0
    while IFS= read -r x; do [ -n "$x" ] && _ar_member "$x" "$want" 0 && hit=1; done < <(_ar_factl "$facts" label)
    [ "$hit" = 1 ] || { echo "labels_any: no matching label"; return 1; }
  fi
  want="$(_arcl "$p.require.labels_none")"
  if [ -n "$want" ]; then
    while IFS= read -r x; do
      [ -n "$x" ] && _ar_member "$x" "$want" 0 && { echo "labels_none: has label '${x}'"; return 1; }
    done < <(_ar_factl "$facts" label)
  fi

  v="$(_arc "$p.require.max_story_points")"
  if [ -n "$v" ]; then
    sp="$(_ar_fact "$facts" sp)"
    [[ "$sp" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "max_story_points: no estimate"; return 1; }
    awk -v a="$sp" -v b="$v" 'BEGIN { exit !(a + 0 <= b + 0) }' || { echo "max_story_points: ${sp} > ${v}"; return 1; }
  fi

  for x in "min_age created" "min_quiet updated"; do
    v="$(_arc "$p.require.${x% *}")"
    [ -z "$v" ] && continue
    ts="$(epoch_of_iso "$(_ar_fact "$facts" "${x#* }")")"
    [ -n "$ts" ] || { echo "${x% *}: unparseable ${x#* } timestamp"; return 1; }
    age=$(( now - ts ))
    [ "$age" -ge "$(jobs_duration_seconds "$v")" ] || { echo "${x% *}: ${x#* } only ${age}s ago (< ${v})"; return 1; }
  done

  v="$(_arc "$p.require.min_description_chars")"
  if [ -n "$v" ]; then
    x="$(_ar_fact "$facts" desc_len)"
    [ "${x:-0}" -ge "$v" ] || { echo "min_description_chars: ${x:-0} < ${v}"; return 1; }
  fi
  if [ "$(_arc "$p.require.has_acceptance_criteria")" = true ]; then
    [ "$(_ar_fact "$facts" has_ac)" = true ] || { echo "has_acceptance_criteria: none found in description"; return 1; }
  fi
  if [ "$(_arc "$p.require.no_open_blockers")" = true ]; then
    x="$(_ar_fact "$facts" open_blockers)"
    [ "${x:-0}" = 0 ] || { echo "no_open_blockers: ${x} unresolved blocker(s)"; return 1; }
  fi
  if [ "$(_arc "$p.require.no_linked_pr")" = true ]; then
    dev="$(_ar_linked_dev "$(_ar_fact "$facts" id)")"
    [ -n "$dev" ] || { echo "no_linked_pr: dev panel unavailable"; return 1; }
    [ "$dev" = "0 0" ] || { echo "no_linked_pr: ${dev% *} PR(s), ${dev#* } branch(es) linked"; return 1; }
  fi
  return 0
}

# ar_jira_init — resolve site/email/token from config into JIRA_*. Sets AR_ERR and returns 1 on
# failure; call it directly, not in $(...), or the globals are lost with the subshell.
ar_jira_init() {
  jobs_cfg_load
  command -v jq   >/dev/null 2>&1 || { AR_ERR="jq not found"; return 1; }
  command -v curl >/dev/null 2>&1 || { AR_ERR="curl not found"; return 1; }
  JIRA_SITE="$(_arc agent.jira.site)"; JIRA_EMAIL="$(_arc agent.jira.email)"
  JIRA_API_BASE="$(_arc agent.jira.api_base)"; JIRA_API_BASE="${JIRA_API_BASE:-/rest/api/2}"
  [ -n "$JIRA_SITE" ]  || { AR_ERR="agent.jira.site is not set"; return 1; }
  [ -n "$JIRA_EMAIL" ] || { AR_ERR="agent.jira.email is not set"; return 1; }
  JIRA_SITE="${JIRA_SITE#https://}"; JIRA_SITE="${JIRA_SITE#http://}"; JIRA_SITE="${JIRA_SITE%/}"
  JIRA_TOKEN="$(ea_secret_resolve "$(_arc agent.jira.api_token_env)" "$(_arc agent.jira.api_token_file)" \
                                  "$(ea_secret_service jira)" "$JIRA_EMAIL")"
  [ -n "$JIRA_TOKEN" ] || { AR_ERR="no Jira API token (checked env/file/keychain)"; return 1; }
}

# ar_my_account_id — the token owner's accountId, cached per email in state/jira-account-id.
ar_my_account_id() {
  local f="${EA_AGENT_DIR}/state/jira-account-id" id code
  if [ -f "$f" ]; then
    id="$(awk -F'\t' -v e="$JIRA_EMAIL" '$1==e {print $2; exit}' "$f")"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  fi
  code="$(jira_api "$TMPD/myself.json" GET "/myself")"
  [ "$code" = 200 ] || return 1
  id="$(jq -r '.accountId // empty' "$TMPD/myself.json")"
  [ -n "$id" ] || return 1
  mkdir -p "$(dirname "$f")"
  printf '%s\t%s\n' "$JIRA_EMAIL" "$id" > "$f"
  printf '%s' "$id"
}

_ar_trace() { [ "${AR_TRACE:-0}" = 1 ] && printf '%s\n' "$*" >&2; return 0; }

# ar_select <slug> <idx> — prints "<rule>\t<key>\t<issue-id>" for the ticket to pick (rc 0), nothing
# (rc 1) when none is eligible, or a reason (rc 2) on error. A failed search aborts rather than
# falling through: skipping a higher-priority rule on an outage would pick the wrong ticket.
# AR_TRACE=1 logs every verdict to stderr; AR_EVAL_ALL=1 keeps evaluating after the pick.
ar_select() {
  local slug="$1" idx="$2" n j p name jql code count k key id pick="" reason need_me=0 hit
  jobs_cfg_load
  n="$(_arc "projects.${slug}.job.${idx}.rule_count")"
  j=0
  while [ "$j" -lt "${n:-0}" ]; do
    [ "$(ar_assignee_mode "$(ar_prefix "$slug" "$idx" "$j")")" = me ] && need_me=1
    j=$((j+1))
  done
  if [ "$need_me" = 1 ] && [ -z "${AR_MY_ACCOUNT_ID:-}" ]; then
    AR_MY_ACCOUNT_ID="$(ar_my_account_id)" || { echo "could not resolve own Jira accountId (/myself)"; return 2; }
  fi

  j=0
  while [ "$j" -lt "${n:-0}" ]; do
    p="$(ar_prefix "$slug" "$idx" "$j")"
    name="$(_arc "$p.name")"; jql="$(_arc "$p.jql")"
    code="$(jira_search "$TMPD/rule.json" "$jql" "$AR_MAX_RESULTS" "$(ar_fields_json)")"
    [ "$code" = 200 ] || { echo "rule ${name}: search failed (HTTP ${code})"; return 2; }
    count="$(jq -r '.issues | length' "$TMPD/rule.json" 2>/dev/null)"
    [[ "$count" =~ ^[0-9]+$ ]] || { echo "rule ${name}: unrecognised search response"; return 2; }
    _ar_trace "rule ${name}: ${count} fetched"
    k=0
    while [ "$k" -lt "$count" ]; do
      jq ".issues[$k]" "$TMPD/rule.json" > "$TMPD/issue.json"
      key="$(jq -r '.key // ""' "$TMPD/issue.json")"; id="$(jq -r '.id // ""' "$TMPD/issue.json")"
      k=$((k+1))
      hit="$(queue_lookup ticket "$key")"
      if [ -n "$hit" ]; then
        _ar_trace "  ${key}  skip  already queued (${hit%%	*})"
        continue
      fi
      if reason="$(ar_eval "$TMPD/issue.json" "$p")"; then
        if [ -z "$pick" ]; then
          pick="$(printf '%s\t%s\t%s' "$name" "$key" "$id")"
          _ar_trace "  ${key}  PICK"
          [ "${AR_EVAL_ALL:-0}" = 1 ] || { printf '%s\n' "$pick"; return 0; }
        else
          _ar_trace "  ${key}  eligible"
        fi
      else
        _ar_trace "  ${key}  skip  ${reason}"
      fi
    done
    j=$((j+1))
  done
  [ -n "$pick" ] || return 1
  printf '%s\n' "$pick"
}
