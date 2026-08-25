#!/bin/bash
# Tests for scripts/ea-config.sh — the normalizer that turns engineer.yaml into effective config.
#
# Background: the rules exercised here are currently written as prose in the poll skills, and each
# is a rule the model re-derives on every 15-minute poll:
#
#   - tracker inference          (poll-github-issues step 3, poll-jira step 3)
#   - investigation REPLACE-not-merge, where [] DISABLES a tier and absent keeps the shipped
#     default                    (references/ticket-kind.md)
#   - effective Slack workspace, project overriding agent   (poll-slack step 1)
#   - the per-source configured/skipped decision that fills the receipt's `skipped:` bucket,
#     which "MUST NOT affect status"                        (cron-poll.sh prompt)
#
# The last one matters most: cron-poll.sh's prompt asks the MODEL to sort every source into one of
# three buckets. Getting that wrong turns a normal quiet poll into a `status: error` page, or worse
# hides a real failure inside `skipped:`. It is pure bookkeeping over config.
#
# Run: bash tests/ea-config.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EA="${REPO_ROOT}/scripts/ea-config.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
mkdir -p "$EA_AGENT_DIR"

cat > "$EA_AGENT_DIR/engineer.yaml" <<'YAML'
agent:
  # branch_prefix and max_pr_files deliberately omitted -> defaults must apply
  max_issue_age_days: 30
  slack:
    workspace: "globalws"
  investigation:
    jira_types: ["Spike"]              # narrows the shipped default globally
  notify:
    ntfy:
      topic: "SECRET-TOPIC"
      command_topic: "SECRET-CMD"
      auth_token: "tk_SECRET"
projects:
  explicit-jira:
    path: "/tmp/a"
    tracker: "jira"
    jira:
      assignee: "me@example.com"
    slack:
      channels: ["C1"]
      workspace: "projectws"
  inferred-jira:
    path: "/tmp/b"
    jira:
      assignee: "me@example.com"
  inferred-gh:
    path: "/tmp/c"
    github:
      owner: "acme"
      repos: ["thing"]
      review_requested_for: "me"
      issues:
        assignee: "me"
        labels: ["backend"]
  no-tracker:
    path: "/tmp/d"
    github:
      owner: "acme"
      repos: ["other"]
      review_requested_for: "me"
  overridden:
    path: "/tmp/e"
    tracker: "github-issues"
    github:
      owner: "acme"
      repos: ["ov"]
      review_requested_for: "me"
      issues:
        assignee: "me"
    investigation:
      jira_types: ["Decision", "Discovery"]   # project REPLACES the global narrow
      title_keywords: []                      # explicitly DISABLES the title tier
    slite:
      doc_labels: ["needs-review"]
YAML

D="$("$EA" dump)"
g()  { printf '%s\n' "$D" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }
gl() { printf '%s\n' "$D" | awk -v p="$1[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}' | tr '\n' ' ' | sed 's/ $//'; }

echo "== agent defaults =="
eq "branch_prefix default"    "engineer-agent" "$(g agent.branch_prefix)"
eq "max_pr_files default"     "50"             "$(g agent.max_pr_files)"
eq "max_issue_age_days set"   "30"             "$(g agent.max_issue_age_days)"
eq "slack.method default"     "spy"            "$(g agent.slack.method)"
eq "slack.bin default"        "spy"            "$(g agent.slack.bin)"

echo "== tracker inference =="
eq "explicit tracker wins"    "jira"           "$(g projects.explicit-jira.tracker)"
eq "jira section infers jira" "jira"           "$(g projects.inferred-jira.tracker)"
eq "github.issues infers gh"  "github-issues"  "$(g projects.inferred-gh.tracker)"
eq "neither infers none"      "none"           "$(g projects.no-tracker.tracker)"

echo "== investigation: REPLACE, not merge (references/ticket-kind.md) =="
# Global narrows the shipped ["Spike","Decision","Task"] to just ["Spike"].
eq "global override replaces"  "Spike"              "$(gl projects.inferred-gh.investigation.jira_types)"
# Project replaces the GLOBAL, not the shipped default, and does not merge with it.
eq "project replaces global"   "Decision Discovery" "$(gl projects.overridden.investigation.jira_types)"
# A key nobody overrode still gets the full shipped default.
eq "unoverridden = shipped"    "spike research investigation decision adr rfc discovery" \
   "$(gl projects.inferred-gh.investigation.github_labels)"
# An explicitly empty list DISABLES that tier — it must NOT fall back to the shipped default.
eq "[] disables the tier"      ""                   "$(gl projects.overridden.investigation.title_keywords)"
eq "other project keeps title" "spike decision adr rfc investigate research evaluate compare assess determine" \
   "$(gl projects.inferred-gh.investigation.title_keywords)"

echo "== effective slack workspace (project overrides agent) =="
eq "project workspace wins" "projectws" "$(g projects.explicit-jira.slack.workspace)"
eq "falls back to agent"    "globalws"  "$(g projects.inferred-gh.slack.workspace)"
eq "ignore_bots defaults"   "true"      "$(g projects.inferred-gh.slack.ignore_bots)"

echo "== per-source configured/skipped (fills the receipt's skipped: bucket) =="
eq "gh PRs configured"       "configured" "$(g projects.inferred-gh.source.github)"
eq "gh issues configured"    "configured" "$(g projects.inferred-gh.source.github_issues)"
eq "gh issues need tracker"  "skipped:tracker is none" "$(g projects.no-tracker.source.github_issues)"
eq "jira skipped w/ reason"  "skipped:tracker is github-issues, no jira section" "$(g projects.inferred-gh.source.jira)"
eq "jira configured"         "configured" "$(g projects.explicit-jira.source.jira)"
eq "slack empty channels"    "skipped:slack.channels is empty" "$(g projects.inferred-gh.source.slack)"
eq "slack configured"        "configured" "$(g projects.explicit-jira.source.slack)"
eq "slite absent"            "skipped:no slite section configured" "$(g projects.inferred-gh.source.slite)"
eq "slite configured"        "configured" "$(g projects.overridden.source.slite)"
# A project with no github section at all must skip PR review, not error.
eq "no github -> skip PRs"   "skipped:no github section configured" "$(g projects.explicit-jira.source.github)"

echo "== security: secrets must never reach the normalized view =="
# On public ntfy.sh the command_topic is effectively a password for remote approval. A poller has
# no use for it (notify.sh resolves its own settings), so it must not appear in output that gets
# logged or cached.
if printf '%s\n' "$D" | grep -qi 'SECRET\|auth_token\|command_topic'; then
  bad "ntfy credentials leaked into the dump"
else ok "ntfy credentials excluded from the dump"; fi

echo "== lists and slugs =="
eq "project list" "explicit-jira inferred-gh inferred-jira no-tracker overridden" \
   "$("$EA" projects | sort | tr '\n' ' ' | sed 's/ $//')"
eq "repos flow seq" "thing" "$(gl projects.inferred-gh.github.repos)"
eq "sources subcommand" "configured" "$("$EA" sources inferred-gh | awk -F'\t' '$1=="github"{print $2}')"

echo "== drift guard: shipped defaults vs config/engineer.example.yaml =="
# ea-config.sh hardcodes the shipped investigation defaults. references/ticket-kind.md and the
# example config state them too. If someone edits the example without editing the script (or the
# reverse), the tiers silently change for every install that never overrode them.
EX="${REPO_ROOT}/config/engineer.example.yaml"
# shellcheck source=../scripts/lib-yaml.sh
source "${REPO_ROOT}/scripts/lib-yaml.sh"
for key in jira_types github_labels title_keywords; do
  want="$(yaml_get_list "agent.investigation.$key" "$EX" | tr '\n' ' ' | sed 's/ $//')"
  have="$(grep -E "^DEFAULT_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')=" "$EA" | sed 's/^[^=]*="//; s/"$//')"
  eq "example matches script: $key" "$want" "$have"
done

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
