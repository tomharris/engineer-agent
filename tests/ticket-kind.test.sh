#!/bin/bash
# Tests for scripts/lib-ticket-kind.sh against references/ticket-kind.md.
#
# Every "fires" / "does not fire" example in that document is pinned here VERBATIM. That is the
# point of the suite: the doc is unusually specific about which titles must and must not classify as
# investigations, and those examples are the real spec — a title that wrongly classifies produces a
# findings comment where the human expected a PR (or the reverse), and the mistake is only visible
# at the approval gate if someone reads the plan carefully.
#
# Run: bash tests/ticket-kind.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib-ticket-kind.sh
source "${REPO_ROOT}/scripts/lib-ticket-kind.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
KW="$TMP/kw";     printf '%s\n' spike decision adr rfc investigate research evaluate compare assess determine > "$KW"
GL="$TMP/gl";     printf '%s\n' spike research investigation decision adr rfc discovery > "$GL"
JT="$TMP/jt";     printf '%s\n' Spike Decision Task > "$JT"
NOLBL="$TMP/none"; : > "$NOLBL"

# kind <title> [labels...] -> "<type>|<method>|<needs_form_b>"
kind() {
  local title="$1"; shift
  local lf="$TMP/lbl"; : > "$lf"
  [ $# -gt 0 ] && printf '%s\n' "$@" > "$lf"
  ticket_kind_classify --tracker github --title "$title" --labels-file "$lf" \
    --github-labels-file "$GL" --title-keywords-file "$KW" \
    | awk -F'\t' '{print $1"|"$2"|"$4}'
}
rationale() {
  local title="$1"
  ticket_kind_classify --tracker github --title "$title" --labels-file "$NOLBL" \
    --github-labels-file "$GL" --title-keywords-file "$KW" | cut -f3
}

expect() { # expect <label> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi
}
fires()     { expect "FIRES: $1"         "ticket-investigation|title-keyword|0" "$(kind "$1")"; }
not_fires() { expect "does not fire: $1" "ticket|default|0"                     "$(kind "$1")"; }

echo "== Tier 3 Form A: the doc's 'Fires' list, verbatim =="
fires "Spike: cache invalidation"
fires "[Decision] queue backend"
fires "(spike) websocket limits"
fires "SPIKE - can we drop Redis?"
fires "Decision — Sidekiq vs SQS"
fires "RFC | new auth flow"
fires "ADR: storage"
fires "Spike"

echo "== Tier 3 Form A: the doc's 'Does not fire' list, verbatim =="
not_fires "Add spike protection to the rate limiter"
not_fires "Rate limiter spike handling"
not_fires "Spikeguard: fix crash"
not_fires "Fix [spike] rendering"

echo "== Tier 3 normalization: the routing prefix must not hide the kind prefix =="
fires "[payroll-workflows] Spike: cache invalidation"
# "[Spike] Add caching" must match on the bracket it was handed, NOT be stripped to "Add caching".
expect "bracket that IS a keyword is not stripped" "ticket-investigation|title-keyword|0" "$(kind "[Spike] Add caching")"

echo "== Tier 3 rationale is mandatory for title-keyword =="
R="$(rationale 'Spike: cache invalidation')"
if [ -n "$R" ]; then ok "rationale present: $R"; else bad "title-keyword must carry a rationale"; fi
if printf '%s' "$R" | grep -q 'Form A'; then ok "rationale names the form"; else bad "rationale should name the form"; fi

echo "== Tier 3 Form B: flagged for a model, never silently guessed =="
# These are the doc's Form B "Fires" list. bash cannot decide verb-vs-noun, so it must default to
# code work (the spec's own tie-break) AND raise the flag.
for t in "Investigate why checkout 500s on retry" \
         "Compare Sidekiq and SQS for the outbox" \
         "Evaluate whether we can drop the Redis dependency" \
         "Researching the N+1 in the roster endpoint"; do
  expect "Form B candidate flagged: $t" "ticket|default|1" "$(kind "$t")"
done
# The mandatory disqualifier from the doc: "a leading word functioning as a noun or modifier is not
# an imperative". `Research` is a shipped VERB, so bash cannot rule it out — it defaults to code
# work (the correct answer here) and flags it so a model can confirm.
expect "verb-shaped disqualifier is flagged" "ticket|default|1" "$(kind 'Research service returns 500')"
# `Decision`, by contrast, is a NOUN in the shipped vocabulary and is Form A only — so Form B was
# never reachable and bash settles it outright, with NO model call. That asymmetry is worth pinning:
# it is the difference between paying for a judgment call and not needing one.
expect "noun-shaped disqualifier needs no model" "ticket|default|0" "$(kind 'Decision engine times out')"
# A NOUN-only keyword leading a title is Form A only — it must NEVER become a Form B candidate,
# or every "Spike handling is broken" bug wastes a model call.
expect "noun-only keyword is not a Form B candidate" "ticket|default|0" "$(kind 'Spike handling is broken')"
expect "no keyword at all"                           "ticket|default|0" "$(kind 'Fix the flaky roster test')"
# "no stemming beyond the gerund"
expect "comparison is not compare" "ticket|default|0" "$(kind 'Comparison of queue backends is wrong')"

echo "== Tier 2: GitHub label =="
expect "bare label"        "ticket-investigation|github-label|0" "$(kind 'Anything at all' spike)"
expect "type: prefix"      "ticket-investigation|github-label|0" "$(kind 'Anything at all' 'type: spike')"
expect "kind/ prefix"      "ticket-investigation|github-label|0" "$(kind 'Anything at all' 'kind/research')"
expect "category: prefix"  "ticket-investigation|github-label|0" "$(kind 'Anything at all' 'category: adr')"
expect "emoji prefix"      "ticket-investigation|github-label|0" "$(kind 'Anything at all' '🔬 discovery')"
expect "label wins over title" "ticket-investigation|github-label|0" "$(kind 'Fix the crash' spike)"
# Whole-string, never substring — each of these is a plausible real label that must NOT fire.
expect "spike-protection"   "ticket|default|0" "$(kind 'Anything at all' spike-protection)"
expect "no-research-needed" "ticket|default|0" "$(kind 'Anything at all' no-research-needed)"
expect "decision-log"       "ticket|default|0" "$(kind 'Anything at all' decision-log)"
expect "unrelated labels"   "ticket|default|0" "$(kind 'Anything at all' bug 'good first issue')"

echo "== Tier 1: Jira issue type, TERMINAL for Jira =="
jira() {
  ticket_kind_classify --tracker jira --jira-issue-type "$1" --title "${2:-}" \
    --jira-types-file "$JT" --github-labels-file "$GL" --title-keywords-file "$KW" \
    | awk -F'\t' '{print $1"|"$2"|"$4}'
}
expect "Spike type"            "ticket-investigation|jira-issuetype|0" "$(jira Spike)"
expect "case-insensitive"      "ticket-investigation|jira-issuetype|0" "$(jira spike)"
expect "Task ships as trigger" "ticket-investigation|jira-issuetype|0" "$(jira Task)"
expect "Story is code work"    "ticket|default|0"                     "$(jira Story)"
# The whole point of Tier 1 being terminal: a Jira title can NEVER reach the title tier.
expect "Jira title tier unreachable"      "ticket|default|0" "$(jira Story 'Spike: cache invalidation')"
expect "Jira Form B also unreachable"     "ticket|default|0" "$(jira Story 'Investigate why checkout 500s')"
expect "Jira 'Add spike protection'"      "ticket|default|0" "$(jira Story 'Add spike protection to the rate limiter')"

echo "== Tier 0: manual flag overrides everything =="
m() { ticket_kind_classify --tracker github --manual "$1" --title "$2" --title-keywords-file "$KW" | awk -F'\t' '{print $1"|"$2}'; }
expect "--investigate wins" "ticket-investigation|manual" "$(m investigate 'Fix the crash')"
expect "--implement wins"   "ticket|manual"               "$(m implement 'Spike: cache invalidation')"

echo "== disabled tiers ([] in config) =="
EMPTY="$TMP/empty"; : > "$EMPTY"
d="$(ticket_kind_classify --tracker github --title 'Spike: cache invalidation' \
      --labels-file "$NOLBL" --github-labels-file "$GL" --title-keywords-file "$EMPTY" \
      | awk -F'\t' '{print $1"|"$2"|"$4}')"
expect "empty title_keywords disables the tier" "ticket|default|0" "$d"
d2="$(ticket_kind_classify --tracker github --title 'x' \
      --labels-file <(echo spike) --github-labels-file "$EMPTY" --title-keywords-file "$KW" \
      | awk -F'\t' '{print $1"|"$2"|"$4}')"
expect "empty github_labels disables the tier" "ticket|default|0" "$d2"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
