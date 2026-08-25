#!/bin/bash
# Tests for scripts/poll-slite.sh — the deterministic Slite collector.
#
# `curl` is stubbed on PATH so no network is touched and every response shape is chosen here.
#
# The headline case is ROUTING. skills/poll-slite/SKILL.md iterates per project and queues a
# matching doc for each, which in a real config is a live bug and not a hypothetical: all six
# projects set doc_labels: ["needs-review"], so every review doc matches every project and the
# global source_id dedup silently awards it to whichever project the loop reached first. This
# collector gathers docs once and routes them, so the ambiguous case becomes a visible `_unrouted`
# item that review-queue can resolve — the same outcome every other source already gives.
#
# The other properties pinned: terminal state is absorbing (posting review comments UPDATES the
# doc, so without this the doc just reviewed reappears every poll), the recency cutoff, and clean
# degradation to the model on a missing key or an unrecognised response shape.
#
# Run: bash tests/poll-slite.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLL="${REPO_ROOT}/scripts/poll-slite.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (poll-slite.sh degrades to the model without it)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state" "$TMP/bin" "$TMP/notes"
export PATH="$TMP/bin:$PATH"

export SEARCH_JSON="$TMP/search.json"
export NOTES_DIR="$TMP/notes"
export SEARCH_CODE="$TMP/search.code"; echo 200 > "$SEARCH_CODE"
export CURL_ARGV="$TMP/curl.argv"
export CURL_STDIN="$TMP/curl.stdin"

cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; esac
  case "$a" in https://*) url="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$*" >> "$CURL_ARGV"
cat >> "$CURL_STDIN"
code=200
case "$url" in
  *"/search-notes"*) cat "$SEARCH_JSON" > "$out"; code="$(cat "$SEARCH_CODE")" ;;
  *"/notes/"*)
    id="${url##*/notes/}"
    if [ -f "$NOTES_DIR/$id.json" ]; then cat "$NOTES_DIR/$id.json" > "$out"; else echo '{}' > "$out"; code=404; fi ;;
  *) echo '{}' > "$out"; code=404 ;;
esac
printf '%s' "$code"
EOF
chmod +x "$TMP/bin/curl"

write_config() {   # one project watching "needs-review"
  cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  slite:
    api_key_env: "EA_TEST_SLITE_KEY"
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "none"
    slite:
      doc_labels: ["needs-review"]
YAML
}

write_shared_config() {   # the real-config shape: two projects, same label
  cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  slite:
    api_key_env: "EA_TEST_SLITE_KEY"
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "none"
    slite:
      doc_labels: ["needs-review"]
  beta:
    path: "/tmp/beta"
    tracker: "none"
    slite:
      doc_labels: ["needs-review"]
YAML
}

# note <id> <title> [tags-json] [updatedAt]
note() {
  jq -nc --arg i "$1" --arg t "$2" --argjson g "${3:-null}" --arg u "${4:-2026-08-20T10:00:00Z}" \
    '{id:$i, title:$t, url:("https://slite/"+$i), updatedAt:$u,
      author:{displayName:"Ann"}, content:"# Design\nSome content."}
     + (if $g == null then {} else {tags:$g} end)' > "$NOTES_DIR/$1.json"
}
set_hits() { jq -nc --argjson a "$1" '{hits:$a}' > "$SEARCH_JSON"; }

reset() {
  rm -f "$EA_AGENT_DIR"/queue/*/*.md "$EA_AGENT_DIR/state/last-poll.yaml" "$CURL_ARGV" "$CURL_STDIN" "$NOTES_DIR"/*.json
  : > "$TMP/manifest"; echo 200 > "$SEARCH_CODE"; set_hits '[]'
}
run()  { EA_TEST_SLITE_KEY="key" bash "$POLL" --manifest "$TMP/manifest" "$@" 2>"$TMP/err"; }
item() { ls "$EA_AGENT_DIR/queue/incoming/"*"$1"* 2>/dev/null | head -1; }

echo "== degradation =="
write_config; reset
set_hits '[{"id":"n1"}]'; note n1 "A design doc"
EA_TEST_SLITE_KEY="" bash "$POLL" --manifest "$TMP/manifest" >/dev/null 2>&1
eq "no key => exit 3 (leave it to the model)" "3" "$?"
if [ -z "$(ls -A "$EA_AGENT_DIR/queue/incoming" 2>/dev/null)" ]; then ok "no items written"; else bad "must not write without a key"; fi

write_config; reset
# An unrecognisable envelope must NOT be read as "zero docs need review" — that is indistinguishable
# from a quiet week and would go unnoticed indefinitely.
echo '{"unexpected":"shape"}' > "$SEARCH_JSON"
run >/dev/null
eq "unknown response shape => exit 3" "3" "$?"

echo "== the API key never appears in argv =="
write_config; reset
set_hits '[{"id":"n1"}]'; note n1 "A design doc"
run >/dev/null
if grep -q 'key' "$CURL_ARGV" && grep -qE 'x-slite-api-key: key' "$CURL_ARGV"; then bad "API key leaked into argv"; else ok "key absent from argv"; fi
if grep -q 'x-slite-api-key: key' "$CURL_STDIN"; then ok "key passed on stdin"; else bad "key should go via --config -"; fi

echo "== a routed doc is written with the doc-review shape =="
write_config; reset
set_hits '[{"id":"n7"}]'; note n7 "Payments design"
run >/dev/null
I="$(item n7)"
if [ -n "$I" ]; then ok "queue item created"; else bad "no queue item"; fi
eq "type"      "doc-review"  "$(grep -m1 '^type:' "$I" | sed 's/^type: *//')"
eq "source"    "slite"       "$(grep -m1 '^source:' "$I" | sed 's/^source: *//')"
# The "slite:" prefix is load-bearing: CLAUDE.md gives that form as the one the spec -> design-doc
# -> ticket-plan prior-artifact lookups chain on, so a bare id breaks those joins while looking fine.
eq "source_id is prefixed" "slite:n7" "$(grep -m1 '^source_id:' "$I" | sed 's/^source_id: *"\(.*\)"/\1/')"
eq "project"   "alpha"       "$(grep -m1 '^project:' "$I" | sed 's/^project: *"\(.*\)"/\1/')"
eq "doc_id"    "n7"          "$(grep -m1 '^doc_id:' "$I" | sed 's/^doc_id: *"\(.*\)"/\1/')"
if grep -q 'Some content.' "$I"; then ok "document body inlined"; else bad "body missing"; fi
if grep -q '^## Draft Response' "$I"; then bad "collector must not draft"; else ok "no draft written (correct split)"; fi

echo "== label_source records how the match was established =="
write_config; reset
set_hits '[{"id":"n8"}]'; note n8 "Untagged doc"          # no tags field at all
run >/dev/null
eq "no tag field => matched on the query" "query" "$(grep -m1 '^label_source:' "$(item n8)" | sed 's/^label_source: *"\(.*\)"/\1/')"

write_config; reset
set_hits '[{"id":"n9"}]'; note n9 "Tagged doc" '["needs-review"]'
run >/dev/null
eq "real tag comparison is recorded as such" "tags" "$(grep -m1 '^label_source:' "$(item n9)" | sed 's/^label_source: *"\(.*\)"/\1/')"

echo "== shared doc_labels: the per-project loop bug =="
write_shared_config; reset
set_hits '[{"id":"n10"}]'; note n10 "Shared doc" '["needs-review"]'
run >/dev/null
N="$(ls "$EA_AGENT_DIR/queue/incoming/"*n10* 2>/dev/null | wc -l | tr -d ' ')"
eq "the doc is queued exactly ONCE" "1" "$N"
I="$(item n10)"
eq "and is _unrouted rather than arbitrarily assigned" "_unrouted" "$(grep -m1 '^project:' "$I" | sed 's/^project: *"\(.*\)"/\1/')"
if grep -q '^matched_projects: \["alpha", "beta"\]' "$I"; then ok "both candidates recorded for the human"; else bad "matched_projects missing: $(grep '^matched_projects' "$I")"; fi
# Tier 3b is opt-in: with no candidate carrying a routing block the ladder stops at Tier 4 and does
# NOT ask a model to guess, which is what keeps installs that never add hints behaving as before.
eq "no routing hints => no inference requested" "0" "$(awk -F'\t' '/n10/ {print $6}' "$TMP/manifest")"

# Add a hint to one candidate and Tier 3b becomes reachable, so the model is asked to resolve it.
cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  slite:
    api_key_env: "EA_TEST_SLITE_KEY"
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "none"
    routing:
      description: >-
        Payments and treasury flows.
    slite:
      doc_labels: ["needs-review"]
  beta:
    path: "/tmp/beta"
    tracker: "none"
    slite:
      doc_labels: ["needs-review"]
YAML
reset
set_hits '[{"id":"n10b"}]'; note n10b "Shared doc" '["needs-review"]'
run >/dev/null
eq "a routing hint makes Tier 3b reachable" "1" "$(awk -F'\t' '/n10b/ {print $6}' "$TMP/manifest")"

echo "== one search per distinct label, and docs deduplicated across them =="
cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  slite:
    api_key_env: "EA_TEST_SLITE_KEY"
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "none"
    slite:
      doc_labels: ["needs-review", "design"]
YAML
reset
set_hits '[{"id":"n11"}]'; note n11 "Doc in both searches" '["needs-review","design"]'
run >/dev/null
eq "two labels => two searches" "2" "$(grep -c 'search-notes' "$CURL_ARGV")"
eq "the doc is still queued once" "1" "$(ls "$EA_AGENT_DIR/queue/incoming/"*n11* 2>/dev/null | wc -l | tr -d ' ')"

echo "== terminal state is absorbing =="
write_config; reset
set_hits '[{"id":"n12"}]'; note n12 "Reviewed already"
run >/dev/null
mv "$(item n12)" "$EA_AGENT_DIR/queue/completed/"
# Posting review comments back to the doc bumps updatedAt, so the doc reappears in the window.
note n12 "Reviewed already" 'null' "2026-09-01T10:00:00Z"
run > "$TMP/out"
if [ -z "$(ls -A "$EA_AGENT_DIR/queue/incoming" 2>/dev/null)" ]; then ok "completed doc not re-queued"; else bad "re-queued a completed doc"; fi
if grep -q 'Skipped (terminal): slite:n12' "$TMP/out"; then ok "skip is reported, not hidden as 0 new"; else bad "skipped ids must be reported"; fi

echo "== recency cutoff =="
write_config; reset
set_hits '[{"id":"n13"}]'; note n13 "Old doc" 'null' "2026-08-01T00:00:00Z"
cat > "$EA_AGENT_DIR/state/last-poll.yaml" <<'YAML'
projects:
  alpha:
    slite:
      last_checked: "2026-08-15T00:00:00Z"
YAML
run >/dev/null
if [ -z "$(ls -A "$EA_AGENT_DIR/queue/incoming" 2>/dev/null)" ]; then ok "a doc older than the cutoff is skipped"; else bad "recency filter did not apply"; fi
if grep -q '2026' "$EA_AGENT_DIR/state/last-poll.yaml"; then ok "cutoff advances on a zero-doc poll"; else bad "cutoff must advance even when nothing was found"; fi

echo "== resume sweep =="
write_config; reset
set_hits '[{"id":"n14"}]'; note n14 "Stranded"
run >/dev/null
: > "$TMP/manifest"; set_hits '[]'
run >/dev/null
if grep -q "^resume	.*slite:n14" "$TMP/manifest"; then ok "stranded item re-emitted (self-healing)"; else bad "an undrafted incoming/ item is invisible to every approval path"; fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
