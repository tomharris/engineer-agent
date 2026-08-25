#!/bin/bash
# End-to-end tests for scripts/poll-github-issues.sh with a stubbed `gh`.
#
# PATH-shim stubbing follows tests/slack-mcp.test.sh, which stubs `curl` and `security` the same
# way. The stub returns the exact TSV shape the real `gh --jq` expression produces, so the parsing,
# base64 decoding and label splitting are genuinely exercised rather than bypassed.
#
# What matters here is that the collector is the thing now upholding invariants that used to be
# prose instructions to a model. Each group below pins one of them:
#   - terminal state is ABSORBING (a completed item is never re-queued, no matter how recently the
#     issue was updated) — the self-sustaining loop that 14f0976 fixed
#   - collection is deduplicated PER REPO, so a shared repo is fetched once and routed per issue
#   - `--label` is never passed to `gh issue list` (it means AND and cannot union watchers)
#   - unrouted items stay out of seen_issues so they get re-checked
#   - a stranded incoming/ item is re-emitted, because only drafts/ is reachable by the gate
#   - a failed query leaves the repo cutoff UNCHANGED rather than silently skipping the window
#
# Run: bash tests/poll-github-issues.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLL="${REPO_ROOT}/scripts/poll-github-issues.sh"
TAB="$(printf '\t')"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state"
STUB="$TMP/bin"; mkdir -p "$STUB"
export PATH="$STUB:$PATH"

# --- the gh stub -------------------------------------------------------------------------------
# Emits rows from $GH_FIXTURE, records every invocation to $TMP/gh.calls, and fails when
# $GH_FAIL is set (to exercise the error path).
cat > "$STUB/gh" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
if [ -n "${GH_FAIL:-}" ]; then echo "simulated gh failure" >&2; exit 1; fi
repo=""; assignee=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --assignee) assignee="$2"; shift 2 ;;
    *) shift ;;
  esac
done
awk -F'|' -v r="$repo" -v a="$assignee" 'BEGIN{OFS="\t"} $1==r && $2==a {
  print $3, $4, $5, $6, $7, $8
}' "$GH_FIXTURE"
STUBEOF
chmod +x "$STUB/gh"
export GH_CALLS="$TMP/gh.calls"
export GH_FIXTURE="$TMP/fixture"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
SEP="$(printf '\001')"

cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  max_issue_age_days: 30
  investigation:
    jira_types: ["Spike"]
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "github-issues"
    github:
      owner: "acme"
      repos: ["shared", "alpha-only"]
      review_requested_for: "me"
      issues:
        assignee: "me"
        labels: ["backend"]
    routing:
      keywords: ["payroll"]
  beta:
    path: "/tmp/beta"
    tracker: "github-issues"
    github:
      owner: "acme"
      repos: ["shared"]
      review_requested_for: "me"
      issues:
        assignee: "me"
        labels: ["frontend"]
    routing:
      keywords: ["checkout"]
YAML

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD="2020-01-01T00:00:00Z"

# fixture columns: repo|assignee|number|updatedAt|title_b64|body_b64|labels|url
fixture() { printf '%s\n' "$@" > "$GH_FIXTURE"; }
run() { : > "$GH_CALLS"; "$POLL" --run-ts "$NOW" --manifest "$1" >"$TMP/out" 2>"$TMP/err"; echo $?; }
item() { ls "$EA_AGENT_DIR/queue/incoming/"*"$1"* 2>/dev/null | head -1; }
fmv() { awk -v k="$2" 'NR==1&&/^---/{i=1;next} i&&/^---/{exit} i{l=$0;sub(/^ +/,"",l);key=l;sub(/:.*/,"",key);if(key!=k)next;v=substr(l,index(l,":")+1);sub(/^ +/,"",v);gsub(/^"|"$/,"",v);print v;exit}' "$1"; }

echo "== routing on a SHARED repo, one fetch, per-issue decisions =="
fixture \
  "acme/shared|me|101|${NOW}|$(b64 '[alpha] Add payroll endpoint')|$(b64 'body')|backend|https://gh/101" \
  "acme/shared|me|102|${NOW}|$(b64 'Fix the checkout flow')|$(b64 'body')|frontend|https://gh/102" \
  "acme/shared|me|103|${NOW}|$(b64 'Totally ambiguous thing')|$(b64 'body')||https://gh/103" \
  "acme/shared|me|104|${NOW}|$(b64 'Fix the checkout flow')|$(b64 'body')||https://gh/104" \
  "acme/alpha-only|me|201|${NOW}|$(b64 'Solo repo issue')|$(b64 'body')||https://gh/201"
M="$TMP/m1"; : > "$M"
rc="$(run "$M")"
eq "exit 0" "0" "$rc"
eq "prefix route"        "alpha"     "$(fmv "$(item gh-101)" project)"
eq "prefix method"       "prefix"    "$(fmv "$(item gh-101)" routing_method)"
# Tier 2 (label filters) runs BEFORE Tier 3a (hints), so a labelled issue routes by `filters`
# even when its title would also have matched a keyword. The tiers are ordered, not scored.
eq "label filter route"  "beta"      "$(fmv "$(item gh-102)" project)"
eq "label filter method" "filters"   "$(fmv "$(item gh-102)" routing_method)"
# The same title with NO labels falls past Tier 2 and is resolved by the Tier 3a keyword hint.
eq "keyword route"       "beta"      "$(fmv "$(item gh-104)" project)"
eq "keyword method"      "keyword"   "$(fmv "$(item gh-104)" routing_method)"
eq "ambiguous unrouted"  "_unrouted" "$(fmv "$(item gh-103)" project)"
eq "matched_projects"    '["alpha", "beta"]' "$(fmv "$(item gh-103)" matched_projects)"
eq "solo repo free"      "single-candidate" "$(fmv "$(item gh-201)" routing_method)"

echo "== the two traps the skill documents =="
# gh issue list --label a --label b means AND, so watchers' filters must never become query flags.
if grep -q -- '--label' "$GH_CALLS"; then bad "--label must never be passed to gh issue list"; else ok "no --label flag passed to gh"; fi
# The shared repo has two watchers but must be fetched ONCE (dedup is per repo, not per project).
eq "shared repo fetched once" "1" "$(grep -c 'repo acme/shared' "$GH_CALLS")"

echo "== manifest names what still needs a model =="
eq "manifest rows" "5" "$(wc -l < "$M" | tr -d ' ')"
eq "ambiguous flagged for inference" "1" "$(awk -F"$TAB" '$5=="acme/shared#103"{print $6}' "$M")"
eq "resolved item not flagged"       "0" "$(awk -F"$TAB" '$5=="acme/shared#101"{print $6}' "$M")"

echo "== frontmatter + body shape =="
F="$(item gh-101)"
eq "type"        "ticket"                "$(fmv "$F" type)"
eq "source"      "github"                "$(awk 'NR==1&&/^---/{i=1;next} i&&/^---/{exit} /^source:/{print $2;exit}' "$F")"
eq "source_id"   "acme/shared#101"       "$(fmv "$F" source_id)"
eq "ticket_key"  "#101"                  "$(fmv "$F" ticket_key)"
eq "status"      "incoming"              "$(awk 'NR==1&&/^---/{i=1;next} i&&/^---/{exit} /^status:/{print $2;exit}' "$F")"
eq "labels"      '["backend"]'           "$(fmv "$F" github_labels)"
if grep -q '^## Context' "$F"; then ok "has Context section"; else bad "missing Context"; fi
if grep -q '^### Acceptance Criteria' "$F"; then ok "has AC section"; else bad "missing AC"; fi
# Undrafted by construction — the model adds this, and its absence is what the resume sweep keys on.
if grep -q '^## Draft Response' "$F"; then bad "collector must NOT write a draft"; else ok "no draft written (model's job)"; fi
# _unrouted items are classified LATE — no kind method until a slug exists.
if [ -z "$(fmv "$(item gh-103)" ticket_kind_method)" ]; then ok "_unrouted has no kind method"; else bad "_unrouted must not carry a kind"; fi

echo "== state =="
S="$EA_AGENT_DIR/state/last-poll.yaml"
if grep -q 'acme/shared' "$S"; then ok "repo cutoff recorded"; else bad "missing repo cutoff"; fi
if grep -q 'acme/shared#101' "$S"; then ok "routed issue in seen_issues"; else bad "routed issue missing from seen"; fi
# An unrouted issue must be re-checked next poll, so it is deliberately NOT recorded as seen.
if grep -q 'acme/shared#103' "$S"; then bad "unrouted must NOT enter seen_issues"; else ok "unrouted stays out of seen_issues"; fi

echo "== idempotency: a second identical poll creates nothing new =="
BEFORE="$(ls "$EA_AGENT_DIR/queue/incoming" | wc -l | tr -d ' ')"
M2="$TMP/m2"; : > "$M2"; run "$M2" >/dev/null
AFTER="$(ls "$EA_AGENT_DIR/queue/incoming" | wc -l | tr -d ' ')"
eq "no duplicate files" "$BEFORE" "$AFTER"
eq "unchanged reported" "4" "$(grep -o '[0-9]* unchanged' "$TMP/out" | grep -o '^[0-9]*')"

echo "== terminal state is ABSORBING =="
# Move a routed item to completed/, then poll again with the issue freshly updated. This is the
# self-sustaining loop: engineer-agent's own comment bumps updatedAt. It must NOT be re-queued.
mv "$(item gh-101)" "$EA_AGENT_DIR/queue/completed/"
M3="$TMP/m3"; : > "$M3"; run "$M3" >/dev/null
if [ -z "$(item gh-101)" ]; then ok "completed issue not re-queued"; else bad "completed issue was RE-QUEUED"; fi
if grep -q 'Skipped (terminal): acme/shared#101' "$TMP/out"; then ok "skip is reported, not silent"; else bad "terminal skip must be reported"; fi
# The family rule: a retitled issue that would now classify as an investigation must still be
# absorbed by the completed ticket, not mint a rival item.
fixture "acme/shared|me|101|${NOW}|$(b64 'Spike: Add payroll endpoint')|$(b64 'body')|backend|https://gh/101"
M4="$TMP/m4"; : > "$M4"; run "$M4" >/dev/null
if [ -z "$(item gh-101)" ]; then ok "retitled issue absorbed by completed ticket (family rule)"; else bad "family rule failed: rival item created"; fi

echo "== recency guard (agent.max_issue_age_days) =="
fixture "acme/shared|me|301|${OLD}|$(b64 'Ancient backlog item')|$(b64 'x')|backend|https://gh/301"
M5="$TMP/m5"; : > "$M5"; run "$M5" >/dev/null
if [ -z "$(item gh-301)" ]; then ok "stale issue excluded"; else bad "stale issue should be excluded"; fi
fixture "acme/shared|me|302|${NOW}|$(b64 'Recent payroll item')|$(b64 'x')|backend|https://gh/302"
M6="$TMP/m6"; : > "$M6"; run "$M6" >/dev/null
if [ -n "$(item gh-302)" ]; then ok "recent issue included"; else bad "recent issue should be included"; fi

echo "== kind ladder wiring =="
fixture "acme/shared|me|401|${NOW}|$(b64 'Spike: payroll cache invalidation')|$(b64 'x')|backend|https://gh/401" \
        "acme/shared|me|402|${NOW}|$(b64 'Investigate the payroll 500s')|$(b64 'x')|backend|https://gh/402" \
        "acme/shared|me|403|${NOW}|$(b64 'Add payroll spike protection')|$(b64 'x')|backend|https://gh/403"
M7="$TMP/m7"; : > "$M7"; run "$M7" >/dev/null
eq "Form A -> investigation" "ticket-investigation" "$(fmv "$(item gh-401)" type)"
eq "Form A method"           "title-keyword"        "$(fmv "$(item gh-401)" ticket_kind_method)"
if [ -n "$(fmv "$(item gh-401)" ticket_kind_rationale)" ]; then ok "Form A carries a rationale"; else bad "title-keyword needs a rationale"; fi
eq "Form B defaults to code work" "ticket" "$(fmv "$(item gh-402)" type)"
eq "Form B flagged for a model"   "1"      "$(awk -F"$TAB" '$5=="acme/shared#402"{print $7}' "$M7")"
eq "noun mid-title stays code"    "ticket" "$(fmv "$(item gh-403)" type)"
eq "noun mid-title unflagged"     "0"      "$(awk -F"$TAB" '$5=="acme/shared#403"{print $7}' "$M7")"

echo "== resume sweep: a stranded item is re-emitted =="
# Strand an item exactly as a killed drafting phase would: present in incoming/, no draft section.
M8="$TMP/m8"; : > "$M8"
fixture "acme/shared|me|999|${NOW}|$(b64 'unrelated')|$(b64 'x')||https://gh/999"
run "$M8" >/dev/null
STRANDED="$(item gh-401)"
if [ -n "$STRANDED" ]; then
  if grep -qF "$(printf 'resume\t%s\t' "$STRANDED")" "$M8"; then ok "stranded item re-emitted as resume"; else bad "stranded item was NOT re-emitted"; fi
else bad "fixture problem: no stranded item present"; fi
# Once drafted, it must drop out — otherwise every poll re-drafts the whole backlog.
printf '\n## Draft Response\ndone\n' >> "$STRANDED"
M9="$TMP/m9"; : > "$M9"; run "$M9" >/dev/null
if grep -qF "$(printf 'resume\t%s\t' "$STRANDED")" "$M9"; then bad "drafted item must leave the sweep"; else ok "drafted item leaves the sweep"; fi

echo "== a failed query must not advance the cutoff =="
BEFORE_TS="$(grep -A1 'acme/shared:' "$S" | grep last_checked | head -1)"
fixture "acme/shared|me|501|${NOW}|$(b64 'x')|$(b64 'x')||https://gh/501"
GH_FAIL=1 "$POLL" --run-ts "2099-01-01T00:00:00Z" --manifest "$TMP/m10" >/dev/null 2>&1
AFTER_TS="$(grep -A1 'acme/shared:' "$S" | grep last_checked | head -1)"
eq "cutoff unchanged after failure" "$BEFORE_TS" "$AFTER_TS"
if [ -z "$(item gh-501)" ]; then ok "no item created from a failed query"; else bad "failed query created an item"; fi

echo "== --dry-run writes nothing =="
fixture "acme/shared|me|601|${NOW}|$(b64 'payroll dry run')|$(b64 'x')|backend|https://gh/601"
BEFORE_N="$(ls "$EA_AGENT_DIR/queue/incoming" | wc -l | tr -d ' ')"
BEFORE_STATE="$(cat "$S")"
"$POLL" --dry-run --run-ts "$NOW" --manifest "$TMP/m11" >/dev/null 2>&1
eq "no files written"  "$BEFORE_N" "$(ls "$EA_AGENT_DIR/queue/incoming" | wc -l | tr -d ' ')"
eq "no state written"  "$BEFORE_STATE" "$(cat "$S")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
