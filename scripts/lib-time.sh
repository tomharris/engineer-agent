#!/bin/bash
# lib-time.sh — timestamp helpers for the scripted pollers.
#
# WHY A LIBRARY FOR SOMETHING THIS SMALL: `date -d "<iso>" +%s` is GNU-only. This plugin installs
# its poll as a launchd LaunchAgent on macOS (install-cron.sh branches on `uname` = Darwin), where
# `date` is BSD and needs `date -j -f <fmt>`. A GNU-only call site does not error out usefully on
# macOS — it prints a usage message to stderr and returns empty, so an age filter silently compares
# against 0 and every issue looks ancient (or brand new, depending on the comparison). Branch on the
# platform ONCE, here, instead of at each call site.
#
# All functions speak ISO-8601 UTC ("2026-08-25T14:00:01Z"), the format already used throughout
# state/last-poll.yaml and every queue item's created_at.

# _ea_date_flavor — "gnu" or "bsd", probed once and cached.
_ea_date_flavor() {
  if [ -n "${_EA_DATE_FLAVOR:-}" ]; then printf '%s' "$_EA_DATE_FLAVOR"; return 0; fi
  if date -d "1970-01-01T00:00:00Z" +%s >/dev/null 2>&1; then _EA_DATE_FLAVOR=gnu; else _EA_DATE_FLAVOR=bsd; fi
  printf '%s' "$_EA_DATE_FLAVOR"
}

# iso_now — current time as ISO-8601 UTC.
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# epoch_now — current time as a unix epoch.
epoch_now() { date -u +%s; }

# epoch_of_iso <iso8601> — unix epoch for an ISO-8601 UTC timestamp. Prints nothing on an
# unparseable value; callers MUST treat empty as "unknown" and fail safe rather than as 0. A
# fractional-second or offset form ("2026-07-21T08:12:57.458-0600", as Jira returns) is normalized
# to whole seconds UTC first.
epoch_of_iso() {
  local ts="${1:-}" bare off sign hh mm adj e
  [ -n "$ts" ] || return 0
  ts="${ts/ /T}"
  ts="$(printf '%s' "$ts" | sed -E 's/\.[0-9]+//')"        # drop fractional seconds

  # Normalize any UTC offset in the shell rather than delegating to date. GNU date understands
  # "…T08:12:57-0600" and BSD date does not — a BSD call site that merely stripped the offset
  # would be silently SIX HOURS wrong rather than failing. Both platforms now take the identical
  # path: parse the bare wall-clock as UTC, then subtract the offset by hand.
  bare="${ts%Z}"
  off="$(printf '%s' "$bare" | sed -nE 's/.*([+-][0-9]{2}:?[0-9]{2})$/\1/p')"
  [ -n "$off" ] && bare="${bare%"$off"}"

  case "$(_ea_date_flavor)" in
    gnu) e="$(date -u -d "$bare" +%s 2>/dev/null)" ;;
    bsd) e="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$bare" +%s 2>/dev/null)" ;;
  esac
  [ -n "$e" ] || return 0

  if [ -n "$off" ]; then
    sign="${off:0:1}"; off="${off:1}"; off="${off/:/}"
    hh="${off:0:2}"; mm="${off:2:2}"
    adj=$(( 10#$hh * 3600 + 10#$mm * 60 ))
    if [ "$sign" = "+" ]; then e=$(( e - adj )); else e=$(( e + adj )); fi
  fi
  printf '%s' "$e"
}

# iso_of_epoch <epoch> — ISO-8601 UTC for a unix epoch.
iso_of_epoch() {
  local e="${1:-}"
  [ -n "$e" ] || return 0
  case "$(_ea_date_flavor)" in
    gnu) date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ;;
    bsd) date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ;;
  esac
}

# iso_days_ago <n> — ISO-8601 UTC for n days before now. Used for agent.max_issue_age_days.
iso_days_ago() {
  local days="${1:-0}"
  iso_of_epoch "$(( $(epoch_now) - days * 86400 ))"
}

# iso_older_than <iso8601> <days> — rc 0 when the timestamp is strictly older than <days> days.
# An unparseable timestamp returns rc 1 (NOT older), so a parse failure can never silently drop a
# live item from the queue. Fail toward doing the work.
iso_older_than() {
  local ts="${1:-}" days="${2:-0}" e
  [ "$days" -gt 0 ] 2>/dev/null || return 1
  e="$(epoch_of_iso "$ts")"
  [ -n "$e" ] || return 1
  [ "$e" -lt "$(( $(epoch_now) - days * 86400 ))" ]
}

# relative_age <iso8601> — human age for status tables ("3d ago", "45m ago", "just now").
# Prints "unknown" when unparseable rather than a misleading "56y ago" from an implicit 0.
relative_age() {
  local ts="${1:-}" e now d
  e="$(epoch_of_iso "$ts")"
  [ -n "$e" ] || { printf 'unknown'; return 0; }
  now="$(epoch_now)"
  d=$(( now - e ))
  [ "$d" -lt 0 ] && d=0
  if   [ "$d" -lt 60 ];    then printf 'just now'
  elif [ "$d" -lt 3600 ];  then printf '%dm ago' $(( d / 60 ))
  elif [ "$d" -lt 86400 ]; then printf '%dh ago' $(( d / 3600 ))
  else                          printf '%dd ago' $(( d / 86400 ))
  fi
}
