#!/bin/bash
# Tests for scripts/lib-queue.sh — frontmatter access and the reconciliation lookup that the
# scripted pollers use to decide create / skip / update-in-place / unchanged.
#
# Background: references/queue-reconciliation.md states the invariant ("at most one queue file per
# (type, source_id)") and a five-row decision table that, until now, only a model followed by hand
# on each poll. Moving polling into scripts makes that table executable — and makes these branches
# worth pinning, because every one of them is a silent failure when wrong:
#
#   - a missed "skip" re-queues finished work, and since engineer-agent's own findings comment bumps
#     the ticket's `updated`, that loop is self-sustaining (the bug 14f0976 fixed).
#   - a missed "update" mints a rival file rather than resolving the _unrouted one, and because
#     filenames carry a fresh timestamp the duplicate never collides on disk — it just sits there.
#   - a missed resume candidate strands an item in incoming/, where NEITHER approval path can see it
#     (CLAUDE.md: "Only drafts/ is reachable by the approval gate").
#
# Run: bash tests/lib-queue.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected}

# shellcheck source=../scripts/lib-queue.sh
source "${REPO_ROOT}/scripts/lib-queue.sh"

# mkitem <dir> <name> <type> <source_id> <project> [--drafted]
mkitem() {
  local dir="$1" name="$2" typ="$3" sid="$4" proj="$5" drafted="${6:-}"
  {
    echo "---"
    echo "type: $typ"
    echo "source: github"
    echo "source_id: \"$sid\""
    echo "title: \"a title with: a colon in it\""
    echo "project: \"$proj\""
    echo "status: incoming"
    echo "---"
    echo "## Context"
    echo "type: this line mentions type but is in the BODY and must be ignored"
    [ "$drafted" = "--drafted" ] && { echo "## Draft Response"; echo "some draft"; }
  } > "$EA_AGENT_DIR/queue/$dir/$name"
}

echo "== frontmatter =="
mkitem drafts 20260101-000000-ticket-gh-1.md ticket "acme/repo#1" alpha --drafted
F="$EA_AGENT_DIR/queue/drafts/20260101-000000-ticket-gh-1.md"
eq "fm type"           "ticket"       "$(fm "$F" type)"
eq "fm source_id"      "acme/repo#1"  "$(fm "$F" source_id)"
eq "fm value w/ colon" "a title with: a colon in it" "$(fm "$F" title)"
eq "fm absent key"     ""             "$(fm "$F" nope)"
# The body deliberately contains "type:" after the closing delimiter.
eq "fm stops at ---"   "ticket"       "$(fm "$F" type)"
eq "fm missing file"   ""             "$(fm "$TMP/nope.md" type)"

echo "== fm_set =="
fm_set "$F" status drafted
eq "fm_set replaces"   "drafted"      "$(fm "$F" status)"
eq "fm_set kept others" "ticket"      "$(fm "$F" type)"
fm_set "$F" priority urgent
eq "fm_set creates"    "urgent"       "$(fm "$F" priority)"
eq "body preserved"    "1"            "$(grep -c '^## Draft Response' "$F")"

echo "== has_section (drives the resume sweep) =="
if has_section "$F" "## Draft Response"; then ok "drafted item has section"; else bad "should have section"; fi
mkitem incoming 20260101-000001-ticket-gh-2.md ticket "acme/repo#2" alpha
G="$EA_AGENT_DIR/queue/incoming/20260101-000001-ticket-gh-2.md"
if has_section "$G" "## Draft Response"; then bad "undrafted item must NOT have section"; else ok "undrafted item lacks section"; fi

echo "== disposition: the five-row table =="
eq "nothing anywhere -> create"     "create"           "$(queue_disposition ticket 'acme/repo#404')"
eq "drafts/ -> unchanged"           "unchanged:$F"     "$(queue_disposition ticket 'acme/repo#1')"
eq "incoming/ + project -> unchanged" "unchanged:$G"   "$(queue_disposition ticket 'acme/repo#2')"

mkitem incoming 20260101-000002-ticket-gh-3.md ticket "acme/repo#3" _unrouted
U="$EA_AGENT_DIR/queue/incoming/20260101-000002-ticket-gh-3.md"
eq "incoming/ + _unrouted -> update" "update:$U"       "$(queue_disposition ticket 'acme/repo#3')"

mkitem completed 20260101-000003-ticket-gh-4.md ticket "acme/repo#4" alpha --drafted
eq "completed/ -> skip"             "skip"             "$(queue_disposition ticket 'acme/repo#4')"
mkitem rejected 20260101-000004-ticket-gh-5.md ticket "acme/repo#5" alpha --drafted
eq "rejected/ -> skip"              "skip"             "$(queue_disposition ticket 'acme/repo#5')"

echo "== the {ticket, ticket-investigation} family =="
# A kind can change between polls (issue type edited, title retitled). The poller lookup must be
# family-wide AND terminal-inclusive, or a retitled issue mints a rival item for finished work.
eq "investigation sees completed ticket"  "skip" "$(queue_disposition ticket-investigation 'acme/repo#4')"
eq "ticket sees rejected investigation"   "skip" "$(queue_disposition ticket 'acme/repo#5')"
mkitem drafts 20260101-000005-ticket-investigation-gh-6.md ticket-investigation "acme/repo#6" alpha --drafted
I6="$EA_AGENT_DIR/queue/drafts/20260101-000005-ticket-investigation-gh-6.md"
eq "ticket sees drafted investigation"    "unchanged:$I6" "$(queue_disposition ticket 'acme/repo#6')"
# Different families with the same source_id are NOT duplicates — a ticket and its later
# qa-test-plan legitimately coexist.
eq "different family is independent"      "create" "$(queue_disposition qa-test-plan 'acme/repo#1')"
eq "pr-review independent of ticket"      "create" "$(queue_disposition pr-review 'acme/repo#4')"

echo "== resume sweep =="
# Only #2 and #3 are in incoming/ without a draft; everything else is drafted or terminal.
RES="$(poll_resume_candidates | sed "s|$EA_AGENT_DIR/queue/incoming/||" | sort | tr '\n' ' ' | sed 's/ $//')"
eq "sweep finds stranded items" "20260101-000001-ticket-gh-2.md 20260101-000002-ticket-gh-3.md" "$RES"
# Once drafted, an item must drop out of the sweep — otherwise every poll re-drafts the backlog.
printf '## Draft Response\ndone\n' >> "$G"
RES2="$(poll_resume_candidates | sed "s|$EA_AGENT_DIR/queue/incoming/||" | sort | tr '\n' ' ' | sed 's/ $//')"
eq "drafted item leaves the sweep" "20260101-000002-ticket-gh-3.md" "$RES2"

echo "== enumeration hygiene =="
echo "# repo instructions, not a queue item" > "$EA_AGENT_DIR/queue/drafts/CLAUDE.md"
eq "CLAUDE.md is not an item" "0" "$(queue_items drafts | grep -c 'CLAUDE.md')"
eq "queue_items counts all"   "6" "$(queue_items | wc -l | tr -d ' ')"

echo "== predicates =="
if is_terminal_dir completed; then ok "completed terminal"; else bad "completed should be terminal"; fi
if is_terminal_dir rejected;  then ok "rejected terminal";  else bad "rejected should be terminal";  fi
if is_terminal_dir drafts;    then bad "drafts not terminal"; else ok "drafts not terminal"; fi
eq "family of ticket"        "ticket" "$(type_family ticket)"
eq "family of investigation" "ticket" "$(type_family ticket-investigation)"
# Exact match, never prefix: ticket-plan is its own type and must NOT join the ticket family.
eq "ticket-plan is its own"  "ticket-plan" "$(type_family ticket-plan)"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
