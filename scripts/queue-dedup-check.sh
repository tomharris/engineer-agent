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
# Usage: queue-dedup-check.sh [-q] [--heal] [--keys]
#   -q       quiet: exit status only, no output
#   --heal   auto-resolve the duplicates that need no human judgement (see "Healing" below),
#            then report on whatever is left. Without it the check never writes to the queue.
#   --keys   machine-readable: print one "type<TAB>source_id" line per UNRESOLVED duplicate group
#            (after healing and baseline suppression) instead of the prose report. This is what
#            cron-poll.sh diffs against its last push, so a standing duplicate is announced once
#            rather than every 15 minutes.
# Exit: 0 = invariant holds (or empty queue), 1 = duplicates found, 2 = usage/queue-missing error.
#
# HEALING: a duplicate used to be a pure alarm — it stayed red, and re-pushed an ntfy warning on
# every poll, until a human hand-rejected a copy. But most duplicates are mechanical: the poller
# minted a rival file instead of updating in place, and one of the two copies holds no work at all.
# Rejecting that copy is a decision a script can make correctly, so `--heal` makes it, and the
# notification disappears with the duplicate instead of nagging until someone is at a laptop.
#
# What it will NOT touch, because each needs a judgement the script does not have:
#   - a group containing a `completed/` copy. That is EITHER the self-sustaining re-queue loop
#     (heal-worthy) OR a human's deliberate `/engineer-agent add-ticket` override of terminal
#     state, which references/queue-reconciliation.md explicitly permits — and the two are
#     indistinguishable on disk by design ("downstream skills see no difference between a manually
#     added and a polled item"). Auto-rejecting would silently throw away the human's re-add.
#   - a group with two or more SUBSTANTIVE copies (in drafts/, or carrying a `## Draft Response`).
#     A draft is human-owned: someone may be mid-review or may have hand-edited it, and there is no
#     way to tell which of two drafts to keep.

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
HEAL=0
KEYS=0
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet) QUIET=1; shift ;;
    --heal) HEAL=1; shift ;;
    --keys) KEYS=1; shift ;;
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "queue-dedup-check.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
# --keys is consumed by another program; the prose report would corrupt it.
[ "$KEYS" -eq 1 ] && QUIET=1

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

QUEUE="${EA_AGENT_DIR}/queue"
if [ ! -d "$QUEUE" ]; then
  echo "queue-dedup-check.sh: no queue directory at $QUEUE" >&2
  exit 2
fi

# collect_rows — set `rows` to "type<TAB>source_id<TAB>dir/filename<TAB>dir<TAB>live<TAB>family",
# one line per queue item. A function rather than straight-line code because `--heal` moves files
# and the whole picture has to be recomputed afterwards; two copies of this loop would drift.
collect_rows() {
  local dir f base sid typ live fam
  rows=""
  for dir in incoming drafts completed rejected; do
    [ -d "$QUEUE/$dir" ] || continue
    for f in "$QUEUE/$dir"/*.md; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      # CLAUDE.md is repo instructions that live in the queue dirs, not a queue item.
      [ "$base" = "CLAUDE.md" ] && continue
      sid="$(fm "$f" source_id)"
      [ -n "$sid" ] || continue        # no source_id: not a trackable item, nothing to dedup on
      typ="$(fm "$f" type)"
      [ -n "$typ" ] || typ="(untyped)"
      if counts_toward_invariant "$dir"; then live=1; else live=0; fi
      fam="$(type_family "$typ")"
      rows="${rows}${typ}	${sid}	${dir}/${base}	${dir}	${live}	${fam}
"
    done
  done
}

# compute_dup_keys — set `dup_keys` (exact (type, source_id)) and `dup_fam_keys` (the
# {ticket, ticket-investigation} family) from the current `rows`.
compute_dup_keys() {
  # Group by (type, source_id). A single ticket legitimately appears under several TYPES — a
  # `ticket` item and its later `qa-test-plan` share a source_id and are not duplicates — so the
  # type is part of the key, not ignored.
  # Only field 5 == 1 (a non-rejected item) is counted; rejected copies are context, not violations.
  dup_keys="$(printf '%s' "$rows" | awk -F'\t' 'NF>=5 && $5==1 { c[$1"\t"$2]++ } END { for (k in c) if (c[k]>1) print k }' | sort)"

  # Family check — the reclassification duplicate the exact-type key above cannot see. Restricted
  # to LIVE, NON-TERMINAL dirs (incoming/, drafts/) on purpose: two live items for one source_id
  # across the {ticket, ticket-investigation} pair is always the poller failing to update in place,
  # whereas a terminal item plus a live one of the other type is the legitimate spike -> implement
  # handoff. Keys already reported by the exact check are excluded so a duplicate is never printed
  # twice.
  dup_fam_keys="$(printf '%s' "$rows" \
    | awk -F'\t' 'NF>=6 && $5==1 && $4!="completed" && $4!="rejected" { c[$6"\t"$2]++ } END { for (k in c) if (c[k]>1) print k }' \
    | sort)"
  if [ -n "$dup_fam_keys" ] && [ -n "$dup_keys" ]; then
    local remaining_fam="" fkey
    while IFS= read -r fkey; do
      [ -n "$fkey" ] || continue
      printf '%s' "$dup_keys" | grep -Fqx -- "$fkey" || remaining_fam="${remaining_fam}${fkey}
"
    done <<EOF
$dup_fam_keys
EOF
    dup_fam_keys="$(printf '%s' "$remaining_fam" | sed '/^$/d')"
  fi
}

collect_rows
if [ -z "$rows" ]; then
  say "queue-dedup-check: no queue items found; invariant holds trivially."
  exit 0
fi
compute_dup_keys

# --- Healing ----------------------------------------------------------------------------------
# See the "HEALING" note in the header for what this deliberately refuses to touch and why.
heal_count=0
heal_log=""

# group_rows <key> <mode> — print the member rows of one duplicate group, in the same shape as
# `rows`. mode `exact` matches field 1 (type); mode `family` matches field 6 and drops terminal
# rows — mirroring exactly how each key set was computed. Getting that wrong is silent: the group
# would come back empty and the heal would quietly do nothing.
group_rows() {
  local key="$1" mode="$2" typ sid rtyp rsid rpath rdir rlive rfam
  typ="${key%%$(printf '\t')*}"
  sid="${key#*$(printf '\t')}"
  while IFS="$(printf '\t')" read -r rtyp rsid rpath rdir rlive rfam; do
    [ "$rsid" = "$sid" ] || continue
    [ "$rlive" = "1" ] || continue
    if [ "$mode" = "family" ]; then
      [ "$rfam" = "$typ" ] || continue
      is_terminal_dir "$rdir" && continue
    else
      [ "$rtyp" = "$typ" ] || continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rtyp" "$rsid" "$rpath" "$rdir" "$rlive" "$rfam"
  done <<EOF
$(printf '%s' "$rows")
EOF
}

# is_substantive <dir> <file> — does this copy hold work that a human would lose if it went away?
# drafts/ is human-owned by definition (references/queue-reconciliation.md: "a draft is human-owned:
# someone may be mid-review, or may have hand-edited the draft response"), and an incoming/ item
# that already carries a `## Draft Response` is a drafted item caught mid-move.
is_substantive() {
  [ "$1" = "drafts" ] && return 0
  has_section "$2" "## Draft Response"
}

# reject_copy <relative path> <keeper relative path> — move one redundant copy to rejected/,
# recording WHY in its frontmatter. It is REJECTED, not deleted: rejected/ is the disposal path the
# invariant already ignores (counts_toward_invariant), and keeping the file means an auto-resolution
# can always be inspected — or undone — after the fact, which a delete would not allow.
reject_copy() {
  local rel="$1" keeper="$2" src dst base n=1
  src="$QUEUE/$rel"
  [ -f "$src" ] || return 1
  base="$(basename "$rel")"
  mkdir -p "$QUEUE/rejected"
  dst="$QUEUE/rejected/$base"
  # A same-named file already in rejected/ is a DIFFERENT item (same timestamp, same key, earlier
  # disposal). Never clobber it — that would destroy the record this move exists to preserve.
  while [ -e "$dst" ]; do dst="$QUEUE/rejected/${base%.md}-dup${n}.md"; n=$((n + 1)); done
  fm_set "$src" status rejected || return 1
  fm_set "$src" rejected_reason "auto-resolved duplicate of ${keeper} by queue-dedup-check --heal" || return 1
  mv "$src" "$dst" || return 1
}

# heal_group <key> <mode> — resolve one duplicate group, or decline to.
heal_group() {
  local key="$1" mode="$2" members subst="" bare="" nsub keeper discard d
  local rtyp rsid rpath rdir rlive rfam
  members="$(group_rows "$key" "$mode")"
  [ -n "$members" ] || return 0

  # A completed/ copy makes the group ambiguous — the self-sustaining re-queue loop and a human's
  # deliberate `add-ticket` override of terminal state look identical on disk. Hands off.
  if printf '%s\n' "$members" | awk -F'\t' '$4=="completed" { f=1 } END { exit !f }'; then
    return 0
  fi

  while IFS="$(printf '\t')" read -r rtyp rsid rpath rdir rlive rfam; do
    [ -n "$rpath" ] || continue
    if is_substantive "$rdir" "$QUEUE/$rpath"; then
      subst="${subst}${rpath}
"
    else
      bare="${bare}${rpath}
"
    fi
  done <<EOF
$members
EOF
  subst="$(printf '%s' "$subst" | sed '/^$/d')"
  bare="$(printf '%s' "$bare" | sed '/^$/d')"
  nsub="$(printf '%s' "$subst" | grep -c . || true)"

  if [ "${nsub:-0}" -gt 1 ]; then
    return 0                      # two drafts; no way to know which one a human is holding
  elif [ "${nsub:-0}" -eq 1 ]; then
    keeper="$subst"               # the drafted copy is the one a human is working from
    discard="$bare"
  else
    # No copy holds any work, so keep the OLDEST: the filename's {YYYYMMDD-HHmmss} prefix is the
    # created_at ordering, and references/queue-reconciliation.md keeps it deliberately so a
    # long-unrouted ticket does not keep jumping to the top of the review queue.
    keeper="$(printf '%s\n' "$bare" | sort -t/ -k2 | head -1)"
    discard="$(printf '%s\n' "$bare" | grep -Fxv -- "$keeper" || true)"
  fi
  [ -n "$discard" ] || return 0

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if reject_copy "$d" "$keeper"; then
      heal_count=$((heal_count + 1))
      heal_log="${heal_log}    - ${d}  ->  rejected/   (redundant copy of ${keeper})
"
    else
      heal_log="${heal_log}    - ${d}   COULD NOT be moved — left in place
"
    fi
  done <<EOF
$discard
EOF
}

if [ "$HEAL" -eq 1 ]; then
  # NOT `printf ... | while read`: a pipeline runs the loop in a SUBSHELL, so every heal_count /
  # heal_log increment would be discarded and the heal would appear to do nothing while quietly
  # rejecting files. Here-docs keep the loop in this shell — the same reason the report loops below
  # use them.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    heal_group "$key" exact
  done <<EOF
$dup_keys
EOF
  # Recompute between the two passes: an exact heal has moved files, and the family pass would
  # otherwise reason about rows that no longer exist (a source_id can carry both an exact-type
  # duplicate and a family one — two ticket-investigations plus a ticket, say).
  if [ "$heal_count" -gt 0 ]; then collect_rows; compute_dup_keys; fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    heal_group "$key" family
  done <<EOF
$dup_fam_keys
EOF

  if [ "$heal_count" -gt 0 ]; then
    collect_rows
    compute_dup_keys
    say "queue-dedup-check: healed — ${heal_count} redundant cop(ies) moved to rejected/:"
    printf '%s' "$heal_log" | while IFS= read -r l; do say "$l"; done
    say ""
  fi
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

# --keys: the machine-readable answer, emitted AFTER healing and baseline suppression so it names
# exactly what a human still has to resolve — nothing more. cron-poll.sh diffs this list against
# the one it last pushed, which is what turns a standing duplicate into a single notification
# instead of one every 15 minutes.
if [ "$KEYS" -eq 1 ]; then
  [ -n "$dup_keys" ] && printf '%s\n' "$dup_keys"
  [ -n "$dup_fam_keys" ] && printf '%s\n' "$dup_fam_keys"
  if [ -z "$dup_keys" ] && [ -z "$dup_fam_keys" ]; then exit 0; fi
  exit 1
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
if [ "$HEAL" -eq 1 ]; then
  say ""
  say "(--heal ran and left these alone on purpose: each one either includes a completed/ copy —"
  say " ambiguous between the re-queue loop and a deliberate add-ticket override — or holds two"
  say " copies with human-owned drafts. Both need a person to choose. See the header.)"
fi
exit 1
