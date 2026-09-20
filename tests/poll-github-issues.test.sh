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

echo "== ticket-kind Tier 3 Form B: deferred by default, judged when configured =="
# The default first: with no agent.typesafe.ticket_kind block, a Form B candidate is written as a
# plain `ticket` and flagged needs_kind_check=1 for Phase B. That is the behaviour every install
# has had, and it must survive the judge existing at all.
fixture "acme/alpha-only|me|701|${NOW}|$(b64 'Investigate why checkout 500s on retry')|$(b64 'x')||https://gh/701"
M12="$TMP/m12"; : > "$M12"; run "$M12" >/dev/null
eq "unconfigured: written as a plain ticket" "ticket" "$(fmv "$(item gh-701)" type)"
eq "unconfigured: flagged for Phase B"       "1"      "$(awk -F"$TAB" '$5=="acme/alpha-only#701"{print $7}' "$M12")"

# Now the judgment. `curl` and `security` are stubbed exactly as in tests/ticket-kind-judge.test.sh
# — `security` because ea_secret_resolve would otherwise reach the developer's real Keychain entry
# and quietly make the "no key" case pass for the wrong reason.
printf '#!/bin/bash\nexit 1\n' > "$STUB/security"; chmod +x "$STUB/security"
export ANSWERS="$TMP/answers.json"
export TS_CODE="$TMP/ts.code"; echo 200 > "$TS_CODE"
export CURL_ARGV="$TMP/curl.argv"; : > "$CURL_ARGV"
export CURL_BODY="$TMP/curl.body"; : > "$CURL_BODY"
cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
out=""; prev=""; body=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; esac
  case "$a" in @*) body="${a#@}" ;; esac
  prev="$a"
done
printf '%s\n' "$*" >> "$CURL_ARGV"
cat > /dev/null
[ -n "$body" ] && cat "$body" > "$CURL_BODY"
cat "$ANSWERS" > "$out"
printf '%s' "$(cat "$TS_CODE")"
STUBEOF
chmod +x "$STUB/curl"
export EA_TYPESAFE_RETRIES=0
export EA_TEST_TK_KEY="sk-test-e2e"
tk_noul() { jq -nc --argjson p "$1" \
  '{model:"jev-latest",answers:{leading_imperative:{type:"noul",noul:$p}}}' > "$ANSWERS"; }

if command -v jq >/dev/null 2>&1; then
  # Insert the opt-in under `agent:`, leaving the rest of the config (and so every routing
  # assertion above) untouched.
  sed -i.bak '/^agent:$/a\
  typesafe:\
    api_key_env: "EA_TEST_TK_KEY"\
    ticket_kind:\
      enabled: true\
      min_imperative: 0.60' "$EA_AGENT_DIR/engineer.yaml"
  rm -f "$EA_AGENT_DIR/engineer.yaml.bak"

  # Fires: the kind is settled HERE, so `type:` and the filename are right the first time and
  # Phase B is not asked to revisit it.
  : > "$CURL_ARGV"; tk_noul 0.93
  fixture "acme/alpha-only|me|702|${NOW}|$(b64 'Investigate why checkout 500s on retry')|$(b64 'x')||https://gh/702"
  M13="$TMP/m13"; : > "$M13"; run "$M13" >/dev/null
  F13="$(item gh-702)"
  eq "judged imperative: type"    "ticket-investigation" "$(fmv "$F13" type)"
  eq "judged imperative: method"  "title-keyword"        "$(fmv "$F13" ticket_kind_method)"
  eq "judged imperative: manifest type" "ticket-investigation" "$(awk -F"$TAB" '$5=="acme/alpha-only#702"{print $3}' "$M13")"
  eq "judged: flag cleared"       "0" "$(awk -F"$TAB" '$5=="acme/alpha-only#702"{print $7}' "$M13")"
  # The filename carries {type}; a kind settled after reconciliation would leave it misnamed.
  case "$(basename "$F13")" in *-ticket-investigation-*) ok "filename carries the settled type" ;;
    *) bad "filename should carry ticket-investigation: $(basename "$F13")" ;; esac
  # The rationale is the audit trail at the approval gate: it must name the form AND the evidence,
  # for the same reason routing_rationale does on an inferred route.
  R13="$(fmv "$F13" ticket_kind_rationale)"
  case "$R13" in *"Form B"*) ok "rationale names the form" ;; *) bad "rationale should name Form B: $R13" ;; esac
  case "$R13" in *0.93*) ok "rationale carries the probability" ;; *) bad "rationale should carry the score: $R13" ;; esac
  eq "exactly one judgment request" "1" "$(wc -l < "$CURL_ARGV" | tr -d '[:space:]')"
  if grep -q 'sk-test-e2e' "$CURL_ARGV"; then bad "API KEY LEAKED INTO argv"; else ok "key never in argv"; fi

  # Does not fire: judged, and judged NO. Still a ticket — but the flag is cleared, because the
  # question was answered rather than skipped.
  : > "$CURL_ARGV"; tk_noul 0.08
  fixture "acme/alpha-only|me|703|${NOW}|$(b64 'Research service returns 500 on the payroll route')|$(b64 'x')||https://gh/703"
  M14="$TMP/m14"; : > "$M14"; run "$M14" >/dev/null
  eq "judged noun: stays a ticket" "ticket" "$(fmv "$(item gh-703)" type)"
  eq "judged noun: flag cleared"   "0"      "$(awk -F"$TAB" '$5=="acme/alpha-only#703"{print $7}' "$M14")"

  # A transport failure must NOT become a silent "no": the flag stays up and Phase B answers it,
  # exactly as on an install with no key. Otherwise an outage quietly reclassifies every spike.
  : > "$CURL_ARGV"; tk_noul 0.99; echo 500 > "$TS_CODE"
  fixture "acme/alpha-only|me|704|${NOW}|$(b64 'Investigate the N+1 in the roster endpoint')|$(b64 'x')||https://gh/704"
  M15="$TMP/m15"; : > "$M15"; run "$M15" >/dev/null
  eq "failed judgment: still written" "ticket" "$(fmv "$(item gh-704)" type)"
  eq "failed judgment: deferred to Phase B" "1" "$(awk -F"$TAB" '$5=="acme/alpha-only#704"{print $7}' "$M15")"
  echo 200 > "$TS_CODE"

  # Form A is never sent anywhere — it is settled in bash, and that is the cost and containment
  # argument for keeping it there.
  : > "$CURL_ARGV"; tk_noul 0.99
  fixture "acme/alpha-only|me|705|${NOW}|$(b64 'Spike: queue backend')|$(b64 'x')||https://gh/705"
  run "$TMP/m16" >/dev/null
  eq "Form A settled offline"            "ticket-investigation" "$(fmv "$(item gh-705)" type)"
  eq "Form A makes no judgment request"  "0" "$(wc -l < "$CURL_ARGV" | tr -d '[:space:]')"

  # And a title with no configured leading keyword never reaches the wire either.
  : > "$CURL_ARGV"
  fixture "acme/alpha-only|me|706|${NOW}|$(b64 'Fix the flaky roster test')|$(b64 'x')||https://gh/706"
  run "$TMP/m17" >/dev/null
  eq "non-candidate makes no request" "0" "$(wc -l < "$CURL_ARGV" | tr -d '[:space:]')"

  rm -f "$STUB/curl"
else
  echo "  SKIP: jq not installed (the judge degrades to the model without it)"
fi

echo "== routing Tier 3b: deferred by default, judged when configured =="
# Default first, same shape as the Form B block above: with no agent.typesafe.routing block an
# ambiguous issue is written `_unrouted` with matched_projects and flagged for Phase B. That is
# what every install does today and it must survive the judge existing.
fixture "acme/shared|me|801|${NOW}|$(b64 'Totally ambiguous thing again')|$(b64 'nothing to go on')||https://gh/801"
M18="$TMP/m18"; : > "$M18"; run "$M18" >/dev/null
eq "unconfigured: unrouted"          "_unrouted" "$(fmv "$(item gh-801)" project)"
eq "unconfigured: flagged for Phase B" "1"       "$(awk -F"$TAB" '$5=="acme/shared#801"{print $6}' "$M18")"

if command -v jq >/dev/null 2>&1; then
  # Re-create the curl stub the Form B block removed, and add the routing opt-in beside it. Both
  # features are now on at once, which is the realistic case and pins that they stay independent.
  cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
out=""; prev=""; body=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; esac
  case "$a" in @*) body="${a#@}" ;; esac
  prev="$a"
done
printf '%s\n' "$*" >> "$CURL_ARGV"
cat > /dev/null
[ -n "$body" ] && cat "$body" > "$CURL_BODY"
cat "$ANSWERS" > "$out"
printf '%s' "$(cat "$TS_CODE")"
STUBEOF
  chmod +x "$STUB/curl"
  sed -i.bak '/^      min_imperative: 0.60$/a\
    routing:\
      enabled: true\
      min_confidence: 0.70' "$EA_AGENT_DIR/engineer.yaml"
  rm -f "$EA_AGENT_DIR/engineer.yaml.bak"

  rt_choice() { jq -nc --arg c "$1" --argjson p "$2" \
    '{model:"jev-latest",answers:{project_match:{type:"choice",choice:$c,confidence:($p[$c] // 0),probabilities:$p}}}' > "$ANSWERS"; }

  # A confident winner routes, and — the thing only an end-to-end test can show — the KIND ladder
  # then runs against the project the judgment just chose. Kind lists are per-project overridable,
  # so classifying before the slug was settled would have used the wrong lists (or, for an item
  # still `_unrouted`, skipped the kind entirely and shipped it with none).
  : > "$CURL_ARGV"; rt_choice alpha '{"alpha":0.88,"beta":0.09,"none_of_these":0.03}'
  fixture "acme/shared|me|802|${NOW}|$(b64 'Another ambiguous one')|$(b64 'no hints here')||https://gh/802"
  M19="$TMP/m19"; : > "$M19"; run "$M19" >/dev/null
  eq "judged: routed"        "alpha"    "$(fmv "$(item gh-802)" project)"
  eq "judged: method"        "inferred" "$(fmv "$(item gh-802)" routing_method)"
  eq "judged: flag cleared"  "0"        "$(awk -F"$TAB" '$5=="acme/shared#802"{print $6}' "$M19")"
  eq "judged: kind ran after routing" "default" "$(fmv "$(item gh-802)" ticket_kind_method)"
  case "$(fmv "$(item gh-802)" routing_rationale)" in
    *"p=0.88"*) ok "judged: rationale carries the evidence" ;;
    *) bad "judged: rationale should carry p=0.88 — got [$(fmv "$(item gh-802)" routing_rationale)]" ;;
  esac
  # A routed issue is recorded as seen; the _unrouted ones above deliberately are not.
  if grep -q 'acme/shared#802' "$S"; then ok "judged: routed issue enters seen_issues"; else bad "judged: routed issue missing from seen"; fi

  # An answered "cannot tell" leaves it for the human and CLEARS the flag: Phase B re-deciding a
  # question that was already answered would pay twice and could overturn the abstention.
  : > "$CURL_ARGV"; rt_choice none_of_these '{"alpha":0.30,"beta":0.25,"none_of_these":0.45}'
  fixture "acme/shared|me|803|${NOW}|$(b64 'Bump a linter somewhere')|$(b64 'no hints here')||https://gh/803"
  M20="$TMP/m20"; : > "$M20"; run "$M20" >/dev/null
  eq "abstained: stays unrouted"  "_unrouted" "$(fmv "$(item gh-803)" project)"
  eq "abstained: flag cleared"    "0"         "$(awk -F"$TAB" '$5=="acme/shared#803"{print $6}' "$M20")"
  eq "abstained: keeps candidates for the human" '["alpha", "beta"]' "$(fmv "$(item gh-803)" matched_projects)"

  # A transport failure is NOT an abstention: Phase B still gets the tier, exactly as on an install
  # with no key at all.
  : > "$CURL_ARGV"; rt_choice alpha '{"alpha":0.99}'; echo 500 > "$TS_CODE"
  fixture "acme/shared|me|804|${NOW}|$(b64 'Yet another ambiguous one')|$(b64 'no hints here')||https://gh/804"
  M21="$TMP/m21"; : > "$M21"; run "$M21" >/dev/null
  eq "failed: stays unrouted"          "_unrouted" "$(fmv "$(item gh-804)" project)"
  eq "failed: deferred to Phase B"     "1"         "$(awk -F"$TAB" '$5=="acme/shared#804"{print $6}' "$M21")"
  echo 200 > "$TS_CODE"

  # An issue Tier 0-3a already resolved never reaches the wire — the judgment is only ever paid for
  # on a genuine ambiguity.
  : > "$CURL_ARGV"
  fixture "acme/shared|me|805|${NOW}|$(b64 '[alpha] Resolved by prefix')|$(b64 'x')||https://gh/805"
  run "$TMP/m22" >/dev/null
  eq "resolved item makes no request" "0" "$(wc -l < "$CURL_ARGV" | tr -d '[:space:]')"

  # NOR does an item reconciliation is about to discard. Found on the first live run: 3 requests
  # went out for 2 issues that were then skipped as terminal — paying to decide where to file work
  # that is already finished, and (for routing) egressing its body to do it. The disposition is a
  # filesystem lookup and free; the judgment is not, so the free one goes first.
  : > "$CURL_ARGV"; rt_choice alpha '{"alpha":0.99}'
  fixture "acme/shared|me|806|${NOW}|$(b64 'Ambiguous but already done')|$(b64 'no hints here')||https://gh/806"
  run "$TMP/m23" >/dev/null
  mv "$(item gh-806)" "$EA_AGENT_DIR/queue/completed/"
  : > "$CURL_ARGV"
  run "$TMP/m24" >/dev/null
  eq "terminal item makes no request" "0" "$(wc -l < "$CURL_ARGV" | tr -d '[:space:]')"

  # Same for an item already drafted: its route is not rewritten, so it must not be re-judged.
  : > "$CURL_ARGV"; rt_choice alpha '{"alpha":0.99}'
  fixture "acme/shared|me|807|${NOW}|$(b64 'Ambiguous and drafted')|$(b64 'no hints here')||https://gh/807"
  run "$TMP/m25" >/dev/null
  mv "$(item gh-807)" "$EA_AGENT_DIR/queue/drafts/"
  : > "$CURL_ARGV"
  run "$TMP/m26" >/dev/null
  eq "already-drafted item makes no request" "0" "$(wc -l < "$CURL_ARGV" | tr -d '[:space:]')"

  rm -f "$STUB/curl"
else
  echo "  SKIP: jq not installed (the judge degrades to the model without it)"
fi

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
