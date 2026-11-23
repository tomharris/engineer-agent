#!/bin/bash
# queue-hygiene.sh — heal stranded drafts, heal duplicates, push once per unresolved duplicate set.
# Run by jobs-tick.sh, at most every EA_HYGIENE_EVERY.
#
# Takes drafting.lock unless --lock-held: a heal racing a draft in progress would move or reject a
# file a model is still editing. A held lock skips the run and leaves --stamp untouched, so the
# next tick retries.
#
# ORDER: heal-stranded first. It changes which directory an item lives in, and queue-dedup-check's
# healing rules turn on exactly that (a copy in drafts/ counts as substantive).
#
# NO PUSH FOR AUTO-RESOLUTIONS. A stranded move or a mechanical duplicate needs no judgement; it is
# logged and counted by `/engineer-agent status`. What dedup --heal declines (a completed/ copy, or
# two human-owned drafts) is pushed ONCE per distinct (type, source_id), tracked in
# state/queue-dedup-notified.tsv. The ledger is rewritten to exactly what is unresolved now, so a
# duplicate that is resolved and later recurs is announced again. The dedup warning once re-fired
# every 15 minutes on the same ntfy topic the Approve/Reject buttons use.
#
# Usage: queue-hygiene.sh [--lock-held] [--stamp <file>] [--log <file>]
#   --lock-held  caller already holds drafting.lock
#   --stamp      write the run's epoch here once the lock is taken (EA_NOW overrides)
#   --log        append to this log (default state/jobs.log)
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
# shellcheck source=lib-drafting-lock.sh
. "${PLUGIN_ROOT}/scripts/lib-drafting-lock.sh"

LOCK_HELD=0; STAMP=""; LOG_FILE="${EA_AGENT_DIR}/state/jobs.log"
while [ $# -gt 0 ]; do
  case "$1" in
    --lock-held) LOCK_HELD=1; shift ;;
    --stamp)     STAMP="$2"; shift 2 ;;
    --log)       LOG_FILE="$2"; shift 2 ;;
    *) echo "queue-hygiene.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
NOTIFY="${EA_NOTIFY_BIN:-${PLUGIN_ROOT}/scripts/notify.sh}"
mkdir -p "${EA_AGENT_DIR}/state" "$(dirname "$LOG_FILE")"

if [ "$LOCK_HELD" -eq 0 ]; then
  if ! holder="$(drafting_lock_acquire)"; then
    echo "queue-hygiene: skipped, drafter (PID ${holder}) holds drafting.lock" >> "$LOG_FILE"
    exit 0
  fi
  trap drafting_lock_release EXIT
fi
if [ -n "$STAMP" ]; then
  mkdir -p "$(dirname "$STAMP")"
  printf '%s\n' "${EA_NOW:-$(date +%s)}" > "$STAMP"
fi

HEAL_RC=0
HEAL_OUT="$(bash "${PLUGIN_ROOT}/scripts/queue-heal-stranded.sh" --heal 2>&1)" || HEAL_RC=$?
case "$HEAL_OUT" in
  *"nothing stranded"*) ;;
  *) printf '%s\n' "$HEAL_OUT" >> "$LOG_FILE" ;;
esac
[ "$HEAL_RC" -eq 0 ] || echo "WARN: queue-heal-stranded left items unresolved (exit ${HEAL_RC}); see above" >> "$LOG_FILE"

DUP_RC=0
DUP_OUT="$(bash "${PLUGIN_ROOT}/scripts/queue-dedup-check.sh" --heal 2>&1)" || DUP_RC=$?
NOTIFIED_FILE="${EA_AGENT_DIR}/state/queue-dedup-notified.tsv"
case "$DUP_OUT" in
  *"queue-dedup-check: healed"*|*FAILED*) printf '%s\n' "$DUP_OUT" >> "$LOG_FILE" ;;
esac

case "$DUP_RC" in
  1)
    echo "WARN: queue has duplicate items --heal could not resolve — see references/queue-reconciliation.md" >> "$LOG_FILE"
    # --keys is the post-heal list: exactly what a human still has to decide. It exits 1 whenever
    # it has something to report.
    DUP_KEYS="$(bash "${PLUGIN_ROOT}/scripts/queue-dedup-check.sh" --keys 2>/dev/null || true)"
    NEW_KEYS=""
    while IFS= read -r dkey; do
      [ -n "$dkey" ] || continue
      if [ -f "$NOTIFIED_FILE" ] && grep -Fqx -- "$dkey" "$NOTIFIED_FILE"; then continue; fi
      NEW_KEYS="${NEW_KEYS}${dkey}
"
    done <<EOF
$DUP_KEYS
EOF
    printf '%s\n' "$DUP_KEYS" | sed '/^$/d' > "$NOTIFIED_FILE"
    if [ -n "$NEW_KEYS" ]; then
      DUP_IDS="$(printf '%s' "$NEW_KEYS" | awk -F'\t' 'NF>=2 { print $2 }' | paste -sd, - | cut -c1-160)"
      "$NOTIFY" \
        --title 'engineer-agent: duplicate queue items' \
        --message "Duplicate queue item(s) needing a decision: ${DUP_IDS:-see log}. Auto-healing declined these (a completed copy, or two drafts). Reject the redundant copy; keep the one a human has acted on." \
        --priority normal --tags warning --fyi >> "$LOG_FILE" 2>&1 || true
    else
      echo "INFO: duplicate(s) unchanged since the last push; not re-notifying." >> "$LOG_FILE"
    fi ;;
  0)
    # Clean, possibly because --heal just fixed it: drop the ledger so a recurrence pushes.
    rm -f "$NOTIFIED_FILE" ;;
  *)
    # Could not run: says nothing about resolution, so the ledger is left alone.
    echo "WARN: queue-dedup-check could not run (exit ${DUP_RC}): ${DUP_OUT}" >> "$LOG_FILE" ;;
esac
exit 0
