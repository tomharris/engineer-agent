#!/bin/bash
# Tests for scripts/lib-yaml.sh — the generic YAML reader the scripted pollers are built on.
#
# Background: the poll path is being moved out of prompt instructions and into deterministic
# scripts. Every one of those scripts reads config through this parser, so a silent parse failure
# here does not produce an error — it produces a poll that quietly finds nothing, unattended,
# forever. That is the exact failure shape CLAUDE.md catalogues (the ~/.claude/ storage guard that
# left the cron polling for a month while queueing nothing).
#
# Two cases below are not hypothetical; both were caught by running the parser against real files
# during development, and both had already been written in a form that returned an empty list with
# no error:
#
#   1. FLOW SEQUENCES. A real installed engineer.yaml mixes styles — exec.allowed_commands is a
#      block sequence, but github.repos / ignore_labels are flow ("[\"a\", \"b\"]"). lib-paths.sh's
#      yaml_project_list() handles block only and gets away with it because its one caller reads
#      exec.allowed_commands. Reused for github.repos it would poll zero repos.
#
#   2. MULTI-LINE FLOW SEQUENCES. config/engineer.example.yaml SHIPS agent.investigation
#      .title_keywords wrapped across two lines. A single-line-only reader silently disables the
#      entire title-keyword tier of references/ticket-kind.md for anyone who copied the example.
#
# Both are pinned here so a future simplification of the awk cannot quietly reintroduce them.
#
# No framework, mirroring tests/queue-dedup.test.sh and tests/turn-notify.test.sh.
# Run: bash tests/lib-yaml.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib-yaml.sh
source "${REPO_ROOT}/scripts/lib-yaml.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

eq() { # eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fixture.yaml"

# A fixture that deliberately mixes every shape a real engineer.yaml uses.
cat > "$FIX" <<'YAML'
# leading full-line comment
agent:
  branch_prefix: "ea"
  max_pr_files: 50
  bare_scalar: hello world
  trailing_comment: 42        # an inline comment must not become part of the value
  hash_in_quotes: "value # not a comment"
  empty_value:
  slack:
    method: "spy"
    mcp:
      server_id: "deep"
  investigation:
    jira_types: ["Spike", "Decision", "Task"]
    title_keywords: ["spike", "decision", "adr",
                     "investigate", "research"]
    github_labels: []
projects:
  alpha:
    path: "/tmp/alpha"
    github:
      owner: "acme"
      repos: ["alpha", "shared"]
      ignore_labels: []
      issues:
        assignee: "someone"
        labels: ["backend"]
    exec:
      allowed_commands:
        - "bin/rails"
        - "bundle"
  beta:                        # a slug header with a trailing comment
    path: "/tmp/beta"
    routing:
      keywords: ["void", "payroll"]
      description: >-
        PHP payroll workflows service. Orchestrator layer between
        treasury and everything else. Abbreviated "WF".
      paths: ["app/payroll/**"]
    literal_block: |
      line one
      line two
    jira:
      sources:
        - project: "ENG"
          components: ["api", "backend"]
          labels: []
        - project: "PLAT"
        - project: "OPS"
          labels: ["infra"]
      assignee: "me@example.com"
      statuses:
        - "To Do"
        - "In Progress"
  gamma:
    jira:
      project: "LEGACY"
YAML

echo "== scalars =="
eq "nested scalar"            "ea"       "$(yaml_get agent.branch_prefix "$FIX")"
eq "numeric scalar"           "50"       "$(yaml_get agent.max_pr_files "$FIX")"
eq "unquoted multi-word"      "hello world" "$(yaml_get agent.bare_scalar "$FIX")"
eq "inline comment stripped"  "42"       "$(yaml_get agent.trailing_comment "$FIX")"
eq "hash inside quotes kept"  "value # not a comment" "$(yaml_get agent.hash_in_quotes "$FIX")"
eq "3 levels deep"            "deep"     "$(yaml_get agent.slack.mcp.server_id "$FIX")"
eq "absent key is empty"      ""         "$(yaml_get agent.nope "$FIX")"

# The depth no helper in lib-paths.sh can reach — this is why lib-yaml.sh exists.
eq "4 levels: issues.assignee" "someone" "$(yaml_get projects.alpha.github.issues.assignee "$FIX")"

echo "== sequences =="
eq "block sequence"           "bin/rails bundle" \
   "$(yaml_get_list projects.alpha.exec.allowed_commands "$FIX" | tr '\n' ' ' | sed 's/ $//')"
# Regression: lib-paths.sh yaml_project_list() returns NOTHING for this shape.
eq "flow sequence"            "alpha shared" \
   "$(yaml_get_list projects.alpha.github.repos "$FIX" | tr '\n' ' ' | sed 's/ $//')"
eq "flow seq, nested deeper"  "backend" \
   "$(yaml_get_list projects.alpha.github.issues.labels "$FIX" | tr '\n' ' ' | sed 's/ $//')"
# Regression: the shipped example config wraps title_keywords across two lines.
eq "MULTI-LINE flow sequence" "spike decision adr investigate research" \
   "$(yaml_get_list agent.investigation.title_keywords "$FIX" | tr '\n' ' ' | sed 's/ $//')"
eq "multi-line item count"    "5" "$(yaml_get_list agent.investigation.title_keywords "$FIX" | wc -l | tr -d ' ')"

echo "== empty vs absent (references/ticket-kind.md replace-not-merge) =="
# An explicitly empty list DISABLES a tier; an absent key keeps the shipped default. Collapsing
# the two makes that rule unimplementable, so the distinction is part of the contract.
if yaml_has_list agent.investigation.github_labels "$FIX"; then ok "empty list reports PRESENT"; else bad "empty list should report PRESENT"; fi
if yaml_has_list agent.investigation.nonexistent  "$FIX"; then bad "absent list should report ABSENT"; else ok "absent list reports ABSENT"; fi
eq "empty list yields no items" "" "$(yaml_get_list agent.investigation.github_labels "$FIX")"
if yaml_has_list projects.alpha.github.ignore_labels "$FIX"; then ok "empty flow list PRESENT"; else bad "empty flow list should be PRESENT"; fi

echo "== block sequences of MAPPINGS (jira.sources) =="
# Previously refused outright: such an item emitted "[]#map-unsupported" because nothing read
# jira.sources while Jira polling was model-driven. scripts/poll-jira.sh reads it now.
#
# The property that matters is PAIRING. `sources` is a set whose elements each carry their own
# filters, and an N:M routing config depends on those staying attached to the right project key —
# flatten them and PLAT silently inherits ENG's component filter, which is a misroute that looks
# like a confident decision.
eq "element count"            "3" "$(yaml_seq_len projects.beta.jira.sources "$FIX")"
eq "element 0 key"            "ENG"  "$(yaml_get projects.beta.jira.sources[0].project "$FIX")"
eq "element 1 key"            "PLAT" "$(yaml_get projects.beta.jira.sources[1].project "$FIX")"
eq "element 2 key"            "OPS"  "$(yaml_get projects.beta.jira.sources[2].project "$FIX")"
eq "filters stay with their element" "api backend" \
   "$(yaml_get_list projects.beta.jira.sources[0].components "$FIX" | tr '\n' ' ' | sed 's/ $//')"
eq "element 2 labels"         "infra" \
   "$(yaml_get_list projects.beta.jira.sources[2].labels "$FIX" | tr '\n' ' ' | sed 's/ $//')"
# A catch-all element must have NO filters — not the previous element's.
eq "catch-all inherits nothing (components)" "" "$(yaml_get_list projects.beta.jira.sources[1].components "$FIX")"
eq "catch-all inherits nothing (labels)"     "" "$(yaml_get_list projects.beta.jira.sources[1].labels "$FIX")"
# An explicitly empty filter list is still PRESENT, same contract as everywhere else.
if yaml_has_list projects.beta.jira.sources[0].labels "$FIX"; then ok "empty filter list PRESENT"; else bad "empty filter list should be PRESENT"; fi

# A key at or above the sequence indent CLOSES it. Without that, `statuses` items would land
# inside sources[3] and both lists would be wrong — silently, with no parse error.
eq "sibling scalar after the sequence" "me@example.com" "$(yaml_get projects.beta.jira.assignee "$FIX")"
eq "sibling BLOCK LIST after the sequence" "To Do In Progress" \
   "$(yaml_get_list projects.beta.jira.statuses "$FIX" | tr '\n' ' ' | sed 's/ $//')"
eq "sequence did not absorb the sibling list" "3" "$(yaml_seq_len projects.beta.jira.sources "$FIX")"

# Backward compat: the legacy scalar form stays a scalar, so poll-jira can detect and normalize it.
eq "legacy jira.project scalar" "LEGACY" "$(yaml_get projects.gamma.jira.project "$FIX")"
eq "legacy form has no sequence" "0" "$(yaml_seq_len projects.gamma.jira.sources "$FIX")"
eq "absent sequence counts 0"    "0" "$(yaml_seq_len projects.alpha.jira.sources "$FIX")"

echo "== block scalars =="
# NOT hypothetical: a real installed engineer.yaml writes routing.description as a folded block
# scalar, and this reader used to return the literal indicator ">-" as the value. Tier 3b of
# references/routing-ladder.md has no other input, so the tier looked configured and was deciding
# on two characters of punctuation.
eq "folded block scalar is folded, not truncated" \
   'PHP payroll workflows service. Orchestrator layer between treasury and everything else. Abbreviated "WF".' \
   "$(yaml_get projects.beta.routing.description "$FIX")"
eq "literal block scalar" "line one line two" "$(yaml_get projects.beta.literal_block "$FIX")"
# The dedent that ends a block scalar must hand the line back to the enclosing mapping, or every
# key after a description silently vanishes.
eq "key after a block scalar is still reachable" "app/payroll/**" \
   "$(yaml_get_list projects.beta.routing.paths "$FIX" | tr '\n' ' ' | sed 's/ $//')"
eq "sibling of the block-scalar owner survives" "/tmp/beta" "$(yaml_get projects.beta.path "$FIX")"

echo "== keys =="
eq "project slugs"  "alpha beta gamma" "$(yaml_keys projects "$FIX" | tr '\n' ' ' | sed 's/ $//')"
eq "top-level keys" "agent projects" "$(yaml_keys "" "$FIX" | tr '\n' ' ' | sed 's/ $//')"
# A slug header carrying a trailing comment must still be seen as a mapping key. lib-paths.sh's
# projects.* family compares the raw trimmed line and misses exactly this.
eq "slug with trailing comment is reachable" "/tmp/beta" "$(yaml_get projects.beta.path "$FIX")"

echo "== isolation =="
eq "no such file is quiet"  "" "$(yaml_get agent.branch_prefix "$TMP/does-not-exist.yaml")"
eq "keyword list for beta"  "void payroll" \
   "$(yaml_get_list projects.beta.routing.keywords "$FIX" | tr '\n' ' ' | sed 's/ $//')"
# Scoping: alpha's keys must never leak into beta's namespace.
eq "no cross-project leak"  "" "$(yaml_get projects.beta.github.owner "$FIX")"

echo "== real shipped config (the shapes that actually ship) =="
EX="${REPO_ROOT}/config/engineer.example.yaml"
if [ -f "$EX" ]; then
  eq "example: title_keywords count" "10" "$(yaml_get_list agent.investigation.title_keywords "$EX" | wc -l | tr -d ' ')"
  eq "example: jira_types"           "Spike Decision Task" \
     "$(yaml_get_list agent.investigation.jira_types "$EX" | tr '\n' ' ' | sed 's/ $//')"
  eq "example: repos flow seq"       "my-api" \
     "$(yaml_get_list projects.my-api.github.repos "$EX" | tr '\n' ' ' | sed 's/ $//')"
  eq "example: deep mcp scalar"      "REPLACE_ME" "$(yaml_get agent.slack.mcp.server_id "$EX")"
  eq "example: jira.sources parses"  "1"   "$(yaml_seq_len projects.my-api.jira.sources "$EX")"
  eq "example: jira source key"      "ENG" "$(yaml_get projects.my-api.jira.sources[0].project "$EX")"
  eq "example: jira source filters"  "api backend" \
     "$(yaml_get_list projects.my-api.jira.sources[0].components "$EX" | tr '\n' ' ' | sed 's/ $//')"
  eq "example: statuses survive the sequence" "To Do In Progress" \
     "$(yaml_get_list projects.my-api.jira.statuses "$EX" | tr '\n' ' ' | sed 's/ $//')"
else
  bad "config/engineer.example.yaml missing"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
