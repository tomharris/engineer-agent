#!/bin/bash
# Regression test for the queue's one-file-per-source_id invariant.
#
# Background: polling produced two queue files for a single ticket. Two distinct mechanisms did it,
# and both were spec contradictions rather than script bugs:
#
#   1. Unrouted re-check. poll-jira step 7.3 says unrouted tickets are deliberately NOT added to
#      seen_tickets so they are "checked again on next poll until assigned". But step 5a says to
#      exclude any ticket whose source_id already exists in any queue file. Resolving that in favour
#      of re-checking, the poller re-polled an `_unrouted` item sitting in incoming/, routed it, and
#      wrote a NEW {timestamp}-ticket-KEY.md instead of updating the existing file. Observed on
#      WIRE-2190 with no human involved.
#
#   2. Updated-since-last_checked re-queue. poll-github-issues 5a says to exclude issues already in
#      a queue file, then immediately says to "Include issues that were previously seen but have
#      updatedAt newer than last_checked (re-queue for updated context)". The second rule wins for
#      any touched ticket. poll-jira carries the same escape hatch as "unless the ticket has new
#      comments or status changes since the last poll". This one is self-triggering: the agent
#      posting its own findings as a Jira comment bumps `updated`, which re-queues the ticket the
#      agent just finished.
#
# Neither mechanism is caught by anything today, because the filename carries a fresh timestamp, so
# a duplicate never collides on disk. This test asserts the invariant directly.
#
# No framework, mirroring tests/turn-notify.test.sh: an isolated queue dir, fixtures written by hand,
# assertions on the checker's exit status and output.
#
# Run: bash tests/queue-dedup.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/../scripts/queue-dedup-check.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

setup() {
  TMP="$(mktemp -d)"
  export EA_AGENT_DIR="$TMP/agent"
  QUEUE="$EA_AGENT_DIR/queue"
  mkdir -p "$QUEUE"/{incoming,drafts,completed,rejected}
}

teardown() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }

# item <dir> <filename> <source_id> [status] [project] [type]
# `type` defaults to `ticket`; pass it explicitly when the fixture models another item type, since
# the invariant is keyed on (type, source_id) and a mismatched type silently changes the key.
item() {
  local dir="$1" name="$2" sid="$3" status="${4:-drafted}" project="${5:-payroll-gateway}" typ="${6:-ticket}"
  cat > "$QUEUE/$dir/$name" <<EOF
---
type: $typ
source: jira
source_id: "$sid"
title: "Fixture for $sid"
status: $status
project: "$project"
ticket_key: "$sid"
---

## Context
Fixture body.
EOF
}

echo "queue-dedup-check.sh"

# ---------------------------------------------------------------------------
echo "clean queue"
setup
item incoming 20260820-140001-ticket-WIRE-1001.md WIRE-1001 incoming _unrouted
item drafts   20260820-140001-ticket-WIRE-1002.md WIRE-1002
item completed 20260820-140001-ticket-WIRE-1003.md WIRE-1003 completed
item rejected  20260820-140001-ticket-WIRE-1004.md WIRE-1004 rejected
if bash "$CHECK" >/dev/null 2>&1; then
  ok "distinct source_ids across all four dirs pass"
else
  bad "clean queue should exit 0"
fi
teardown

# ---------------------------------------------------------------------------
# Mechanism 1: the WIRE-2190 case. An _unrouted item in incoming/ plus a routed copy the next poll
# minted as a new file. This is the one that needs no human to reproduce.
echo "mechanism 1 — unrouted re-check duplicate"
setup
item incoming 20260820-140001-ticket-WIRE-2190.md WIRE-2190 incoming _unrouted
item drafts   20260820-150001-ticket-WIRE-2190.md WIRE-2190 drafted payroll-gateway
out="$(bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
  ok "duplicate across incoming/ and drafts/ is detected (exit 1)"
else
  bad "expected exit 1, got $rc (127 = checker missing, so this is not detection)"
fi
if printf '%s' "$out" | grep -q "WIRE-2190"; then
  ok "names the offending source_id"
else
  bad "output does not name WIRE-2190: $out"
fi
if printf '%s' "$out" | grep -q "incoming/20260820-140001-ticket-WIRE-2190.md" \
   && printf '%s' "$out" | grep -q "drafts/20260820-150001-ticket-WIRE-2190.md"; then
  ok "names both offending files"
else
  bad "output does not name both files: $out"
fi
teardown

# ---------------------------------------------------------------------------
# Mechanism 2: the WIRE-2189 case. Terminal state must be absorbing — a completed item that gets
# re-drafted is the self-triggering loop, since the agent's own comment bumps `updated`.
echo "mechanism 2 — completed item re-drafted"
setup
item completed 20260820-140001-ticket-WIRE-2189.md WIRE-2189 completed
item drafts    20260820-150001-ticket-WIRE-2189.md WIRE-2189 drafted
out="$(bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
  ok "re-draft of a completed item is detected (exit 1)"
else
  bad "expected exit 1, got $rc (127 = checker missing, so this is not detection)"
fi
if printf '%s' "$out" | grep -qi "completed"; then
  ok "flags that the surviving copy is already terminal"
else
  bad "output does not mention the terminal state: $out"
fi
teardown

# ---------------------------------------------------------------------------
# DELIBERATE NON-CASE: "a rejected item was re-drafted" is NOT asserted here.
#
# It is indistinguishable on disk from "a duplicate was correctly resolved by rejecting the
# redundant copy" — both are one rejected file plus one live file for the same source_id, and
# timestamps don't separate them either (the rejected copy may legitimately be older or newer).
#
# Since only one of the two can be flagged, this check flags neither and treats rejected/ as pure
# disposal (see the section below). Rationale: re-drafting a rejected item is already forbidden by
# queue-reconciliation.md's absorbing-terminal rule, and if it slips through, the human sees a draft
# for something they declined and rejects it again — visible and self-correcting. A check that is
# permanently red on every already-resolved duplicate is not: it gets ignored, taking the live-
# duplicate signal down with it.

# ---------------------------------------------------------------------------
# A source_id is only unique per tracker identity, and non-ticket types share the queue. Two
# different types legitimately reference one ticket: a `ticket` item and its later `qa-test-plan`.
# That is NOT a duplicate and must not trip the check.
echo "type-aware: ticket + qa-test-plan for one ticket_key"
setup
cat > "$QUEUE/completed/20260820-140001-ticket-WIRE-2191.md" <<'EOF'
---
type: ticket
source: jira
source_id: "WIRE-2191"
status: completed
project: "payroll-treasury"
---
EOF
cat > "$QUEUE/drafts/20260820-143037-qa-test-plan-WIRE-2191.md" <<'EOF'
---
type: qa-test-plan
source: jira
source_id: "WIRE-2191"
status: drafted
project: "payroll-treasury"
---
EOF
if bash "$CHECK" >/dev/null 2>&1; then
  ok "ticket + qa-test-plan on one source_id is not a duplicate"
else
  bad "type-aware check should allow ticket + qa-test-plan (regression: over-eager matching)"
fi
teardown

# ---------------------------------------------------------------------------
# rejected/ is the DISPOSAL path: rejecting the redundant copy is exactly how a human resolves a
# duplicate. So a rejected sibling must not count against the invariant — otherwise the check fires
# forever on already-resolved duplicates, and a permanently-red check is one nobody reads.
echo "rejected/ is disposal, not a live duplicate"
setup
item completed 20260820-140001-ticket-WIRE-2189.md WIRE-2189 completed
item rejected  20260820-150001-ticket-WIRE-2189.md WIRE-2189 rejected
if bash "$CHECK" >/dev/null 2>&1; then
  ok "completed + rejected is a resolved duplicate, not a violation"
else
  bad "resolved duplicate (completed + rejected) must pass, or the check cries wolf forever"
fi
teardown

setup
item drafts   20260820-150001-ticket-WIRE-2190.md WIRE-2190 drafted
item rejected 20260820-140001-ticket-WIRE-2190.md WIRE-2190 rejected
if bash "$CHECK" >/dev/null 2>&1; then
  ok "drafts + rejected is a resolved duplicate, not a violation"
else
  bad "resolved duplicate (drafts + rejected) must pass"
fi
teardown

# Two rejected copies and nothing live: still resolved.
setup
item rejected 20260820-140001-ticket-WIRE-2199.md WIRE-2199 rejected
item rejected 20260820-150001-ticket-WIRE-2199.md WIRE-2199 rejected
if bash "$CHECK" >/dev/null 2>&1; then
  ok "two rejected copies with nothing live is not a violation"
else
  bad "all-rejected duplicates must pass"
fi
teardown

# ---------------------------------------------------------------------------
# But two COMPLETED copies is a real violation: the work was queued and acted on twice. This is the
# shape found in the live queue (BUGS-35224 completed three times), and it is the strongest evidence
# the duplicate bug is long-standing rather than incidental.
echo "two completed copies — work actually done twice"
setup
item completed 20260429-120000-qa-test-plan-BUGS-35224.md BUGS-35224 completed payroll-gateway qa-test-plan
item completed 20260608-100226-qa-test-plan-BUGS-35224.md BUGS-35224 completed payroll-gateway qa-test-plan
bash "$CHECK" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then
  ok "duplicate completed items are still a violation"
else
  bad "expected exit 1, got $rc — two completed copies means the work ran twice"
fi
teardown

# ---------------------------------------------------------------------------
# Historical duplicates cannot be cleaned without falsifying the record: if a QA plan really was
# completed three times, all three completions are true. Without a baseline the check would be red
# forever on immutable history — the dead-check failure again. So known-historical pairs are
# baselined, and the suppression is always REPORTED so it can never rot invisibly.
echo "baseline suppression"
setup
mkdir -p "$EA_AGENT_DIR/state"
item completed 20260429-120000-qa-test-plan-BUGS-35224.md BUGS-35224 completed payroll-gateway qa-test-plan
item completed 20260608-100226-qa-test-plan-BUGS-35224.md BUGS-35224 completed payroll-gateway qa-test-plan
printf 'qa-test-plan\tBUGS-35224\n' > "$EA_AGENT_DIR/state/queue-dedup-baseline.tsv"
out="$(bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a baselined pair does not fail the check"
else
  bad "expected exit 0 for a baselined pair, got $rc: $out"
fi
if printf '%s' "$out" | grep -qi "suppress"; then
  ok "suppression is reported, not silent"
else
  bad "baseline suppression must be visible in output: $out"
fi

# A NEW duplicate must still fail even while a baseline exists — otherwise baselining would
# silently disable the whole check.
item drafts 20260820-150001-ticket-WIRE-2190.md WIRE-2190 drafted
item incoming 20260820-140001-ticket-WIRE-2190.md WIRE-2190 incoming _unrouted
bash "$CHECK" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then
  ok "a non-baselined duplicate still fails while a baseline is present"
else
  bad "expected exit 1 for a fresh duplicate alongside a baseline, got $rc"
fi
teardown

# ---------------------------------------------------------------------------
echo "--update-baseline"
setup
mkdir -p "$EA_AGENT_DIR/state"
item completed 20260429-120000-qa-test-plan-BUGS-35224.md BUGS-35224 completed payroll-gateway qa-test-plan
item completed 20260608-100226-qa-test-plan-BUGS-35224.md BUGS-35224 completed payroll-gateway qa-test-plan
bash "$CHECK" --update-baseline >/dev/null 2>&1
if grep -q "BUGS-35224" "$EA_AGENT_DIR/state/queue-dedup-baseline.tsv" 2>/dev/null; then
  ok "--update-baseline records the current violations"
else
  bad "--update-baseline did not write the baseline file"
fi
if bash "$CHECK" >/dev/null 2>&1; then
  ok "check is green immediately after --update-baseline"
else
  bad "check should pass after baselining current state"
fi
teardown

# ---------------------------------------------------------------------------
echo "empty queue"
setup
if bash "$CHECK" >/dev/null 2>&1; then
  ok "empty queue passes"
else
  bad "empty queue should exit 0"
fi
teardown

# ---------------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
