#!/bin/bash
# migrate-storage.sh — move engineer-agent runtime data out of ~/.claude/engineer-agent/
# and into the XDG location (see lib-paths.sh for why this move exists).
#
# Safe to re-run: it copies, verifies, then leaves the legacy tree in place with a
# .migrated marker rather than deleting anything. Remove the old tree yourself once
# you're satisfied.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
source "${PLUGIN_ROOT}/scripts/lib-paths.sh"

FROM="$EA_LEGACY_AGENT_DIR"
TO="$EA_AGENT_DIR"

if [ "$FROM" = "$TO" ]; then
  echo "Source and destination are the same ($TO) — nothing to do." >&2
  exit 1
fi

if [ ! -d "$FROM" ]; then
  echo "No legacy install at ${FROM} — nothing to migrate."
  echo "Runtime data location: ${TO}"
  exit 0
fi

if [ -e "${FROM}/.migrated" ]; then
  echo "Already migrated (${FROM}/.migrated exists)."
  echo "Runtime data location: ${TO}"
  exit 0
fi

echo "Migrating engineer-agent runtime data:"
echo "  from: ${FROM}"
echo "    to: ${TO}"
echo ""

mkdir -p "$TO"

# -n: never overwrite anything already at the destination, so a partial or repeated run
# can't clobber newer state (notably state/ntfy-seen.yaml, which is the remote-approval
# at-most-once ledger — losing it could re-execute an already-approved item).
cp -Rn "${FROM}/." "$TO/" 2>/dev/null || true

echo "Contents now at ${TO}:"
for sub in engineer.yaml queue state uat-plans; do
  if [ -e "${TO}/${sub}" ]; then
    if [ -d "${TO}/${sub}" ]; then
      printf '  %-14s %s file(s)\n' "${sub}/" "$(find "${TO}/${sub}" -type f | wc -l | tr -d ' ')"
    else
      printf '  %-14s present\n' "${sub}"
    fi
  else
    printf '  %-14s (absent)\n' "${sub}"
  fi
done

date -u +%Y-%m-%dT%H:%M:%SZ > "${FROM}/.migrated"

cat <<EOF

Done. The legacy tree was left intact at:
  ${FROM}
Verify the new location looks right, then remove it:
  rm -rf "${FROM}"

Note: writes under ~/.claude/ are refused by Claude Code's sensitive-path guard, so the
legacy tree cannot be updated by headless runs anyway — it is now inert.
EOF
