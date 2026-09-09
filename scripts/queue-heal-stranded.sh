#!/bin/bash
# queue-heal-stranded.sh — move finished drafts out of incoming/, where nothing can approve them.
#
# WHY THIS EXISTS: only `drafts/` is reachable by the approval gate. `review-queue` lists `drafts/`
# (plus `_unrouted` items in `incoming/`) and `execute-item` acts only on `drafts/`, treating
# anything else as an idempotent no-op. So an item sitting in `incoming/` with a complete
# `## Draft Response` is finished work that BOTH approval paths — terminal and ntfy — are blind to,
# and each fails silently. CLAUDE.md names this exact shape as a hazard.
#
# It was nonetheless the one shape nothing detected. `poll_resume_candidates()` (lib-queue.sh) tests
# for a MISSING draft, because it was written for the scripted-poller crash: Phase A writes the item,
# Phase B dies before drafting. Its condition is therefore the complement of the invariant it cites,
# and `/engineer-agent status` reported `stranded: 0` while five verified `code-audit-finding` items
# — a cross-client authorization hole among them — sat unreachable in `incoming/` for eight weeks.
# They were written by a pre-e218f1c `audit-code` that had not yet learned to skip `incoming/`; the
# producer bug was fixed the next day, but nothing existed to heal what it had already left behind,
# because the reconciliation table correctly says a resolved `incoming/` item is "leave alone".
#
# The remedy is mechanical, which is why this heals rather than merely warns: the item's draft is
# already written and already human-reviewable, so there is no judgement to make and nothing for a
# model to do — the file is in the wrong directory. Contrast `queue-dedup-check.sh --heal`, which
# must refuse two shapes because it cannot know which of two drafts a human is mid-review on.
#
# Usage: queue-heal-stranded.sh [-q] [--heal]
#   -q       quiet: exit status only, no output
#   --heal   perform the move. Without it this only reports; it never writes to the queue.
# Exit: 0 = nothing stranded (or everything healed), 1 = stranded items remain, 2 = usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
source "${SCRIPT_DIR}/lib-paths.sh"
# shellcheck source=lib-queue.sh
source "${SCRIPT_DIR}/lib-queue.sh"

QUIET=0
HEAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    -q) QUIET=1; shift ;;
    --heal) HEAL=1; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "queue-heal-stranded.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

[ -d "${EA_AGENT_DIR}/queue/incoming" ] || {
  echo "queue-heal-stranded.sh: no queue at ${EA_AGENT_DIR}/queue" >&2
  exit 2
}

STRANDED="$(poll_stranded_drafted)"
[ -n "$STRANDED" ] || { say "queue-heal-stranded: nothing stranded"; exit 0; }

if [ "$HEAL" -eq 0 ]; then
  say "queue-heal-stranded: $(printf '%s\n' "$STRANDED" | grep -c .) item(s) stranded in incoming/ with a finished draft:"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    say "  $(basename "$f")  [$(fm "$f" type)] $(fm "$f" title)"
  done <<EOF
$STRANDED
EOF
  say "Run with --heal to move them to drafts/ where the approval gate can see them."
  exit 1
fi

HEALED=0
LEFT=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  dest="${EA_AGENT_DIR}/queue/drafts/${base}"
  # A same-basename file already in drafts/ means there are two copies of this work. That is the
  # duplicate problem, not this one, and queue-dedup-check.sh owns it — moving on top would
  # destroy whichever copy a human may be reviewing.
  if [ -e "$dest" ]; then
    say "  SKIP ${base}: a file of that name is already in drafts/ (see queue-dedup-check.sh)"
    LEFT=$((LEFT+1))
    continue
  fi
  # Set status to match the directory before moving, so the two never disagree on disk. Only the
  # FIRST `status:` line is rewritten — that one is always the frontmatter's, since frontmatter
  # precedes the body, and audit-finding bodies are prose that may well contain the word again.
  # The temp file gets a non-.md suffix so queue_items() cannot see it mid-heal.
  tmp="${f}.heal.$$"
  if awk 'BEGIN{d=0} /^status:[[:space:]]*/ && !d { print "status: drafted"; d=1; next } {print}' \
       "$f" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ] && mv "$tmp" "$dest"; then
    rm -f "$f"
    say "  healed ${base}: incoming/ -> drafts/ (status: drafted)"
    HEALED=$((HEALED+1))
  else
    rm -f "$tmp"
    say "  FAILED ${base}: could not move to drafts/"
    LEFT=$((LEFT+1))
  fi
done <<EOF
$STRANDED
EOF

say "queue-heal-stranded: healed ${HEALED}, unresolved ${LEFT}"
[ "$LEFT" -eq 0 ] || exit 1
exit 0
