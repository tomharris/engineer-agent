#!/bin/bash
# lib-jira-api.sh — Jira Cloud REST over curl, shared by poll-jira.sh and lib-assign-rules.sh.
#
# Caller sets JIRA_SITE (host, no scheme), JIRA_API_BASE, JIRA_EMAIL, JIRA_TOKEN and TMPD.
#
# The credential goes to curl on STDIN via `--config -`, never in argv: an argv credential is
# readable by any other process on the box via `ps`, and this runs unattended.

# _jira_curl <out> <method> <url> [body] — writes the body to <out>, prints the HTTP status.
_jira_curl() {
  local out="$1" method="$2" url="$3" body="${4:-}" code
  if [ -n "$body" ]; then
    code="$(printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_TOKEN" \
      | curl -sS --config - -o "$out" -w '%{http_code}' \
             -X "$method" -H 'Content-Type: application/json' -H 'Accept: application/json' \
             --max-time 60 --data-binary "$body" "$url" 2>"$TMPD/curlerr")"
  else
    code="$(printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_TOKEN" \
      | curl -sS --config - -o "$out" -w '%{http_code}' \
             -X "$method" -H 'Accept: application/json' --max-time 60 "$url" 2>"$TMPD/curlerr")"
  fi
  printf '%s' "${code:-000}"
}

# jira_api <out> <method> <path-under-api-base> [body]
jira_api() { _jira_curl "$1" "$2" "https://${JIRA_SITE}${JIRA_API_BASE}${3}" "${4:-}"; }

# jira_site_api <out> <method> <path-from-site-root> — for endpoints outside the versioned API
# (e.g. /rest/dev-status/...).
jira_site_api() { _jira_curl "$1" "$2" "https://${JIRA_SITE}${3}" "${4:-}"; }

# jira_search <out> <jql> <maxResults> <fields-json> [nextPageToken] — one page of /search/jql.
jira_search() {
  local out="$1" jql="$2" mx="$3" fields="$4" token="${5:-}" body
  body="$(jq -nc --arg jql "$jql" --argjson mx "$mx" --argjson f "$fields" --arg tok "$token" \
    '{jql: $jql, maxResults: $mx, fields: $f} + (if $tok == "" then {} else {nextPageToken: $tok} end)')"
  jira_api "$out" POST "/search/jql" "$body"
}

# jira_transition_by_name <key> <name> — by target status name, then transition name,
# case-insensitively. rc 0 done, 4 no such transition from the current status, 1 API error
# (JIRA_HTTP holds the status).
jira_transition_by_name() {
  local key="$1" id
  JIRA_HTTP="$(jira_api "$TMPD/tr.json" GET "/issue/${key}/transitions")"
  [ "$JIRA_HTTP" = 200 ] || return 1
  id="$(jq -r --arg n "$2" '($n | ascii_downcase) as $n
    | ([.transitions[]? | select((.to.name // "" | ascii_downcase) == $n)] + [.transitions[]? | select((.name // "" | ascii_downcase) == $n)])
    | .[0].id // empty' "$TMPD/tr.json")"
  [ -n "$id" ] || return 4
  JIRA_HTTP="$(jira_api "$TMPD/trp.json" POST "/issue/${key}/transitions" "$(jq -nc --arg id "$id" '{transition: {id: $id}}')")"
  [ "$JIRA_HTTP" = 204 ] || [ "$JIRA_HTTP" = 200 ]
}

# jira_add_comment <key> <body-file> — plain-text comment (API v2 body). rc 0 on 201.
jira_add_comment() {
  JIRA_HTTP="$(jira_api "$TMPD/comment.json" POST "/issue/$1/comment" "$(jq -Rsc '{body: .}' < "$2")")"
  [ "$JIRA_HTTP" = 201 ]
}
