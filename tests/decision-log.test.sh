#!/bin/bash
# Tests for scripts/lib-decision-log.sh: row sanitizing and the queue-item section.
#
# Run: bash tests/decision-log.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
. "$REPO_ROOT/scripts/lib-decision-log.sh"

echo "== dlog_row"
T="$TMP/state/d.tsv"
dlog_row "$T" ci "fix run 1" "CI failed" "abc1234" "pushed def5678"
dlog_row "$T" ci "fix run 2" "CI failed" "def5678" "pushed nothing"
eq "header written once, then one line per row" 3 "$(wc -l < "$T" | tr -d ' ')"
eq "header columns" "ts	phase	decision	why	evidence	result" "$(head -1 "$T")"
eq "row cells in order" "ci|fix run 1|CI failed|abc1234|pushed def5678" "$(sed -n 2p "$T" | cut -f2- | tr '\t' '|')"
sed -n 2p "$T" | cut -f1 | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' && ok "ts is UTC ISO8601" || bad "ts: $(sed -n 2p "$T" | cut -f1)"

dlog_row "$T" "a	b" "line1
line2" "x" "=HYPERLINK(1)" "-1"
eq "tabs and newlines in a cell stay inside one row" 4 "$(wc -l < "$T" | tr -d ' ')"
eq "still six columns" 6 "$(sed -n 4p "$T" | awk -F'\t' '{print NF}')"
eq "a formula-leading cell is quoted" "'=HYPERLINK(1)" "$(sed -n 4p "$T" | cut -f5)"
eq "a minus-leading cell is quoted" "'-1" "$(sed -n 4p "$T" | cut -f6)"

dlog_row "" p d w e r && ok "an empty path is a no-op" || bad "empty path failed"

echo "== dlog_attach"
I="$TMP/item.md"
printf -- '---\ntype: ticket\n---\n\n## Context\n\nbody\n\n' > "$I"
dlog_attach "$T" "$I"
eq "the body above the section is kept" "body" "$(sed -n 7p "$I")"
eq "one section heading" 1 "$(grep -c '^## Decision Log$' "$I")"
grep -qF '| ci | fix run 1 | CI failed | abc1234 | pushed def5678 |' "$I" && ok "rows rendered as a table" || bad "table: $(cat "$I")"
eq "the section is last" "## Decision Log" "$(grep '^## ' "$I" | tail -1)"

dlog_row "$T" ready "marked ready" "checks passed" "PR #4" "ready"
dlog_attach "$T" "$I"
eq "a rerun replaces the section instead of stacking" 1 "$(grep -c '^## Decision Log$' "$I")"
grep -qF '| ready | marked ready |' "$I" && ok "the rerun carries the new row" || bad "new row missing"
eq "frontmatter untouched" "type: ticket" "$(sed -n 2p "$I")"

T2="$TMP/pipe.tsv"; dlog_row "$T2" p "x | y" w e r
I2="$TMP/item2.md"; printf 'body\n' > "$I2"; dlog_attach "$T2" "$I2"
grep -qF 'x \| y' "$I2" && ok "a pipe in a cell is escaped" || bad "pipe: $(cat "$I2")"

I3="$TMP/item3.md"; printf 'body\n' > "$I3"
dlog_attach "$TMP/missing.tsv" "$I3"
eq "no log: item unchanged" "body" "$(cat "$I3")"
dlog_attach "$T" "$TMP/missing.md"
[ -e "$TMP/missing.md" ] && bad "created a missing item" || ok "no item: nothing created"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
