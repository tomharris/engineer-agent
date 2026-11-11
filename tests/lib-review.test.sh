#!/bin/bash
# Tests for scripts/lib-review.sh: the Jira authorship check and severity ranking.
# Run: bash tests/lib-review.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$REPO_ROOT/scripts/lib-review.sh"

TRUSTED="$(printf 'acc-tom\nacc-jer\n')"
issue() {  # issue <creator> <description-editor> [total]
  jq -n --arg c "$1" --arg e "$2" --argjson t "${3:-1}" '{fields: {creator: {accountId: $c}},
    changelog: {total: $t, histories: [{author: {accountId: $e}, items: [{fieldId: "description"}]}]}}' > "$TMP/i.json"
}

echo "== jira_untrusted_reason"
issue acc-tom acc-jer
eq "trusted creator and editor" "" "$(jira_untrusted_reason "$TMP/i.json" "$TRUSTED")"
issue acc-eve acc-jer
eq "untrusted creator" "created by acc-eve, not a trusted author" "$(jira_untrusted_reason "$TMP/i.json" "$TRUSTED")"
issue acc-tom acc-eve
eq "untrusted description editor" "edited by acc-eve, not a trusted author" "$(jira_untrusted_reason "$TMP/i.json" "$TRUSTED")"
issue acc-tom acc-jer 5
eq "truncated changelog" "changelog truncated; cannot verify edits" "$(jira_untrusted_reason "$TMP/i.json" "$TRUSTED")"
eq "no trusted list" "no trusted_authors configured" "$(jira_untrusted_reason "$TMP/i.json" "")"

echo "== security_introduced"
printf 'app/a.py\n' > "$TMP/changed"
echo '[{"file":"/abs/wt/app/a.py","severity":"high"},{"file":"a/app/a.py"},{"file":"other/b.py"},{"file":"xapp/a.py"}]' > "$TMP/f.json"
eq "absolute and a/-prefixed paths of a changed file count" '["/abs/wt/app/a.py","a/app/a.py"]' "$(security_introduced "$TMP/f.json" "$TMP/changed" | jq -c 'map(.file)')"

echo "== severity_rank"
eq "Critical" 4 "$(severity_rank Critical)"
eq "MEDIUM" 2 "$(severity_rank MEDIUM)"
eq "low" 1 "$(severity_rank low)"
eq "unknown counts as high" 3 "$(severity_rank Moderate)"
eq "missing counts as high" 3 "$(severity_rank "")"

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
