#!/bin/bash
# Stateful `gh` stub for the github-issues implement-next suites (sourced, not run: run-all.sh only
# runs *.test.sh). gh_stub_install <bin-dir> writes the stub; mkissue writes fixtures.
#
# State under $ST (owner/repo is always acme/web):
#   issues/<N>.json   GraphQL Issue node fixture (search + fetch)
#   <N>.assignees     comma-separated logins            <N>.status   board status ("" = not on board)
#   <N>.state         OPEN | CLOSED                     search       issue numbers every search returns
#   race_on_assign    an assign also adds "other"       me           own login (default tom)
# Writes are logged to $REQ_LOG as "<VERB> <what>".

gh_stub_install() {
  cat > "$1/gh" <<'EOF'
#!/bin/bash
[ "$1" = api ] || exit 1
shift
method=GET; path=""; query=""; declare -A F=()
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -f|-F) k="${2%%=*}"; k="${k%\[\]}"; v="${2#*=}"; [ "$k" = query ] && query="$v" || F[$k]="$v"; shift 2 ;;
    --jq) jqf="$2"; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
me="$(cat "$ST/me" 2>/dev/null || echo tom)"
node() {  # node <N> — the fixture with live assignees/board/state
  jq --arg a "$(cat "$ST/$1.assignees")" --arg s "$(cat "$ST/$1.status")" --arg st "$(cat "$ST/$1.state")" '
    .state = $st
    | .assignees = {totalCount: ($a | split(",") | map(select(. != "")) | length), nodes: ($a | split(",") | map(select(. != "")) | map({login: .}))}
    | .projectItems = {nodes: (if $s == "" then [] else [{id: "PI_\(.number)", project: {id: "PVT_1", number: 3, owner: {login: "acme"}}, status: {name: $s}}] end)}' \
    "$ST/issues/$1.json"
}
opt_name() { case "$1" in o1) echo Todo ;; o2) echo "In Progress" ;; o3) echo Ready ;; esac; }
if [ "$path" = user ]; then echo "$me"; exit 0; fi
if [ "$path" = graphql ]; then
  case "$query" in
    *"search(query"*)
      [ -f "$ST/search_fail" ] && { echo '{"errors":[{"message":"boom"}]}'; exit 1; }
      printf '%s\n' "${F[q]}" >> "$ST/queries"
      for n in $(cat "$ST/search"); do node "$n"; done | jq -s '{data: {search: {nodes: .}}}' ;;
    *"repositoryOwner"*)
      echo '{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_1","field":{"id":"F_1","options":[{"id":"o1","name":"Todo"},{"id":"o2","name":"In Progress"},{"id":"o3","name":"Ready"}]}}}}}' ;;
    *"addProjectV2ItemById"*)
      n="${F[c]#I_}"; echo Todo > "$ST/$n.status"; echo "ADD $n" >> "$REQ_LOG"
      jq -n --arg n "$n" '{data: {addProjectV2ItemById: {item: {id: "PI_\($n)"}}}}' ;;
    *"updateProjectV2ItemFieldValue"*)
      n="${F[i]#PI_}"; opt_name "${F[o]}" > "$ST/$n.status"; echo "STATUS $n $(cat "$ST/$n.status")" >> "$REQ_LOG"
      echo '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"x"}}}}' ;;
    *"node(id"*)
      node "${F[id]#I_}" | jq '{data: {node: {projectItems: (.projectItems | .nodes |= map(.project = {id: .project.id}))}}}' ;;
    *"repository(owner"*)
      node "${F[n]}" | jq '{data: {repository: {issue: .}}}' ;;
    *) echo '{"errors":[{"message":"unknown query"}]}'; exit 1 ;;
  esac
  exit 0
fi
n="$(printf '%s' "$path" | sed -nE 's#^repos/acme/web/issues/([0-9]+).*#\1#p')"
case "$method $path" in
  "GET repos/acme/web/issues/"*)
    jq -n --arg a "$(cat "$ST/$n.assignees")" --arg st "$(cat "$ST/$n.state" | tr '[:upper:]' '[:lower:]')" --arg n "$n" \
      '{state: $st, node_id: "I_\($n)", assignees: ($a | split(",") | map(select(. != "")) | map({login: .}))}' ;;
  "POST repos/acme/web/issues/"*"/assignees")
    echo "ASSIGN $n ${F[assignees]}" >> "$REQ_LOG"
    a="$(cat "$ST/$n.assignees")"; [ -f "$ST/race_on_assign" ] && a="${a:+$a,}other"
    echo "${a:+$a,}${F[assignees]}" > "$ST/$n.assignees"; echo '{}' ;;
  "DELETE repos/acme/web/issues/"*"/assignees")
    echo "UNASSIGN $n ${F[assignees]}" >> "$REQ_LOG"
    tr ',' '\n' < "$ST/$n.assignees" | grep -vxF "${F[assignees]}" | paste -sd, - > "$ST/$n.assignees.tmp"
    mv "$ST/$n.assignees.tmp" "$ST/$n.assignees"; echo '{}' ;;
  *) echo '{"message":"Not Found"}'; exit 1 ;;
esac
EOF
  chmod +x "$1/gh"
}

# mkissue <N> [author] [labels csv] [jq filter applied to the fixture]
mkissue() {
  mkdir -p "$ST/issues"
  jq -n --argjson n "$1" --arg au "${2:-lead}" --arg l "${3:-}" '
    {id: "I_\($n)", number: $n, title: "Fix thing \($n)", body: "Do it.\n- [ ] works", url: "https://github.com/acme/web/issues/\($n)",
     createdAt: "2025-11-01T10:00:00Z", updatedAt: "2025-11-01T10:00:00Z",
     repository: {nameWithOwner: "acme/web"}, author: {login: $au},
     labels: {nodes: ($l | split(",") | map(select(. != "")) | map({name: .}))},
     milestone: null, issueType: {name: "Bug"},
     closedByPullRequestsReferences: {totalCount: 0}, linkedBranches: {totalCount: 0},
     xrefs: {totalCount: 0, nodes: []}, blockedBy: {totalCount: 0, nodes: []},
     userContentEdits: {totalCount: 0, nodes: []}, edits: {totalCount: 0, nodes: []}}' \
    | jq "${4:-.}" > "$ST/issues/$1.json"
  : > "$ST/$1.assignees"; echo OPEN > "$ST/$1.state"; echo "${GH_STUB_STATUS-Ready}" > "$ST/$1.status"
}
