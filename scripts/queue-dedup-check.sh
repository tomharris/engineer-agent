#!/bin/bash
# queue-dedup-check.sh — assert the queue's one-file-per (type, source_id) invariant.
#
# WHY THIS EXISTS: a duplicate queue item is invisible on disk. Queue filenames carry a fresh
# {YYYYMMDD-HHmmss} minted at write time, so a second copy of the same ticket never collides with
# the first — it just quietly sits alongside it, and the human sees the same work twice (or, worse,
# implements it twice). Two spec contradictions produced this in practice:
#
#   1. Unrouted re-check. An `_unrouted` item is deliberately kept out of seen_tickets so it gets
#      re-examined until assigned. On the poll that finally routes it, the poller wrote a NEW file
#      instead of updating the one already in incoming/.
#   2. Updated-since-last_checked re-queue. "Re-queue for updated context" fires for any ticket
#      touched since the last poll — including by engineer-agent itself. Recording findings as a
#      Jira comment bumps `updated`, which re-queues the ticket that was just completed. That loop
#      is self-sustaining: every cycle writes a comment, every comment earns another cycle.
#
# references/queue-reconciliation.md is the rule the pollers now follow. This script is the
# executable check on it — run it after a poll, or from CI, to catch a regression.
#
# Usage: queue-dedup-check.sh [-q]
#   -q   quiet: exit status only, no output
# Exit: 0 = invariant holds (or empty queue), 1 = duplicates found, 2 = usage/queue-missing error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "${SCRIPT_DIR}/lib-paths.sh"

QUIET=0
UPDATE_BASELINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet) QUIET=1; shift ;;
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "queue-dedup-check.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

QUEUE="${EA_AGENT_DIR}/queue"
if [ ! -d "$QUEUE" ]; then
  echo "queue-dedup-check.sh: no queue directory at $QUEUE" >&2
  exit 2
fi

# Terminal directories. An item here is DONE: the external action ran (or was explicitly declined),
# so nothing should ever re-draft it. A duplicate whose sibling is terminal is the more serious of
# the two shapes, and is reported as such.
is_terminal_dir() { case "$1" in completed|rejected) return 0 ;; *) return 1 ;; esac; }

# rejected/ is the DISPOSAL path, so it does not count toward the invariant.
#
# Rejecting the redundant copy is exactly how a human resolves a duplicate. If rejected items
# counted, every correctly-resolved duplicate would stay red forever — and a permanently-red check
# is one nobody reads, which would take the live-duplicate signal down with it. (This repo already
# has that scar: see cron-poll.sh on the sha256 fingerprint that false-warned on every quiet poll.)
#
# The cost is real and accepted: "a rejected item got re-drafted" is not detected, because on disk
# it is identical to "a duplicate was resolved by rejection" — one rejected file plus one live file,
# with timestamps unable to separate them. That case is already forbidden by
# queue-reconciliation.md's absorbing-terminal rule, and if it slips through the human sees a draft
# for something they declined and rejects it again. Visible and self-correcting; a dead check is not.
counts_toward_invariant() { [ "$1" != "rejected" ]; }

# Read one frontmatter scalar from the leading --- block. Tolerates quoted and bare values, stops
# at the closing delimiter so a body mention of `type:` cannot be picked up.
fm() {
  awk -v key="$2" '
    NR==1 && $0 ~ /^---[[:space:]]*$/ { inside=1; next }
    inside && $0 ~ /^---[[:space:]]*$/ { exit }
    inside {
      line=$0; sub(/^[ \t]+/,"",line)
      k=line; sub(/:.*/,"",k)
      if (k != key) next
      v=substr(line, index(line,":")+1); sub(/^[ \t]+/,"",v)
      if (substr(v,1,1)=="\"") { v=substr(v,2); q=index(v,"\""); if (q>0) v=substr(v,1,q-1) }
      else if (substr(v,1,1)=="\x27") { v=substr(v,2); q=index(v,"\x27"); if (q>0) v=substr(v,1,q-1) }
      else { sub(/[ \t]+#.*$/,"",v); sub(/[ \t]+$/,"",v) }
      print v; exit
    }
  ' "$1"
}

# Collect "type<TAB>source_id<TAB>dir/filename<TAB>dir" for every queue item.
rows=""
for dir in incoming drafts completed rejected; do
  [ -d "$QUEUE/$dir" ] || continue
  for f in "$QUEUE/$dir"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    # CLAUDE.md is repo instructions that live in the queue dirs, not a queue item.
    [ "$base" = "CLAUDE.md" ] && continue
    sid="$(fm "$f" source_id)"
    [ -n "$sid" ] || continue          # no source_id: not a trackable item, nothing to dedup on
    typ="$(fm "$f" type)"
    [ -n "$typ" ] || typ="(untyped)"
    if counts_toward_invariant "$dir"; then live=1; else live=0; fi
    rows="${rows}${typ}	${sid}	${dir}/${base}	${dir}	${live}
"
  done
done

if [ -z "$rows" ]; then
  say "queue-dedup-check: no queue items found; invariant holds trivially."
  exit 0
fi

# Group by (type, source_id). A single ticket legitimately appears under several TYPES — a `ticket`
# item and its later `qa-test-plan` share a source_id and are not duplicates — so the type is part
# of the key, not ignored.
# Only field 5 == 1 (a non-rejected item) is counted; rejected copies are context, not violations.
dup_keys="$(printf '%s' "$rows" | awk -F'\t' 'NF>=5 && $5==1 { c[$1"\t"$2]++ } END { for (k in c) if (c[k]>1) print k }' | sort)"

# --- Baseline ---------------------------------------------------------------------------------
# Pre-existing duplicates cannot always be cleaned. If a QA plan really was completed three times,
# all three completions are TRUE, and rejecting two of them to make this check green would falsify
# the record. But leaving them red forever kills the check (see the crying-wolf note above). So
# known-historical pairs are baselined — and the suppression is always reported, never silent, so a
# stale baseline cannot quietly hide a live regression.
#
# Format: one "type<TAB>source_id" per line. `#` comments and blank lines ignored.
BASELINE_FILE="${EA_AGENT_DIR}/state/queue-dedup-baseline.tsv"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
  mkdir -p "$(dirname "$BASELINE_FILE")"
  {
    echo "# queue-dedup-check baseline — known duplicate (type, source_id) pairs to suppress."
    echo "# Written by: queue-dedup-check.sh --update-baseline on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# These are historical duplicates that cannot be cleaned without falsifying the record."
    echo "# A pair listed here is NOT checked. Remove a line to re-enable checking for it."
    printf '%s\n' "$dup_keys"
  } > "$BASELINE_FILE"
  n="$(printf '%s' "$dup_keys" | grep -c . || true)"
  say "queue-dedup-check: baseline updated — ${n} pair(s) recorded in ${BASELINE_FILE#"$EA_AGENT_DIR"/}."
  exit 0
fi

suppressed=0
if [ -f "$BASELINE_FILE" ] && [ -n "$dup_keys" ]; then
  remaining=""
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    # Exact whole-line match against the baseline, comments stripped.
    if grep -v '^[[:space:]]*#' "$BASELINE_FILE" 2>/dev/null | grep -Fqx -- "$key"; then
      suppressed=$((suppressed + 1))
    else
      remaining="${remaining}${key}
"
    fi
  done <<EOF
$dup_keys
EOF
  dup_keys="$(printf '%s' "$remaining" | sed '/^$/d')"
fi

suppressed_note=""
if [ "$suppressed" -gt 0 ]; then
  suppressed_note=" (${suppressed} baselined pair(s) suppressed — see ${BASELINE_FILE#"$EA_AGENT_DIR"/})"
fi

if [ -z "$dup_keys" ]; then
  total="$(printf '%s' "$rows" | grep -c . || true)"
  say "queue-dedup-check: ok — ${total} item(s), no duplicate (type, source_id).${suppressed_note}"
  exit 0
fi

count=0
say "queue-dedup-check: FAILED — duplicate queue items found."
say ""
while IFS="$(printf '\t')" read -r typ sid; do
  [ -n "$sid" ] || continue
  count=$((count + 1))
  say "  ${sid}  (type: ${typ})"
  terminal_hit=""
  while IFS="$(printf '\t')" read -r rtyp rsid rpath rdir rlive; do
    [ "$rtyp" = "$typ" ] && [ "$rsid" = "$sid" ] || continue
    if [ "$rlive" != "1" ]; then
      say "    - ${rpath}   (rejected — not counted)"
    elif is_terminal_dir "$rdir"; then
      say "    - ${rpath}   <- already terminal (${rdir})"
      terminal_hit="$rdir"
    else
      say "    - ${rpath}"
    fi
  done <<EOF
$(printf '%s' "$rows")
EOF
  if [ -n "$terminal_hit" ]; then
    say "    => a ${terminal_hit} item was re-queued. Terminal state must be absorbing:"
    say "       the poller should have skipped this source_id outright."
  else
    say "    => same item queued twice without reconciliation. The poller should have"
    say "       updated the existing file in place rather than minting a new one."
  fi
  say ""
done <<EOF
$dup_keys
EOF

say "${count} duplicated source_id(s).${suppressed_note} See references/queue-reconciliation.md for"
say "the rule. Resolve a LIVE duplicate by rejecting the redundant copy (keep the one a human has"
say "acted on). For an immutable historical duplicate — where the work genuinely ran more than once"
say "and every record is true — baseline it instead: queue-dedup-check.sh --update-baseline."
exit 1
