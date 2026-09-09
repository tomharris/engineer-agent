#!/bin/bash
# Tests for scripts/queue-heal-stranded.sh — moving finished drafts out of incoming/.
#
# The bug being pinned: only drafts/ is reachable by the approval gate, so an item in incoming/
# with a complete "## Draft Response" is finished work that neither the terminal nor the ntfy
# approval path can see, and each fails silently. Five real code-audit-finding items sat that way
# for eight weeks while `status` reported stranded:0.
#
# Run: bash tests/queue-heal-stranded.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEAL="bash ${REPO_ROOT}/scripts/queue-heal-stranded.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected}

# mkitem <dir> <name> <project> [--drafted]
mkitem() {
  local dir="$1" name="$2" proj="$3" drafted="${4:-}"
  {
    echo "---"
    echo "type: code-audit-finding"
    echo "source: audit"
    echo "source_id: \"src/${name}.php:1-2\""
    echo "title: \"a finding\""
    echo "project: \"$proj\""
    echo "status: incoming"
    echo "---"
    echo "## Context"
    echo "Body prose that legitimately says status: incoming and must NOT be rewritten."
    [ "$drafted" = "--drafted" ] && { echo "## Draft Response"; echo "the finished draft"; }
  } > "$EA_AGENT_DIR/queue/$dir/$name"
}

echo "== report mode =="
mkitem incoming stranded-a.md alpha --drafted
mkitem incoming stranded-b.md alpha --drafted
mkitem incoming undrafted.md  alpha            # needs the model, not a move
mkitem incoming unrouted.md   _unrouted --drafted   # reachable via review-queue; leave parked
OUT="$($HEAL 2>&1)"; RC=$?
eq "report exits 1 when items are stranded" "1" "$RC"
eq "report names both stranded items" "2" "$(printf '%s\n' "$OUT" | grep -c 'stranded-[ab].md')"
eq "report ignores the undrafted item" "0" "$(printf '%s\n' "$OUT" | grep -c 'undrafted.md')"
eq "report ignores the _unrouted item" "0" "$(printf '%s\n' "$OUT" | grep -c 'unrouted.md')"
# Report mode must never write to the queue — it is what /engineer-agent status calls.
eq "report moved nothing" "4" "$(ls -1 "$EA_AGENT_DIR/queue/incoming" | wc -l | tr -d ' ')"

echo "== heal mode =="
OUT="$($HEAL --heal 2>&1)"; RC=$?
eq "heal exits 0"                    "0"   "$RC"
eq "both stranded items left incoming/" "2" "$(ls -1 "$EA_AGENT_DIR/queue/incoming" | wc -l | tr -d ' ')"
if [ -f "$EA_AGENT_DIR/queue/drafts/stranded-a.md" ] && [ -f "$EA_AGENT_DIR/queue/drafts/stranded-b.md" ]; then
  ok "both landed in drafts/"
else
  bad "items did not land in drafts/"
fi
if [ -f "$EA_AGENT_DIR/queue/incoming/undrafted.md" ] && [ -f "$EA_AGENT_DIR/queue/incoming/unrouted.md" ]; then
  ok "undrafted and _unrouted items left alone"
else
  bad "heal touched an item it should not have"
fi

echo "== status rewritten, body untouched =="
D="$EA_AGENT_DIR/queue/drafts/stranded-a.md"
eq "frontmatter status is drafted" "drafted" "$(sed -n 's/^status: *//p' "$D" | head -1)"
# The whole point of rewriting only the FIRST match: audit-finding bodies are prose.
eq "body prose not rewritten" "1" "$(grep -c 'legitimately says status: incoming' "$D")"
eq "draft section survived"   "1" "$(grep -c '^## Draft Response' "$D")"
eq "no temp file left behind" "0" "$(ls -1 "$EA_AGENT_DIR/queue/incoming" | grep -c '\.heal\.' || true)"

echo "== idempotence and the duplicate guard =="
OUT="$($HEAL --heal 2>&1)"; RC=$?
eq "second heal is a no-op, exit 0" "0" "$RC"
eq "second heal reports nothing stranded" "1" "$(printf '%s\n' "$OUT" | grep -c 'nothing stranded')"
# A same-named file already in drafts/ is the DUPLICATE problem, owned by queue-dedup-check.sh.
# Moving on top of it would destroy whichever copy a human might be reviewing.
mkitem incoming stranded-a.md alpha --drafted
OUT="$($HEAL --heal 2>&1)"; RC=$?
eq "collision does not overwrite drafts/" "1" "$RC"
eq "collision is reported as a skip" "1" "$(printf '%s\n' "$OUT" | grep -c 'SKIP stranded-a.md')"
eq "the drafts/ copy still says drafted" "drafted" "$(sed -n 's/^status: *//p' "$D" | head -1)"
if [ -f "$EA_AGENT_DIR/queue/incoming/stranded-a.md" ]; then
  ok "the colliding copy stays in incoming/ for dedup to resolve"
else
  bad "the colliding copy was consumed"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
