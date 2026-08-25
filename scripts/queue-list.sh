#!/bin/bash
# queue-list.sh — the sorted, numbered table behind `/engineer-agent review-queue`.
#
# WHY: commands/review-queue.md has the model glob drafts/, parse frontmatter from each file,
# filter by type and project, sort by three keys, compute a relative age per row, and render the
# table. Its spec even has to WARN the model about one of those steps — "Match filters against the
# frontmatter type exactly, never as a prefix" — which is a bug class that simply does not arise in
# a `case` statement. (Without it, `--type ticket` would sweep up ticket-plan, ticket-refinement and
# ticket-investigation.)
#
# SORT ORDER, from review-queue.md: unrouted items first (a human is the last tier of the routing
# ladder, so they block), then priority urgent > normal > low, then created_at ascending (oldest
# first).
#
# Usage: queue-list.sh [--type <t>] [--project <slug>] [--tsv]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib-paths.sh"
. "${SCRIPT_DIR}/lib-time.sh"
. "${SCRIPT_DIR}/lib-queue.sh"

TAB="$(printf '\t')"
WANT_TYPE=""; WANT_PROJECT=""; TSV=0
while [ $# -gt 0 ]; do
  case "$1" in
    --type)    WANT_TYPE="$2"; shift 2 ;;
    --project) WANT_PROJECT="$2"; shift 2 ;;
    --tsv)     TSV=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "queue-list.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

prio_rank() { case "$1" in urgent) echo 0 ;; normal) echo 1 ;; low) echo 2 ;; *) echo 1 ;; esac; }

ROWS=""
collect() { # collect <dir> <unrouted_only>
  local dir="$1" only_unrouted="$2" f typ proj prio created title sid
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    typ="$(fm "$f" type)"; proj="$(fm "$f" project)"
    if [ "$only_unrouted" -eq 1 ]; then [ "$proj" = "_unrouted" ] || continue; fi
    # EXACT type match, never a prefix — ticket-plan and ticket-investigation are their own types.
    if [ -n "$WANT_TYPE" ] && [ "$typ" != "$WANT_TYPE" ]; then continue; fi
    if [ -n "$WANT_PROJECT" ] && [ "$proj" != "$WANT_PROJECT" ]; then continue; fi
    prio="$(fm "$f" priority)"; created="$(fm "$f" created_at)"
    title="$(fm "$f" title)"; sid="$(fm "$f" source_id)"
    ROWS="${ROWS}$([ "$only_unrouted" -eq 1 ] && echo 0 || echo 1)${TAB}$(prio_rank "$prio")${TAB}${created}${TAB}$(basename "$f")${TAB}${typ}${TAB}${proj}${TAB}${prio}${TAB}${sid}${TAB}${title}
"
  done < <(queue_items "$dir")
}

# Unrouted items live in incoming/ and are surfaced FIRST: they are blocked on a human choosing a
# project, and review-queue is where that choice is made.
collect incoming 1
collect drafts 0

ROWS="$(printf '%s' "$ROWS" | sed -E '/^[[:space:]]*$/d' | LC_ALL=C sort -t"$TAB" -k1,1n -k2,2n -k3,3)"

if [ -z "$ROWS" ]; then
  [ "$TSV" -eq 1 ] || echo "Queue is empty — nothing awaiting review."
  exit 0
fi

if [ "$TSV" -eq 1 ]; then
  printf '%s\n' "$ROWS"
  exit 0
fi

printf '| # | Type | Project | Priority | Age | Item |\n'
printf '|---|---|---|---|---|---|\n'
n=0
printf '%s\n' "$ROWS" | while IFS="$TAB" read -r _ _ created file typ proj prio _ title; do
  n=$((n+1))
  [ "$proj" = "_unrouted" ] && proj="**_unrouted**"
  printf '| %d | %s | %s | %s | %s | %s |\n' \
    "$n" "$typ" "$proj" "$prio" "$(relative_age "$created")" "$(printf '%s' "$title" | cut -c1-70)"
done
printf '\nFiles, in the same order:\n'
printf '%s\n' "$ROWS" | cut -f4 | nl -w3 -s'. '
