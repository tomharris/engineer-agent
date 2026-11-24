#!/bin/bash
# jobs-draft.sh must not land a polled item in drafts/ when another copy of the same work
# (same type family + source_id) exists or appears while it is being drafted — the race behind
# a manual add-ticket and a poll both queueing one ticket.
#
# Run: bash tests/jobs-draft-rival.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DRAFT="${REPO_ROOT}/scripts/jobs-draft.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
export HOME="$TMP/home"
export TZ=UTC
Q="$EA_AGENT_DIR/queue"
mkdir -p "$TMP/bin" "$HOME"
export PATH="$TMP/bin:$PATH"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"
printf '#!/bin/bash\nexit 0\n' > "$TMP/notify"; chmod +x "$TMP/notify"
export EA_NOTIFY_BIN="$TMP/notify"

# claude stub: runs $TMP/during (if present) to simulate a concurrent writer, then drafts every
# manifest row by moving it to drafts/.
cat > "$TMP/claude" <<'EOF'
#!/bin/bash
echo run >> "$STUB/claude.calls"
[ -x "$STUB/during" ] && "$STUB/during"
for a in "$@"; do case "$a" in *"Read the manifest at "*) m="${a#*Read the manifest at }"; m="${m%% *}" ;; esac; done
while IFS="	" read -r _ p _; do
  [ -f "$p" ] || continue
  printf '\n## Draft Response\nPlan.\n' >> "$p"
  mv "$p" "$EA_AGENT_DIR/queue/drafts/"
done < "$m"
EOF
chmod +x "$TMP/claude"
export CLAUDE_BIN="$TMP/claude" STUB="$TMP"

reset() {
  rm -rf "$EA_AGENT_DIR" "$TMP/during" "$TMP/claude.calls" "$TMP/manifest.tsv"
  mkdir -p "$Q"/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state"
  printf 'projects: {}\n' > "$EA_AGENT_DIR/engineer.yaml"
}
item() {  # item <dir> <file> <type> <source_id>
  printf -- '---\ntype: %s\nsource: github\nsource_id: "%s"\ntitle: "t"\nstatus: incoming\nproject: "web"\n---\n## Context\nBody.\n' \
    "$3" "$4" > "$Q/$1/$2"
}
polled() {  # polled <file> <type> <source_id> — collector output: incoming/ file + manifest row
  item incoming "$1" "$2" "$3"
  printf 'create\t%s\t%s\tweb\t%s\t0\t0\tt\n' "$Q/incoming/$1" "$2" "$3" >> "$TMP/manifest.tsv"
}
during() { printf '#!/bin/bash\n%s\n' "$1" > "$TMP/during"; chmod +x "$TMP/during"; }
run() { bash "$DRAFT" --manifest "$TMP/manifest.tsv" --job web.github-issues >"$TMP/out" 2>&1; echo $?; }
fmv() { awk -v k="$2" -F': *' '$1==k{v=$2; gsub(/"/,"",v); print v; exit}' "$1"; }

SID="o/r#6347"
POLL="20261105-210001-ticket-gh-6347.md"
MANUAL="20261105-210026-ticket-gh-6347.md"

echo "== a completed copy that appears during drafting wins; the polled copy is rejected =="
reset
polled "$POLL" ticket "$SID"
during "printf -- '---\ntype: ticket\nsource_id: \"$SID\"\n---\n' > \"$Q/completed/$MANUAL\""
eq "exit 0 (resolved, not a drafting failure)" 0 "$(run)"
[ -f "$Q/drafts/$POLL" ] && bad "polled copy left in drafts/" || ok "polled copy not in drafts/"
eq "polled copy moved to rejected/ as rejected" rejected "$(fmv "$Q/rejected/$POLL" status 2>/dev/null)"
eq "rejected_reason names the surviving copy" \
  "duplicate of completed/$MANUAL (appeared while this copy was being drafted)" \
  "$(fmv "$Q/rejected/$POLL" rejected_reason 2>/dev/null)"

echo "== a live copy that exists before drafting wins, and the model is not started =="
reset
item incoming "$MANUAL" ticket "$SID"
polled "$POLL" ticket "$SID"
eq "exit 0" 0 "$(run)"
[ -e "$TMP/claude.calls" ] && bad "model ran with nothing left to draft" || ok "model not started"
eq "polled copy rejected" rejected "$(fmv "$Q/rejected/$POLL" status 2>/dev/null)"
eq "rejected_reason names the live copy" "duplicate of incoming/$MANUAL" \
  "$(fmv "$Q/rejected/$POLL" rejected_reason 2>/dev/null)"
[ -f "$Q/incoming/$MANUAL" ] && ok "live copy untouched" || bad "live copy moved"

echo "== the ticket family is one key: a ticket-investigation copy is a rival =="
reset
item drafts "$MANUAL" ticket-investigation "$SID"
polled "$POLL" ticket "$SID"
run >/dev/null
eq "polled ticket rejected next to a live investigation" rejected "$(fmv "$Q/rejected/$POLL" status 2>/dev/null)"

echo "== a completed copy that predates drafting is a human re-add: draft it =="
reset
item completed "20261001-120000-ticket-gh-6347.md" ticket "$SID"
polled "$POLL" ticket "$SID"
eq "exit 0" 0 "$(run)"
[ -f "$Q/drafts/$POLL" ] && ok "re-added item drafted" || bad "re-added item not drafted"
[ -e "$Q/rejected/$POLL" ] && bad "re-added item rejected" || ok "re-added item not rejected"

echo "== non-rivals: rejected copies, other types, other source_ids =="
reset
item rejected "$MANUAL" ticket "$SID"
item drafts "20261105-200000-qa-test-plan-gh-6347.md" qa-test-plan "$SID"
item drafts "20261105-200000-ticket-gh-6348.md" ticket "o/r#6348"
polled "$POLL" ticket "$SID"
during "printf -- '---\ntype: ticket\nsource_id: \"o/r#63470\"\n---\n' > \"$Q/completed/x.md\""
eq "exit 0" 0 "$(run)"
[ -f "$Q/drafts/$POLL" ] && ok "drafted despite non-rival items" || bad "non-rival blocked drafting"

echo "== one survivor among several polled rows: only the colliding row yields =="
reset
polled "$POLL" ticket "$SID"
polled "20261105-210001-ticket-gh-6349.md" ticket "o/r#6349"
during "printf -- '---\ntype: ticket\nsource_id: \"$SID\"\n---\n' > \"$Q/incoming/$MANUAL\""
eq "exit 0" 0 "$(run)"
[ -f "$Q/drafts/20261105-210001-ticket-gh-6349.md" ] && ok "unrelated row drafted" || bad "unrelated row not drafted"
eq "colliding row rejected" rejected "$(fmv "$Q/rejected/$POLL" status 2>/dev/null)"

echo
echo "jobs-draft-rival: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
