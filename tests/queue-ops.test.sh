#!/bin/bash
# Tests for scripts/queue-status.sh and scripts/queue-list.sh.
#
# Both replace work commands/status.md and commands/review-queue.md currently ask a model to do by
# hand. Two behaviours are worth pinning because the specs have to WARN about them in prose:
#
#   - EXACT type matching. review-queue.md says "Match filters against the frontmatter type
#     exactly, never as a prefix", because `--type ticket` must not sweep up ticket-plan,
#     ticket-refinement or ticket-investigation.
#   - The receipt reading rules: status ok + items_queued 0 is HEALTHY, and a non-empty `skipped:`
#     list is NORMAL and must never be reported as a problem. Getting this wrong turns every quiet
#     poll into a false alarm — the exact failure the sha256-fingerprint health check caused before
#     2501ecf replaced it.
#
# Run: bash tests/queue-ops.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATUS="${REPO_ROOT}/scripts/queue-status.sh"
LIST="${REPO_ROOT}/scripts/queue-list.sh"
TAB="$(printf '\t')"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state"

mk() { # mk <dir> <name> <type> <project> <priority> <created> [--drafted]
  local dir="$1" name="$2" typ="$3" proj="$4" prio="$5" created="$6" drafted="${7:-}"
  {
    echo "---"; echo "type: $typ"; echo "source: github"
    echo "source_id: \"acme/repo#${name%%-*}\""
    echo "title: \"title of $name\""; echo "priority: $prio"
    echo "created_at: \"$created\""; echo "status: incoming"; echo "project: \"$proj\""
    echo "---"; echo "## Context"
    [ "$drafted" = "--drafted" ] && { echo "## Draft Response"; echo "x"; }
  } > "$EA_AGENT_DIR/queue/$dir/$name"
}

mk drafts  "1-ticket.md"              ticket               alpha "normal" "2026-01-03T00:00:00Z" --drafted
mk drafts  "2-ticket.md"              ticket               alpha "urgent" "2026-01-04T00:00:00Z" --drafted
mk drafts  "3-ticket.md"              ticket               beta  "low"    "2026-01-01T00:00:00Z" --drafted
mk drafts  "4-ticket-plan.md"         ticket-plan          alpha "normal" "2026-01-02T00:00:00Z" --drafted
mk drafts  "5-ticket-investigation.md" ticket-investigation alpha "normal" "2026-01-05T00:00:00Z" --drafted
mk drafts  "6-pr-review.md"           pr-review            beta  "normal" "2026-01-06T00:00:00Z" --drafted
mk incoming "7-ticket.md"             ticket               _unrouted "normal" "2026-01-07T00:00:00Z" --drafted
mk incoming "8-ticket.md"             ticket               alpha "normal" "2026-01-08T00:00:00Z"   # stranded: no draft
mk completed "9-ticket.md"            ticket               alpha "normal" "2026-01-09T00:00:00Z" --drafted

echo "== queue-list: EXACT type filter (review-queue.md's stated trap) =="
eq "--type ticket matches only ticket" "ticket ticket ticket ticket" \
   "$("$LIST" --type ticket --tsv | cut -f5 | sort | tr '\n' ' ' | sed 's/ $//')"
eq "ticket-plan is its own type"        "ticket-plan" \
   "$("$LIST" --type ticket-plan --tsv | cut -f5 | tr '\n' ' ' | sed 's/ $//')"
eq "ticket-investigation is its own"    "ticket-investigation" \
   "$("$LIST" --type ticket-investigation --tsv | cut -f5 | tr '\n' ' ' | sed 's/ $//')"

echo "== queue-list: project filter =="
eq "--project beta" "3-ticket.md 6-pr-review.md" \
   "$("$LIST" --project beta --tsv | cut -f4 | sort | tr '\n' ' ' | sed 's/ $//')"
eq "filters combine" "3-ticket.md" \
   "$("$LIST" --project beta --type ticket --tsv | cut -f4 | tr '\n' ' ' | sed 's/ $//')"

echo "== queue-list: sort order (unrouted, then priority, then created_at asc) =="
# 7 is unrouted so it leads; then urgent (2); then the three normals oldest-first (4, 1, 5, 6);
# then low (3) last.
eq "full order" "7-ticket.md 2-ticket.md 4-ticket-plan.md 1-ticket.md 5-ticket-investigation.md 6-pr-review.md 3-ticket.md" \
   "$("$LIST" --tsv | cut -f4 | tr '\n' ' ' | sed 's/ $//')"
TABLE="$("$LIST")"
if printf '%s' "$TABLE" | head -4 | grep -q '_unrouted'; then ok "unrouted is surfaced first in the table"; else bad "unrouted must lead"; fi

echo "== queue-list: only drafts/ and unrouted incoming/ are reachable =="
# A resolved incoming/ item is NOT awaiting review, and a completed one is done.
FILES="$("$LIST" --tsv | cut -f4)"
if printf '%s' "$FILES" | grep -q '^8-ticket.md$'; then bad "resolved incoming/ must not be listed"; else ok "resolved incoming/ excluded"; fi
if printf '%s' "$FILES" | grep -q '^9-ticket.md$'; then bad "completed/ must not be listed"; else ok "completed/ excluded"; fi

echo "== queue-list: empty queue =="
mkdir -p "$TMP/empty/queue"/{incoming,drafts,completed,rejected}
eq "empty message" "Queue is empty — nothing awaiting review." "$(EA_AGENT_DIR="$TMP/empty" "$LIST")"
eq "empty tsv is silent" "" "$(EA_AGENT_DIR="$TMP/empty" "$LIST" --tsv)"

echo "== queue-status: counts =="
J="$("$STATUS" --json)"
jget() { printf '%s' "$J" | sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p"; }
eq "drafts count"   "6" "$(jget drafts)"
eq "incoming count" "2" "$(jget incoming)"
eq "completed"      "1" "$(jget completed)"
eq "unrouted"       "1" "$(jget unrouted)"
# The stranded count exists because a scripted collector can now leave an item in incoming/ that no
# approval path can see. status.md has no equivalent today.
eq "stranded"       "1" "$(jget stranded)"
SOUT="$("$STATUS")"
if printf '%s' "$SOUT" | grep -q 'WARNING: 1 item'; then ok "stranded item is surfaced as a warning"; else bad "stranded item must warn"; fi

echo "== queue-status: receipt interpretation =="
cat > "$EA_AGENT_DIR/state/last-poll-receipt.yaml" <<'EOF'
run_id: "20260825T150000Z-1"
finished_at: "2026-08-25T15:00:00Z"
status: ok
items_queued: 0
sources_polled:
  - alpha/github
skipped:
  - "alpha/jira: tracker is github-issues, no jira section"
  - "alpha/slite: no slite section configured"
errors: []
EOF
OUT="$("$STATUS")"
if printf '%s' "$OUT" | grep -q 'status=ok, items_queued=0'; then ok "ok + 0 items reported plainly"; else bad "receipt line wrong"; fi
if printf '%s' "$OUT" | grep -q '2 source(s) skipped'; then ok "skipped counted"; else bad "skipped count wrong"; fi
# A quiet, fully-successful poll must produce NO problem line. This is the false-alarm failure mode.
if printf '%s' "$OUT" | grep -q 'PROBLEM'; then bad "a healthy quiet poll must not report a PROBLEM"; else ok "healthy quiet poll is silent"; fi

cat > "$EA_AGENT_DIR/state/last-poll-receipt.yaml" <<'EOF'
run_id: "x"
finished_at: "2026-08-25T15:00:00Z"
status: partial
items_queued: 0
sources_polled: []
skipped: []
errors:
  - "alpha/github: gh auth failed"
EOF
OUT="$("$STATUS")"
if printf '%s' "$OUT" | grep -q 'PROBLEM: 1 configured source'; then ok "errors surfaced"; else bad "errors must be surfaced"; fi
if printf '%s' "$OUT" | grep -q 'gh auth failed'; then ok "error text inlined"; else bad "error text must be shown"; fi
if printf '%s' "$OUT" | grep -q 'PROBLEM: poll status is partial'; then ok "partial status flagged"; else bad "partial must be flagged"; fi
eq "json errors count" "1" "$("$STATUS" --json | sed -n 's/.*"errors":\([0-9]*\).*/\1/p')"

echo "== queue-status: no receipt at all =="
rm -f "$EA_AGENT_DIR/state/last-poll-receipt.yaml"
SOUT="$("$STATUS")"
if printf '%s' "$SOUT" | grep -q 'No receipt'; then ok "missing receipt reported"; else bad "missing receipt must be reported"; fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
