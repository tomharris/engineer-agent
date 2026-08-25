#!/bin/bash
# lib-queue.sh — queue frontmatter reading and the reconciliation lookup, shared by
# scripts/queue-dedup-check.sh (the executable check on the invariant) and the scripted pollers
# (the writers that must uphold it).
#
# WHY EXTRACT: queue-dedup-check.sh already implemented fm() / type_family() / is_terminal_dir() /
# counts_toward_invariant() in awk, and references/queue-reconciliation.md describes the SAME rules
# again in prose for the model to follow by hand on every poll. That is two implementations of one
# invariant, in two languages, and CLAUDE.md is explicit about where that leads: "three prose copies
# of a rule drift". With the pollers becoming scripts there would have been three. One library, one
# implementation; the reference doc becomes the spec rather than a parallel implementation.
#
# Requires EA_AGENT_DIR (source scripts/lib-paths.sh first).

# --- Predicates (moved verbatim from queue-dedup-check.sh; rationale preserved) --------------

# Terminal directories. An item here is DONE: the external action ran (or was explicitly declined),
# so nothing should ever re-draft it. Terminal state is ABSORBING for pollers — see
# references/queue-reconciliation.md. This is not fussiness: the previous "re-queue anything updated
# since last_checked" rule was self-sustaining, because engineer-agent recording its own findings as
# a comment bumps `updated`, which re-queued the ticket it had just completed.
is_terminal_dir() { case "$1" in completed|rejected) return 0 ;; *) return 1 ;; esac; }

# type_family — `ticket` and `ticket-investigation` are two shapes of the SAME work (code change vs
# findings document; see references/ticket-kind.md). A ticket's kind can change between polls — an
# issue type edited, a title retitled to "Spike: …" — and because the invariant is keyed on
# (type, source_id), the naive rule then mints a rival live item for work already queued.
type_family() { case "$1" in ticket|ticket-investigation) echo "ticket" ;; *) echo "$1" ;; esac; }

# rejected/ is the DISPOSAL path, so it does not count toward the dedup CHECK's invariant.
# NOTE the asymmetry with queue_lookup() below, which DOES treat rejected/ as absorbing. Both are
# deliberate and documented in references/queue-reconciliation.md: the checker must not stay red
# after a human resolves a duplicate by rejecting it, while a poller must never re-queue work a
# human explicitly declined.
counts_toward_invariant() { [ "$1" != "rejected" ]; }

# --- Frontmatter -----------------------------------------------------------------------------

# fm <file> <key> — read one frontmatter scalar from the leading --- block. Tolerates quoted and
# bare values, and stops at the closing delimiter so a body mention of `type:` cannot be picked up.
fm() {
  [ -f "$1" ] || return 0
  awk -v key="$2" '
    NR==1 && $0 ~ /^---[[:space:]]*$/ { inside=1; next }
    inside && $0 ~ /^---[[:space:]]*$/ { exit }
    inside {
      line=$0; sub(/^[ \t]+/,"",line)
      k=line; sub(/:.*/,"",k)
      if (k != key) next
      v=substr(line, index(line,":")+1); sub(/^[ \t]+/,"",v)
      if (substr(v,1,1)=="\"") { v=substr(v,2); q=index(v,"\""); if (q>0) v=substr(v,1,q-1) }
      else if (substr(v,1,1)=="\047") { v=substr(v,2); q=index(v,"\047"); if (q>0) v=substr(v,1,q-1) }
      else { sub(/[ \t]+#.*$/,"",v); sub(/[ \t]+$/,"",v) }
      print v; exit
    }
  ' "$1"
}

# fm_set <file> <key> <value> — replace a frontmatter scalar in place (creating it if absent),
# touching ONLY the leading --- block. Used for status transitions (incoming -> drafted) without
# rewriting the item.
fm_set() {
  local file="$1" key="$2" val="$3" tmp
  [ -f "$file" ] || return 1
  tmp="${file}.tmp.$$"
  awk -v key="$key" -v val="$val" '
    NR==1 && $0 ~ /^---[[:space:]]*$/ { print; inside=1; next }
    inside && $0 ~ /^---[[:space:]]*$/ {
      if (!done) { print key ": \"" val "\""; done=1 }
      print; inside=0; next
    }
    inside {
      line=$0; sub(/^[ \t]+/,"",line)
      k=line; sub(/:.*/,"",k)
      if (k == key && !done) { print key ": \"" val "\""; done=1; next }
      print; next
    }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# has_section <file> <heading> — rc 0 if the item body contains that exact heading line.
# The canonical use is `has_section "$f" "## Draft Response"`, which is how the resume sweep
# distinguishes a fully-drafted item from one stranded mid-flight.
has_section() {
  [ -f "$1" ] || return 1
  grep -qE "^$(printf '%s' "$2" | sed 's/[][\.*^$/]/\\&/g')[[:space:]]*$" "$1"
}

# --- Enumeration and lookup ------------------------------------------------------------------

# queue_dirs — the four queue directories, in pipeline order.
queue_dirs() { printf '%s\n' incoming drafts completed rejected; }

# queue_items [dir...] — absolute paths of every real queue item. CLAUDE.md living in a queue dir is
# repo instructions, not an item.
queue_items() {
  local dirs=("$@") d f base
  [ ${#dirs[@]} -gt 0 ] || dirs=(incoming drafts completed rejected)
  for d in "${dirs[@]}"; do
    [ -d "${EA_AGENT_DIR}/queue/$d" ] || continue
    for f in "${EA_AGENT_DIR}/queue/$d"/*.md; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      [ "$base" = "CLAUDE.md" ] && continue
      printf '%s\n' "$f"
    done
  done
}

# queue_lookup <type> <source_id> — the reconciliation lookup from
# references/queue-reconciliation.md. Prints "<dir>\t<absolute path>" for an existing item, or
# nothing. Only the FIRST match is returned; queue-dedup-check.sh is what asserts there is at most
# one.
#
# The lookup is FAMILY-WIDE and INCLUDES TERMINAL ITEMS — both deliberate, and the opposite of
# queue-dedup-check.sh's narrower family rule. A poller asking "have I handled this before?" must
# see a completed ticket-investigation when it is about to create a ticket for the same source_id;
# otherwise a retitled issue mints a rival item for finished work.
queue_lookup() {
  local want_type="$1" want_sid="$2" fam f d sid typ
  [ -n "$want_sid" ] || return 0
  fam="$(type_family "$want_type")"
  while IFS= read -r f; do
    sid="$(fm "$f" source_id)"
    [ "$sid" = "$want_sid" ] || continue
    typ="$(fm "$f" type)"
    [ "$(type_family "$typ")" = "$fam" ] || continue
    d="$(basename "$(dirname "$f")")"
    printf '%s\t%s\n' "$d" "$f"
    return 0
  done < <(queue_items)
}

# queue_disposition <type> <source_id> — collapse the lookup into the single branch a poller must
# take. Exactly one of:
#
#   create            nothing exists anywhere            -> mint a new item
#   skip              terminal (completed/ or rejected/) -> skip UNCONDITIONALLY
#   update:<path>     incoming/ and still _unrouted      -> update in place, keep the timestamp prefix
#   unchanged:<path>  drafts/, or incoming/ with a project -> leave alone
#
# Note "unchanged" for a resolved incoming/ item is what the resume sweep exists to backstop: such
# an item is invisible to BOTH approval paths (only drafts/ is reachable by the gate), so a poller
# leaving it alone forever is correct per the reconciliation table but fatal if its draft never got
# written. See poll_resume_candidates().
queue_disposition() {
  local hit dir path proj
  hit="$(queue_lookup "$1" "$2")"
  [ -n "$hit" ] || { printf 'create'; return 0; }
  dir="${hit%%	*}"; path="${hit#*	}"
  if is_terminal_dir "$dir"; then printf 'skip'; return 0; fi
  if [ "$dir" = "incoming" ]; then
    proj="$(fm "$path" project)"
    if [ "$proj" = "_unrouted" ] || [ -z "$proj" ]; then printf 'update:%s' "$path"; return 0; fi
  fi
  printf 'unchanged:%s' "$path"
}

# poll_resume_candidates — items sitting in incoming/ with NO "## Draft Response" section.
#
# WHY THIS EXISTS: CLAUDE.md — "Only drafts/ is reachable by the approval gate. An item parked in
# incoming/ with a finished draft is invisible to both approval paths — terminal and ntfy — and
# fails silently in each." The scripted poller writes items to incoming/ for the model to draft, so
# a drafting phase that dies (budget abort, API error, killed session) strands the item: the
# reconciliation table says an incoming/ item with a resolved project is "leave alone", so nothing
# would ever pick it up again. Re-emitting these into each run's manifest makes stranding
# self-healing on the next 15-minute tick instead of permanent and invisible.
poll_resume_candidates() {
  local f
  while IFS= read -r f; do
    has_section "$f" "## Draft Response" || printf '%s\n' "$f"
  done < <(queue_items incoming)
}
