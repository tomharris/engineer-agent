#!/bin/bash
# Tests for scripts/lib-ticket-kind-judge.sh — ticket-kind Tier 3 Form B as a typed judgment.
#
# `curl` is stubbed on PATH and every probability is chosen here, so nothing touches the network.
# That is the same property that makes the judgment worth having: the POLICY (a threshold, a
# fallback, an opt-in) is in bash and can be tested exhaustively, while the model answers only the
# one grammatical question bash cannot.
#
# What is pinned, and why each is a thing that could silently break:
#   • THE OPT-IN IS REAL. Disabled, or enabled with no key, must reach no network at all. This is
#     the user-facing promise that a TypeSafe key set for Slack does not start sending issue
#     titles — the failure the per-feature gate exists to prevent.
#   • A FAILED JUDGMENT IS NOT A "NO". Every transport and parse failure must abstain (rc 1), so
#     the caller leaves needs_kind=1 and Phase B answers it. A silent "no" would quietly convert
#     any outage into "everything is code work".
#   • THE API KEY NEVER APPEARS IN argv. This runs unattended; `ps` is public.
#   • THE BODY IS NEVER SENT. The tier is defined over the title; egress must match that.
#   • THE PRECONDITION STILL GATES WHAT IS ASKED. A title with no configured leading keyword, or
#     one already settled by Form A, must produce no request — containment plus cost.
#
# Run: bash tests/ticket-kind-judge.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (the judge degrades to the model without it)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR" "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# `security` MUST be shimmed: ea_secret_resolve falls through env -> file -> macOS login keychain,
# so without this the "no key" cases would find the DEVELOPER'S REAL engineer-agent-typesafe
# credential and proceed — making the degradation assertions fail on exactly the machines this
# plugin is developed on.
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"

export ANSWERS="$TMP/answers.json"
export TS_CODE="$TMP/ts.code";  echo 200 > "$TS_CODE"
export CURL_ARGV="$TMP/curl.argv"; : > "$CURL_ARGV"
export CURL_STDIN="$TMP/curl.stdin"; : > "$CURL_STDIN"
export CURL_BODY="$TMP/curl.body"; : > "$CURL_BODY"

cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out=""; prev=""; body=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; esac
  case "$a" in @*) body="${a#@}" ;; esac
  prev="$a"
done
printf '%s\n' "$*" >> "$CURL_ARGV"
cat >> "$CURL_STDIN"
[ -n "$body" ] && cat "$body" > "$CURL_BODY"
cat "$ANSWERS" > "$out"
printf '%s' "$(cat "$TS_CODE")"
EOF
chmod +x "$TMP/bin/curl"

# noul <probability> — the shape lib-typesafe.sh's ts_noul reads.
noul() { jq -nc --argjson p "$1" \
  '{model:"jev-latest", answers:{leading_imperative:{type:"noul",noul:$p}}, usage:{input_tokens:1,output_tokens:1}}' > "$ANSWERS"; }

reset() { : > "$CURL_ARGV"; : > "$CURL_STDIN"; : > "$CURL_BODY"; echo 200 > "$TS_CODE"; }
# wc, not `grep -c . || echo 0`: grep exits 1 on an empty file, so the `||` fires AFTER grep has
# already printed its own 0 and the helper returns "0\n0". Same family as the pipefail/grep -q
# trap in CLAUDE.md — a counting helper must not have a failure branch that also prints.
calls() { wc -l < "$CURL_ARGV" | tr -d '[:space:]'; }

# One attempt per call. The retry/backoff ladder belongs to lib-typesafe.sh and is pinned by
# tests/poll-slack.test.sh; re-running it here only adds 6 seconds of sleep to every 5xx case.
export EA_TYPESAFE_RETRIES=0

# shellcheck source=../scripts/lib-secret.sh
source "${REPO_ROOT}/scripts/lib-secret.sh"
# shellcheck source=../scripts/lib-typesafe.sh
source "${REPO_ROOT}/scripts/lib-typesafe.sh"
# shellcheck source=../scripts/lib-ticket-kind-judge.sh
source "${REPO_ROOT}/scripts/lib-ticket-kind-judge.sh"
# shellcheck source=../scripts/lib-ticket-kind.sh
source "${REPO_ROOT}/scripts/lib-ticket-kind.sh"

# cfg <yaml-fragment-for-agent.typesafe> — rebuild EA_CFG from a real engineer.yaml, through
# ea-config.sh, so these tests also cover the normalizer rather than a hand-written dump.
cfg() {
  { echo "agent:"; echo "  typesafe:"; printf '%s\n' "$1"
    echo "projects:"; echo "  alpha:"; echo "    path: \"/tmp/alpha\""; echo "    tracker: \"none\""
  } > "$EA_AGENT_DIR/engineer.yaml"
  EA_CFG="$("${REPO_ROOT}/scripts/ea-config.sh" dump)"; export EA_CFG
}

echo "== the opt-in is real: nothing reaches the network unless BOTH gates pass =="
reset; unset EA_TEST_TK_KEY
cfg '    api_key_env: "EA_TEST_TK_KEY"'
if tk_judge_enabled; then bad "no key + no enable must not enable"; else ok "disabled and keyless: not enabled"; fi

export EA_TEST_TK_KEY="sk-test-abc123"
cfg '    api_key_env: "EA_TEST_TK_KEY"'
if tk_judge_enabled; then bad "a key alone must NOT enable ticket-kind judging"; else ok "key alone (the Slack case) does not enable it"; fi

cfg '    api_key_env: "EA_TEST_TK_KEY"
    ticket_kind:
      enabled: false'
if tk_judge_enabled; then bad "enabled:false must not enable"; else ok "enabled: false is off"; fi

cfg '    api_key_env: "EA_TEST_TK_KEY"
    ticket_kind:
      enabled: "yes"'
if tk_judge_enabled; then bad "only the exact string true enables"; else ok "enabled: \"yes\" is off (exact match only)"; fi

unset EA_TEST_TK_KEY
cfg '    api_key_env: "EA_TEST_TK_KEY"
    ticket_kind:
      enabled: true'
if tk_judge_enabled; then bad "enabled with no resolvable key must not enable"; else ok "enabled but keyless is off"; fi
eq "no request was made by any gate check" "0" "$(calls)"

export EA_TEST_TK_KEY="sk-test-abc123"
cfg '    api_key_env: "EA_TEST_TK_KEY"
    ticket_kind:
      enabled: true
      min_imperative: 0.60'
if tk_judge_enabled; then ok "both gates pass: enabled"; else bad "both gates pass: should be enabled"; fi
eq "threshold read from config" "0.60" "$(tk_judge_min)"

echo "== the verdict, in both directions =="
reset; noul 0.91
p="$(tk_form_b_judge 'Investigate why checkout 500s on retry' 'Investigate')"
eq "imperative: probability returned" "0.91" "$p"
if ts_ge "$p" "$(tk_judge_min)"; then ok "0.91 fires at 0.60"; else bad "0.91 should fire at 0.60"; fi

reset; noul 0.12
p="$(tk_form_b_judge 'Research service returns 500' 'Research')"
eq "noun-shaped: probability returned" "0.12" "$p"
if ts_ge "$p" "$(tk_judge_min)"; then bad "0.12 must not fire at 0.60"; else ok "0.12 does not fire at 0.60"; fi

reset; noul 0.60
p="$(tk_form_b_judge 'Compare Sidekiq and SQS' 'Compare')"
if ts_ge "$p" "0.60"; then ok "the threshold is inclusive (>=)"; else bad "0.60 should satisfy >= 0.60"; fi

echo "== a failed judgment ABSTAINS — it never becomes a silent 'no' =="
reset; noul 0.99; echo 500 > "$TS_CODE"
if tk_form_b_judge 'Investigate the N+1' 'Investigate' >/dev/null; then
  bad "a 500 must abstain"; else ok "HTTP 500 abstains (rc 1)"; fi

reset; noul 0.99; echo 401 > "$TS_CODE"
if tk_form_b_judge 'Investigate the N+1' 'Investigate' >/dev/null; then
  bad "a 401 must abstain"; else ok "HTTP 401 abstains (rc 1)"; fi

reset; echo '{"model":"jev-latest","answers":{}}' > "$ANSWERS"
if tk_form_b_judge 'Investigate the N+1' 'Investigate' >/dev/null; then
  bad "a 200 with no answer must abstain"; else ok "200 with an empty answers object abstains"; fi

reset; jq -nc '{model:"x",answers:{leading_imperative:{type:"noul",noul:"very likely"}}}' > "$ANSWERS"
if tk_form_b_judge 'Investigate the N+1' 'Investigate' >/dev/null; then
  bad "a non-numeric noul must abstain"; else ok "non-numeric noul abstains"; fi

reset; noul 0.99
if tk_form_b_judge '' 'Investigate' >/dev/null; then bad "empty title must abstain"; else ok "empty title abstains"; fi
if tk_form_b_judge 'Investigate x' '' >/dev/null; then bad "empty word must abstain"; else ok "empty leading word abstains"; fi
eq "no request made for an unanswerable call" "0" "$(calls)"

echo "== what is on the wire =="
reset; noul 0.9
LBL="$TMP/labels"; printf '%s\n' bug 'needs triage' > "$LBL"
tk_form_b_judge 'Research service returns 500' 'Research' "$LBL" >/dev/null
eq "exactly one request per judgment" "1" "$(calls)"
if grep -q 'sk-test-abc123' "$CURL_ARGV"; then bad "API KEY LEAKED INTO argv"; else ok "the key is never in argv"; fi
if grep -q 'sk-test-abc123' "$CURL_STDIN"; then ok "the key goes via --config on stdin"; else bad "the key should be on stdin"; fi
eq "title is sent"        "Research service returns 500" "$(jq -r '.state.title' "$CURL_BODY")"
eq "leading word is sent" "Research"                     "$(jq -r '.state.leading_word' "$CURL_BODY")"
eq "labels are sent"      "bug,needs triage"             "$(jq -r '.state.labels | join(",")' "$CURL_BODY")"
eq "tracker is sent"      "github"                       "$(jq -r '.state.tracker' "$CURL_BODY")"
if jq -e '.state | has("body")' "$CURL_BODY" >/dev/null 2>&1; then
  bad "THE ISSUE BODY MUST NEVER BE SENT"; else ok "the issue body is never sent"; fi
eq "exactly one question is asked" "1" "$(jq -r '.questions | keys | length' "$CURL_BODY")"
eq "and it is the Form B one"      "leading_imperative" "$(jq -r '.questions | keys[0]' "$CURL_BODY")"
eq "it is a noul"                  "noul" "$(jq -r '.questions.leading_imperative.type' "$CURL_BODY")"

echo "== a title with no labels file still asks =="
reset; noul 0.9
p="$(tk_form_b_judge 'Investigate the N+1' 'Investigate')"
eq "no labels file is fine" "0.9" "$p"
eq "labels default to []"   "0"   "$(jq -r '.state.labels | length' "$CURL_BODY")"

echo "== the deterministic precondition still decides WHAT may be asked =="
# These pin the containment property from the caller's side: the judge is only ever reached when
# ticket_kind_classify emits needs_form_b=1 with a candidate word. A title settled by Form A, or
# one whose leading word is not configured, never becomes a request — so the trigger vocabulary
# stays closed under config no matter what the model would have said.
KW="$TMP/kw"; printf '%s\n' spike decision adr rfc investigate research compare > "$KW"
NOLBL="$TMP/none"; : > "$NOLBL"
fb() {
  ticket_kind_classify --tracker github --title "$1" --labels-file "$NOLBL" \
    --github-labels-file "$NOLBL" --title-keywords-file "$KW" | awk -F'\t' '{print $4"|"$5}'
}
eq "Form B candidate carries its word"      "1|Investigate" "$(fb 'Investigate why checkout 500s')"
eq "gerund candidate carries its real word" "1|Researching" "$(fb 'Researching the N+1 in the roster endpoint')"
eq "please is stripped, case-insensitively" "1|Compare"     "$(fb 'Please Compare Sidekiq and SQS')"
eq "Form A settles it, no judgment needed"  "0|"            "$(fb 'Spike: cache invalidation')"
eq "noun-only keyword is never a candidate" "0|"            "$(fb 'Spike handling is broken')"
eq "unconfigured leading word: no candidate" "0|"           "$(fb 'Fix the flaky roster test')"
eq "no stemming beyond the gerund"          "0|"            "$(fb 'Comparison of queue backends is wrong')"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
