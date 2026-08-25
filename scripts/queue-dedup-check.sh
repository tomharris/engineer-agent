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
# is_terminal_dir / type_family / counts_toward_invariant / fm now live in lib-queue.sh so that
# THIS check and the scripted pollers that must uphold the invariant share one implementation
# rather than two. The rationale comments moved with them; see lib-queue.sh.
# shellcheck source=lib-queue.sh
. "${SCRIPT_DIR}/lib-queue.sh"

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
    fam="$(type_family "$typ")"
    rows="${rows}${typ}	${sid}	${dir}/${base}	${dir}	${live}	${fam}
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

# Family check — the reclassification duplicate the exact-type key above cannot see. Restricted to
# LIVE, NON-TERMINAL dirs (incoming/, drafts/) on purpose: two live items for one source_id across
# the {ticket, ticket-investigation} pair is always the poller failing to update in place, whereas a
# terminal item plus a live one of the other type is the legitimate spike -> implement handoff.
# Keys already reported by the exact check are excluded so a duplicate is never printed twice.
dup_fam_keys="$(printf '%s' "$rows" \
  | awk -F'\t' 'NF>=6 && $5==1 && $4!="completed" && $4!="rejected" { c[$6"\t"$2]++ } END { for (k in c) if (c[k]>1) print k }' \
  | sort)"
if [ -n "$dup_fam_keys" ] && [ -n "$dup_keys" ]; then
  remaining_fam=""
  while IFS= read -r fkey; do
    [ -n "$fkey" ] || continue
    printf '%s' "$dup_keys" | grep -Fqx -- "$fkey" || remaining_fam="${remaining_fam}${fkey}
"
  done <<EOF
$dup_fam_keys
EOF
  dup_fam_keys="$(printf '%s' "$remaining_fam" | sed '/^$/d')"
fi

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
    [ -n "$dup_fam_keys" ] && printf '%s\n' "$dup_fam_keys"
  } > "$BASELINE_FILE"
  n="$(printf '%s\n%s' "$dup_keys" "$dup_fam_keys" | grep -c . || true)"
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
if [ -f "$BASELINE_FILE" ] && [ -n "$dup_fam_keys" ]; then
  remaining=""
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if grep -v '^[[:space:]]*#' "$BASELINE_FILE" 2>/dev/null | grep -Fqx -- "$key"; then
      suppressed=$((suppressed + 1))
    else
      remaining="${remaining}${key}
"
    fi
  done <<EOF
$dup_fam_keys
EOF
  dup_fam_keys="$(printf '%s' "$remaining" | sed '/^$/d')"
fi

suppressed_note=""
if [ "$suppressed" -gt 0 ]; then
  suppressed_note=" (${suppressed} baselined pair(s) suppressed — see ${BASELINE_FILE#"$EA_AGENT_DIR"/})"
fi

if [ -z "$dup_keys" ] && [ -z "$dup_fam_keys" ]; then
  total="$(printf '%s' "$rows" | grep -c . || true)"
  say "queue-dedup-check: ok — ${total} item(s), no duplicate (type, source_id).${suppressed_note}"
  exit 0
fi

count=0
say "queue-dedup-check: FAILED — duplicate queue items found."
say ""

# report_group KEY MODE — print one duplicated key and the files behind it.
# MODE `exact` matches rows on field 1 (`type`); MODE `family` matches on field 6 (`type_family`)
# and considers only non-terminal rows, mirroring exactly how each key set was computed. Getting
# this wrong is silent: the key would be found but no row would match it, so the check would report
# a duplicate and then list zero files.
report_group() {
  local key="$1" mode="$2" sid typ terminal_hit="" matched=0
  typ="${key%%$(printf '\t')*}"
  sid="${key#*$(printf '\t')}"
  count=$((count + 1))
  if [ "$mode" = "family" ]; then
    say "  ${sid}  (type family: ${typ} — ticket / ticket-investigation)"
  else
    say "  ${sid}  (type: ${typ})"
  fi
  while IFS="$(printf '\t')" read -r rtyp rsid rpath rdir rlive rfam; do
    [ "$rsid" = "$sid" ] || continue
    if [ "$mode" = "family" ]; then
      [ "$rfam" = "$typ" ] || continue
      is_terminal_dir "$rdir" && continue
    else
      [ "$rtyp" = "$typ" ] || continue
    fi
    matched=$((matched + 1))
    if [ "$rlive" != "1" ]; then
      say "    - ${rpath}   (rejected — not counted)"
    elif is_terminal_dir "$rdir"; then
      say "    - ${rpath}   <- already terminal (${rdir})"
      terminal_hit="$rdir"
    else
      say "    - ${rpath}   (type: ${rtyp})"
    fi
  done <<EOF
$(printf '%s' "$rows")
EOF
  if [ "$matched" -eq 0 ]; then
    say "    - (no rows matched this key — this is a bug in queue-dedup-check.sh, not in the queue)"
  elif [ "$mode" = "family" ]; then
    say "    => one ticket has TWO live items with different deliverables. A kind reclassification"
    say "       (issue type edited, or retitled to 'Spike: …') must UPDATE the existing incoming/"
    say "       item in place — including its type — never mint a rival. See"
    say "       references/ticket-kind.md -> 'Deciding once'."
  elif [ -n "$terminal_hit" ]; then
    say "    => a ${terminal_hit} item was re-queued. Terminal state must be absorbing:"
    say "       the poller should have skipped this source_id outright."
  else
    say "    => same item queued twice without reconciliation. The poller should have"
    say "       updated the existing file in place rather than minting a new one."
  fi
  say ""
}

while IFS= read -r key; do
  [ -n "$key" ] || continue
  report_group "$key" exact
done <<EOF
$dup_keys
EOF

while IFS= read -r key; do
  [ -n "$key" ] || continue
  report_group "$key" family
done <<EOF
$dup_fam_keys
EOF

say "${count} duplicated source_id(s).${suppressed_note} See references/queue-reconciliation.md for"
say "the rule. Resolve a LIVE duplicate by rejecting the redundant copy (keep the one a human has"
say "acted on). For an immutable historical duplicate — where the work genuinely ran more than once"
say "and every record is true — baseline it instead: queue-dedup-check.sh --update-baseline."
exit 1
