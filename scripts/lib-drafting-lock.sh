#!/bin/bash
# lib-drafting-lock.sh — the one lock every drafting run (global poll, each job's jobs-draft.sh)
# takes, so no two models edit the same queue file. Watch jobs dispatch concurrently, so acquiring
# must be atomic: the PID is written to a temp file and hard-linked into place (`ln` fails if the
# lock exists), so a reader never sees an empty lock.
#
# Requires lib-paths.sh (EA_AGENT_DIR).

DRAFTING_LOCK="${EA_AGENT_DIR}/state/drafting.lock"

# drafting_lock_acquire — rc 0 if taken (holds $$); else prints the holder's PID, rc 1.
# A dead holder's lock is reclaimed once.
drafting_lock_acquire() {
  local f="$DRAFTING_LOCK" t pid
  mkdir -p "$(dirname "$f")"
  t="${f}.$$"
  echo $$ > "$t" || return 1
  if ln "$t" "$f" 2>/dev/null; then rm -f "$t"; return 0; fi
  pid="$(cat "$f" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then rm -f "$t"; printf '%s' "$pid"; return 1; fi
  rm -f "$f"
  if ln "$t" "$f" 2>/dev/null; then rm -f "$t"; return 0; fi
  rm -f "$t"; cat "$f" 2>/dev/null; return 1
}

# drafting_lock_release — removes the lock only if this process holds it.
drafting_lock_release() {
  [ "$(cat "$DRAFTING_LOCK" 2>/dev/null)" = "$$" ] && rm -f "$DRAFTING_LOCK"
  return 0
}
