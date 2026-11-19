#!/bin/bash
# Tests for scripts/draft-lint.sh: which text is linted per type, and each rule.
#
# Run: bash tests/draft-lint.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LINT="$REPO_ROOT/scripts/draft-lint.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"

# item <type> <body> — a queue file with that type and body.
item() { printf -- '---\ntype: %s\nstatus: drafted\n---\n\n## Context\n\nThe asker wrote — delve.\n\n%s\n' "$1" "$2" > "$TMP/i.md"; echo "$TMP/i.md"; }
lint() { "$LINT" "$1"; }
rules() { "$LINT" "$1" | cut -f1 | paste -sd, -; }

echo "== clean"
f="$(item slack-question '## Draft Response

### Proposed Slack Message

The retry loop never stops when the token expires. See `auth.ts:40`.

### Confidence

high')"
out="$(lint "$f")"; rc=$?
eq "a clean reply prints nothing" "" "$out"
eq "a clean reply exits 0" 0 "$rc"

echo "== slack-question scope"
f="$(item slack-question '## Draft Response

### Proposed Slack Message

Great question — we leverage the cache here.

### Claims

| a — b | Direct | x |')"
lint "$f" >/dev/null; eq "hits exit 1" 1 "$?"
eq "only the message is linted, each rule once" "em-dash,ai-word,chatbot" "$(rules "$f")"
eq "row shape: rule, line below the heading, match" "ai-word	2	leverage" "$(lint "$f" | grep ai-word)"

echo "== pr-review scope"
f="$(item pr-review '## Draft Response

### Review Summary

This is crucial to fix.

### Dismissed

- a.ts:1 — it is crucial — preference')"
eq "Dismissed is approver-only and not linted" "ai-word" "$(rules "$f")"

echo "== other types"
f="$(item standup '## Draft Response

In order to ship, I utilized the queue.

## Notes

delve — delve')"
eq "Draft Response linted, the next ## ends it" "ai-word,filler" "$(rules "$f")"

echo "== code is skipped"
f="$(item slack-question '## Draft Response

### Proposed Slack Message

Run `leverage --now` then:

```
x = "delve — here"
```

Done.')"
eq "inline and fenced code are ignored" "" "$(lint "$f")"

echo "== rules"
f="$(item slack-question '## Draft Response

### Proposed Slack Message

It'"'"'s not just a bug, it'"'"'s a design flaw.
She said “no”.
I hope this helps!
We delved into it.
The leveraged buyout is unrelated to fosterage.')"
out="$(lint "$f")"
eq "not-just" "not-just	2	not just X, Y" "$(printf '%s\n' "$out" | grep not-just)"
eq "curly quotes" "curly-quote	3	curly quote" "$(printf '%s\n' "$out" | grep curly)"
eq "chatbot" "chatbot	4	i hope this helps" "$(printf '%s\n' "$out" | grep chatbot)"
eq "inflected AI word" "ai-word	5	delved" "$(printf '%s\n' "$out" | grep '	5	')"
eq "whole words only: 'fosterage' is not 'foster'" "ai-word	6	leveraged" "$(printf '%s\n' "$out" | grep '	6	')"

f="$(item slack-question '## Draft Response

### Proposed Slack Message

Fosterage and underscoring_var are fine; so is unleveraged.')"
eq "whole words only: no hit inside a longer word" "" "$(lint "$f")"

echo "== edge cases"
f="$(item slack-question '## Draft Response

Nothing proposed.')"
eq "no Proposed Slack Message: nothing linted" "" "$(lint "$f")"
printf 'no frontmatter\n## Draft Response\n\ncrucial\n' > "$TMP/nofm.md"
eq "no frontmatter: Draft Response still linted" "ai-word" "$(rules "$TMP/nofm.md")"
"$LINT" "$TMP/missing.md" 2>/dev/null; eq "unreadable file exits 2" 2 "$?"
"$LINT" 2>/dev/null; eq "no argument exits 2" 2 "$?"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
