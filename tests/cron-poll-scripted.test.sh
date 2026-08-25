#!/bin/bash
# Tests for the scripted-collector integration in scripts/cron-poll.sh (Phase A).
#
# Two properties carry the whole change and are asserted here:
#
#   1. DENY-BY-DEFAULT. With agent.poll.scripted_sources absent — which is the state of every
#      existing install, including after a `/plugin update` that ships this code — the run must
#      behave exactly as before: the collector never runs, and the model is invoked. A change that
#      silently altered unattended behaviour on upgrade would be the worst possible outcome here.
#
#   2. THE MODEL IS SKIPPED when every configured source was collected by a script and nothing
#      needs drafting. This is the steady state of a healthy queue (the live receipt reads
#      items_queued: 0) and the entire point of the exercise. It is asserted by stubbing `claude`
#      and checking it was never executed.
#
# `claude` and `gh` are stubbed on PATH, following tests/slack-mcp.test.sh and
# tests/approval-listener.test.sh (which stub via CLAUDE_BIN/NOTIFY_BIN the same way).
#
# Run: bash tests/cron-poll-scripted.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CRON="${REPO_ROOT}/scripts/cron-poll.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state" "$TMP/bin"
export PATH="$TMP/bin:$PATH"
export GH_FIXTURE="$TMP/fixture"; : > "$GH_FIXTURE"
export CLAUDE_CALLS="$TMP/claude.calls"; : > "$CLAUDE_CALLS"
export PROMPT_CAPTURE="$TMP/last-prompt.txt"

cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
repo=""; assignee=""
while [ $# -gt 0 ]; do
  case "$1" in --repo) repo="$2"; shift 2 ;; --assignee) assignee="$2"; shift 2 ;; *) shift ;; esac
done
awk -F'|' -v r="$repo" -v a="$assignee" 'BEGIN{OFS="\t"} $1==r && $2==a { print $3,$4,$5,$6,$7,$8 }' "$GH_FIXTURE"
EOF
chmod +x "$TMP/bin/gh"

# The claude stub records that it ran and writes a receipt echoing the RUN_ID it was given, so the
# health check downstream is satisfied on the paths where the model is expected to run.
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/bash
echo "invoked" >> "$CLAUDE_CALLS"
prompt="${*: -1}"
rid="$(printf '%s' "$prompt" | sed -n 's/.*run_id: "\([^"]*\)".*/\1/p' | head -1)"
[ -n "$rid" ] || rid="$(printf '%s' "$prompt" | grep -o '[0-9]\{8\}T[0-9]\{6\}Z-[0-9]*' | head -1)"
printf 'run_id: "%s"\nfinished_at: "x"\nstatus: ok\nitems_queued: 0\nsources_polled: []\nskipped: []\nerrors: []\n' \
  "$rid" > "$EA_AGENT_DIR/state/last-poll-receipt.yaml"
printf '%s\n' "$prompt" > "$PROMPT_CAPTURE"
EOF
chmod +x "$TMP/bin/claude"
export CLAUDE_BIN="$TMP/bin/claude"
export NOTIFY_BIN=/bin/true

write_config() { # write_config <scripted_sources_line>
  cat > "$EA_AGENT_DIR/engineer.yaml" <<YAML
agent:
  max_issue_age_days: 0
$1
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "github-issues"
    github:
      owner: "acme"
      repos: ["only"]
      issues:
        assignee: "me"
YAML
}

run_cron() { : > "$CLAUDE_CALLS"; EA_POLL_SCRIPTED_SOURCES="${1:-}" bash "$CRON" >/dev/null 2>&1; }
claude_ran() { [ -s "$CLAUDE_CALLS" ]; }

echo "== 1. deny-by-default: no config key => unchanged behaviour =="
write_config ""
run_cron ""
if claude_ran; then ok "model IS invoked when the flag is absent"; else bad "model must still run when unconfigured"; fi
if [ -s "$EA_AGENT_DIR/state/poll-manifest.tsv" ]; then bad "collector must not run when unconfigured"; else ok "collector did not run"; fi

echo "== 2. flag on, nothing new => the model is SKIPPED entirely =="
: > "$GH_FIXTURE"   # zero open issues: the steady state of a healthy queue
run_cron "github-issues"
if claude_ran; then bad "model must NOT be invoked when there is no work"; else ok "model skipped entirely (the token win)"; fi

echo "== 2b. ...and the receipt is still written, from ground truth =="
R="$EA_AGENT_DIR/state/last-poll-receipt.yaml"
if [ -s "$R" ]; then ok "receipt written without a model"; else bad "receipt missing"; fi
eq "receipt status"       "ok" "$(sed -n 's/^status: *//p' "$R")"
eq "receipt items_queued" "0"  "$(sed -n 's/^items_queued: *//p' "$R")"
if grep -q 'alpha/github_issues' "$R"; then ok "configured source listed as polled"; else bad "polled source missing"; fi
# The skipped: bucket must still be populated, and it must never affect status.
if grep -q 'alpha/jira: tracker is' "$R"; then ok "skip reasons recorded"; else bad "skip reasons missing"; fi
# The run_id must match THIS run — that is what proves liveness rather than a stale receipt.
if grep -qE 'run_id: "[0-9]{8}T[0-9]{6}Z-[0-9]+"' "$R"; then ok "run_id is present and well-formed"; else bad "run_id malformed"; fi

echo "== 3. flag on, work found => the model IS invoked, and told what to draft =="
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
printf 'acme/only|me|7|%s|%s|%s||https://gh/7\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(b64 'A new issue')" "$(b64 'body')" > "$GH_FIXTURE"
run_cron "github-issues"
if claude_ran; then ok "model invoked when there is work"; else bad "model must run when items need drafting"; fi
if [ -s "$EA_AGENT_DIR/state/poll-manifest.tsv" ]; then ok "manifest non-empty"; else bad "manifest should list the new item"; fi
P="$PROMPT_CAPTURE"
if grep -q 'SCRIPTED:' "$P"; then ok "prompt carries the SCRIPTED directive"; else bad "SCRIPTED directive missing"; fi
if grep -q 'poll-manifest.tsv' "$P"; then ok "prompt names the manifest path"; else bad "manifest path not pinned in prompt"; fi
if grep -q 'Do NOT re-poll them' "$P"; then ok "prompt forbids re-polling scripted sources"; else bad "must forbid re-polling"; fi
# The item itself must already exist with full frontmatter — the model only adds the draft.
I="$(ls "$EA_AGENT_DIR/queue/incoming/"*gh-7* 2>/dev/null | head -1)"
if [ -n "$I" ]; then ok "collector wrote the queue item"; else bad "queue item missing"; fi
if [ -n "$I" ] && grep -q 'source_id: "acme/only#7"' "$I"; then ok "frontmatter complete before the model runs"; else bad "frontmatter incomplete"; fi

echo "== 4. an unscripted configured source keeps the model in the loop =="
# Slack is configured here but is NOT a scripted source, so even with zero new issues the model
# must still run — the skip is only ever safe when every configured source was scripted.
cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  max_issue_age_days: 0
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "github-issues"
    github:
      owner: "acme"
      repos: ["only"]
      issues:
        assignee: "me"
    slack:
      channels: ["C123"]
      keywords: ["@me"]
YAML
: > "$GH_FIXTURE"
run_cron "github-issues"
if claude_ran; then ok "model still runs when Slack is configured but unscripted"; else bad "must not skip with an unscripted source configured"; fi

echo "== 5. PR review configured but unscripted also keeps the model in the loop =="
# This is not hypothetical: every project in a real engineer.yaml sets github.review_requested_for,
# so `github` is a configured source everywhere. The all-or-nothing skip rule means scripting
# github-issues ALONE never makes a real install skippable — the PR collector is required too.
cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  max_issue_age_days: 0
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "github-issues"
    github:
      owner: "acme"
      repos: ["only"]
      review_requested_for: "me"
      issues:
        assignee: "me"
YAML
: > "$GH_FIXTURE"
run_cron "github-issues"
if claude_ran; then ok "model still runs when PR review is configured but unscripted"; else bad "must not skip while PR review is unscripted"; fi

echo "== 6. both GitHub sources scripted => a realistic config CAN skip the model =="
# This is the shape of a real engineer.yaml: PR review and issues both configured. With both
# collectors enabled and nothing new, the model must be skipped — this is the case that actually
# fires 96 times a day.
cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  max_issue_age_days: 0
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "github-issues"
    github:
      owner: "acme"
      repos: ["only"]
      review_requested_for: "me"
      ignore_labels: ["wip"]
      issues:
        assignee: "me"
YAML
: > "$GH_FIXTURE"
# Clear the queue first. Test 3 deliberately left an undrafted item in incoming/, and the resume
# sweep correctly re-emits it — which means the model IS still needed. That is the sweep working,
# not a bug, but it makes this case about a genuinely empty queue.
rm -f "$EA_AGENT_DIR"/queue/incoming/*.md
run_cron "github-issues github"
if claude_ran; then bad "both sources scripted and nothing new => model must be skipped"; else ok "realistic config skips the model"; fi
eq "receipt still ok" "ok" "$(sed -n 's/^status: *//p' "$EA_AGENT_DIR/state/last-poll-receipt.yaml")"
if grep -q 'alpha/github$' "$EA_AGENT_DIR/state/last-poll-receipt.yaml"; then ok "PR review listed as polled"; else bad "PR review missing from receipt"; fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
