#!/bin/bash
# Tests for scripts/migrate-poll-to-jobs.sh: global-poll coverage -> per-project watch jobs.
#
# `crontab` and `launchctl` are PATH shims backed by files in the sandbox; the launchd plist lives
# under the sandbox $HOME. The clock is frozen with EA_NOW.
#
# Run: bash tests/migrate-poll-to-jobs.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIG="${REPO_ROOT}/scripts/migrate-poll-to-jobs.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — [$2] not in [$3]"; fi; }
hasnt() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 — [$2] unexpectedly in output"; else ok "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
export HOME="$TMP/home"
export TZ=UTC
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/security"
cat > "$TMP/bin/crontab" <<EOF
#!/bin/bash
f="$TMP/crontab.txt"
if [ "\${1:-}" = "-l" ]; then [ -f "\$f" ] || exit 1; cat "\$f"; exit 0; fi
if [ "\${1:-}" = "-" ]; then cat > "\$f"; exit 0; fi
exit 2
EOF
cat > "$TMP/bin/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/launchctl.log"
EOF
chmod +x "$TMP/bin/"*

T0=1794218400   # Monday 2026-11-09 10:00:00 UTC
export EA_NOW="$T0"
CFG="$EA_AGENT_DIR/engineer.yaml"
STATE="$EA_AGENT_DIR/state/jobs"
PLIST="$HOME/Library/LaunchAgents/engineer-agent-poll.plist"
POLL_CRON="*/10 * * * * PATH=/usr/bin:/bin /opt/engineer-agent/scripts/cron-poll.sh"
JOBS_CRON="* * * * * PATH=/usr/bin:/bin /opt/engineer-agent/scripts/jobs-tick.sh"

reset() {
  rm -rf "$EA_AGENT_DIR" "$HOME" "$TMP/crontab.txt" "$TMP/launchctl.log"
  mkdir -p "$EA_AGENT_DIR/state" "$HOME"
}

# enumerate <cfg> — "slug|id|integration|action|every|hours" per job, from the real config reader.
enumerate() {
  ( . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-jobs.sh"; jobs_enumerate ) \
    | cut -d'|' -f1,3,4,5,6,7
}

TWO_PROJECTS='projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "jira"
    jira:
      project: "ENG"
    github:
      owner: acme
      repos: [web]
      review_requested_for: tom
    slack:
      channels: ["C1"]
    jobs:
      - id: sw
        integration: slack
        action: watch
        every: 5m
        exclusive: true
        watch: [channels]

  beta:
    path: "/tmp/beta"
    github:
      owner: acme
      repos: [api]
      issues:
        assignee: tom
    slack:
      channels: ["C2"]
    # trailing comment stays with beta
'

LAST_POLL='jira_projects:
  ENG:
    last_checked: "2026-11-08T09:00:00Z"
  OPS:
    last_checked: "2026-11-08T09:30:00Z"
github_repos:
  acme/api:
    last_checked: "2026-11-08T08:00:00Z"
  acme/web:
    last_checked: "2026-11-08T08:15:00Z"
projects:
  alpha:
    github:
      last_checked: "2026-11-08T07:00:00Z"
      seen_prs:
        - "acme/web#1"
    jira:
      last_checked: "2026-11-08T09:00:00Z"
    slack:
      last_checked_ts: "1794000000.000100"
  beta:
    github_issues:
      last_checked: "2026-11-08T08:00:00Z"
    slack:
      last_checked_ts: "1794000000.000200"
      mentions_ts: "1794000000.000300"
'

echo "== 1. dry run: prints the diff, changes nothing =="
reset
printf '%s' "$TWO_PROJECTS" > "$CFG"
printf '%s' "$LAST_POLL" > "$EA_AGENT_DIR/state/last-poll.yaml"
printf '%s\n' "$POLL_CRON" > "$TMP/crontab.txt"
cp "$CFG" "$TMP/orig.yaml"
out="$(bash "$MIG" 2>&1)"; rc=$?
eq "dry run exits 0" 0 "$rc"
has "reports the detected poll schedule" "Global poll: crontab, every 10m" "$out"
has "diff adds alpha's github job" "+      - id: github-watch" "$out"
has "diff adds beta's slack job" "+      - id: slack-watch" "$out"
has "diff drops exclusive" "-        exclusive: true" "$out"
has "lists the state seeding" "would seed state/jobs/alpha.jira-watch.state.yaml (2 keys from last-poll.yaml)" "$out"
has "says the poll would be removed" "would remove the global poll (crontab entry)" "$out"
has "points at --apply" "Dry run. Re-run with --apply" "$out"
if cmp -s "$TMP/orig.yaml" "$CFG"; then ok "config untouched"; else bad "config changed by dry run"; fi
eq "no state files written" "" "$(ls "$STATE" 2>/dev/null)"
eq "crontab untouched" "$POLL_CRON" "$(cat "$TMP/crontab.txt")"

echo "== 2. --apply refuses while the jobs dispatcher is not installed =="
out="$(bash "$MIG" --apply 2>&1)"; rc=$?
eq "exit 1" 1 "$rc"
has "says why" "the jobs dispatcher is not installed; run scripts/install-jobs.sh first" "$out"
if cmp -s "$TMP/orig.yaml" "$CFG"; then ok "config untouched"; else bad "config changed"; fi
eq "poll left installed" "$POLL_CRON" "$(cat "$TMP/crontab.txt")"

echo "== 3. --apply: exact jobs, backup, seeded state, poll removed =="
printf '%s\n%s\n' "$POLL_CRON" "$JOBS_CRON" > "$TMP/crontab.txt"
out="$(bash "$MIG" --apply 2>&1)"; rc=$?
eq "apply exits 0" 0 "$rc"
want='projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "jira"
    jira:
      project: "ENG"
    github:
      owner: acme
      repos: [web]
      review_requested_for: tom
    slack:
      channels: ["C1"]
    jobs:
      - id: sw
        integration: slack
        action: watch
        every: 5m
        watch: [channels]
      - id: github-watch
        integration: github
        action: watch
        every: 10m
      - id: jira-watch
        integration: jira
        action: watch
        every: 10m

  beta:
    path: "/tmp/beta"
    github:
      owner: acme
      repos: [api]
      issues:
        assignee: tom
    slack:
      channels: ["C2"]
    jobs:
      - id: github-issues-watch
        integration: github-issues
        action: watch
        every: 10m
      - id: slack-watch
        integration: slack
        action: watch
        every: 10m
        watch: [channels]
    # trailing comment stays with beta'
eq "engineer.yaml gains exactly the missing watch jobs" "$want" "$(cat "$CFG")"
eq "jobs as the config reader sees them" "alpha|sw|slack|watch|5m|
alpha|github-watch|github|watch|10m|
alpha|jira-watch|jira|watch|10m|
beta|github-issues-watch|github-issues|watch|10m|
beta|slack-watch|slack|watch|10m|" "$(enumerate)"
if cmp -s "$TMP/orig.yaml" "$CFG.bak-$T0"; then ok "backup holds the original"; else bad "no/wrong backup at $CFG.bak-$T0"; fi
eq "github state: alpha's github subtree only" 'projects:
  alpha:
    github:
      last_checked: "2026-11-08T07:00:00Z"
      seen_prs:
        - "acme/web#1"' "$(cat "$STATE/alpha.github-watch.state.yaml" 2>&1)"
eq "jira state: the project's jira subtree and its key's watermark" 'jira_projects:
  ENG:
    last_checked: "2026-11-08T09:00:00Z"
projects:
  alpha:
    jira:
      last_checked: "2026-11-08T09:00:00Z"' "$(cat "$STATE/alpha.jira-watch.state.yaml" 2>&1)"
eq "github-issues state: the project's subtree and its repo's watermark" 'github_repos:
  acme/api:
    last_checked: "2026-11-08T08:00:00Z"
projects:
  beta:
    github_issues:
      last_checked: "2026-11-08T08:00:00Z"' "$(cat "$STATE/beta.github-issues-watch.state.yaml" 2>&1)"
eq "slack state: every slack cutoff" 'projects:
  beta:
    slack:
      last_checked_ts: "1794000000.000200"
      mentions_ts: "1794000000.000300"' "$(cat "$STATE/beta.slack-watch.state.yaml" 2>&1)"
eq "an existing job gets no seeded state" "no" "$([ -e "$STATE/alpha.sw.state.yaml" ] && echo yes || echo no)"
eq "poll crontab entry removed, dispatcher kept" "$JOBS_CRON" "$(cat "$TMP/crontab.txt")"
has "reports the removal" "removed the global poll (crontab entry)" "$out"

echo "== 4. a second --apply is a no-op =="
cp "$CFG" "$TMP/after1.yaml"
sums1="$(cd "$STATE" && cksum *.state.yaml)"
export EA_NOW=$((T0 + 60))
out="$(bash "$MIG" --apply 2>&1)"; rc=$?
export EA_NOW="$T0"
eq "exit 0" 0 "$rc"
has "says nothing to do" "Nothing to migrate" "$out"
if cmp -s "$TMP/after1.yaml" "$CFG"; then ok "config unchanged"; else bad "config changed on second apply"; fi
eq "no second backup" "engineer.yaml.bak-$T0" "$(cd "$EA_AGENT_DIR" && ls engineer.yaml.bak-* | tr '\n' ' ' | sed 's/ $//')"
eq "state files unchanged" "$sums1" "$(cd "$STATE" && cksum *.state.yaml)"

echo "== 5. an existing state file is never overwritten =="
reset
printf '%s' "$TWO_PROJECTS" > "$CFG"
printf '%s' "$LAST_POLL" > "$EA_AGENT_DIR/state/last-poll.yaml"
printf '%s\n' "$JOBS_CRON" > "$TMP/crontab.txt"
mkdir -p "$STATE"; printf 'mine: "1"\n' > "$STATE/alpha.jira-watch.state.yaml"
out="$(bash "$MIG" --apply 2>&1)"; rc=$?
eq "exit 0" 0 "$rc"
eq "existing state kept" 'mine: "1"' "$(cat "$STATE/alpha.jira-watch.state.yaml")"
has "says it kept it" "kept existing state/jobs/alpha.jira-watch.state.yaml" "$out"
has "no poll installed is reported" "Global poll: none installed" "$out"

echo "== 6. schedule detection =="
ONE='projects:
  solo:
    path: "/tmp/solo"
    slack:
      channels: ["C9"]
'
plist() { mkdir -p "$(dirname "$PLIST")"; printf '<?xml version="1.0"?>\n<plist version="1.0">\n<dict>\n%s\n</dict>\n</plist>\n' "$1" > "$PLIST"; }
reset; printf '%s' "$ONE" > "$CFG"
plist '    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>3</integer></dict>
        <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>3</integer></dict>
        <dict><key>Hour</key><integer>11</integer><key>Minute</key><integer>3</integer></dict>
    </array>'
out="$(bash "$MIG" 2>&1)"
has "contiguous clock hours -> hourly job with a window" "Global poll: launchd, hours 9-12" "$out"
has "every 1h" "+        every: 1h" "$out"
has "hours window" '+        hours: "9-12"' "$out"
has "launchd removal named" "would remove the global poll (launchd agent)" "$out"

plist '    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>13</integer><key>Minute</key><integer>0</integer></dict>
    </array>'
out="$(bash "$MIG" 2>&1)"
has "non-contiguous hours are not a window" "hours 9,13 are not a contiguous range; no hours: window set" "$out"
hasnt "no hours line" "hours: " "$(printf '%s\n' "$out" | grep '^+')"

plist '    <key>StartInterval</key>
    <integer>1800</integer>'
out="$(bash "$MIG" 2>&1)"
has "StartInterval seconds -> every" "Global poll: launchd, every 30m" "$out"
has "every 30m" "+        every: 30m" "$out"

out="$(bash "$MIG" --every 5m 2>&1)"
has "--every overrides the detected interval" "+        every: 5m" "$out"

rm -f "$PLIST"
out="$(bash "$MIG" 2>&1)"
has "no poll -> 15m" "+        every: 15m" "$out"

echo "== 7. launchd poll removal on --apply =="
reset; printf '%s' "$ONE" > "$CFG"
plist '    <key>StartInterval</key>
    <integer>900</integer>'
touch "$HOME/Library/LaunchAgents/engineer-agent-jobs.plist"
out="$(bash "$MIG" --apply 2>&1)"; rc=$?
eq "exit 0" 0 "$rc"
eq "poll plist removed" "no" "$([ -e "$PLIST" ] && echo yes || echo no)"
eq "dispatcher plist kept" "yes" "$([ -e "$HOME/Library/LaunchAgents/engineer-agent-jobs.plist" ] && echo yes || echo no)"
eq "poll agent booted out" "bootout gui/$(id -u)/engineer-agent-poll" "$(cat "$TMP/launchctl.log" 2>&1)"

echo "== 7b. config already migrated, poll still installed: only the poll goes =="
cp "$CFG" "$TMP/after1.yaml"
printf '%s\n' "$POLL_CRON" > "$TMP/crontab.txt"
export EA_NOW=$((T0 + 60))
out="$(bash "$MIG" --apply 2>&1)"; rc=$?
export EA_NOW="$T0"
eq "exit 0" 0 "$rc"
if cmp -s "$TMP/after1.yaml" "$CFG"; then ok "config unchanged"; else bad "config changed"; fi
eq "no second backup" "engineer.yaml.bak-$T0" "$(cd "$EA_AGENT_DIR" && ls engineer.yaml.bak-* | tr '\n' ' ' | sed 's/ $//')"
eq "poll crontab entry removed" "" "$(cat "$TMP/crontab.txt")"
hasnt "no config message" "engineer.yaml updated" "$out"

echo "== 8. jobs: [] and a compact jobs list =="
reset
cat > "$CFG" <<'YAML'
projects:
  one:
    path: "/tmp/one"
    slack:
      channels: ["C1"]
    jobs: []   # none yet
  two:
    path: "/tmp/two"
    slack:
      channels: ["C2"]
    jobs:
    - id: cr
      integration: slack
      action: cr-qa
      every: 5m
      exclusive: true
      channel: C2
agent:
  name: x
YAML
printf '%s\n' "$JOBS_CRON" > "$TMP/crontab.txt"
bash "$MIG" --apply >/dev/null 2>&1; rc=$?
eq "exit 0" 0 "$rc"
eq "entries match the list's indentation" 'projects:
  one:
    path: "/tmp/one"
    slack:
      channels: ["C1"]
    jobs:
      - id: slack-watch
        integration: slack
        action: watch
        every: 15m
        watch: [channels]
  two:
    path: "/tmp/two"
    slack:
      channels: ["C2"]
    jobs:
    - id: cr
      integration: slack
      action: cr-qa
      every: 5m
      channel: C2
    - id: slack-watch
      integration: slack
      action: watch
      every: 15m
      watch: [channels]
agent:
  name: x' "$(cat "$CFG")"
eq "both new jobs read back" "one|slack-watch|slack|watch|15m|
two|cr|slack|cr-qa|5m|
two|slack-watch|slack|watch|15m|" "$(enumerate)"

echo "== 9. failure paths =="
reset
cat > "$CFG" <<'YAML'
projects:
  one:
    path: "/tmp/one"
    slack:
      channels: ["C1"]
    jobs: [{id: a, integration: jira, action: implement-next, every: 5m}]
YAML
printf '%s\n' "$JOBS_CRON" > "$TMP/crontab.txt"
cp "$CFG" "$TMP/orig.yaml"
out="$(bash "$MIG" --apply 2>&1)"; rc=$?
eq "flow-style jobs list: exit 2" 2 "$rc"
has "names the project" "project 'one': jobs is a flow-style list; rewrite it as a block list and re-run" "$out"
if cmp -s "$TMP/orig.yaml" "$CFG"; then ok "config untouched"; else bad "config changed"; fi
eq "no backup" "" "$(cd "$EA_AGENT_DIR" && ls engineer.yaml.bak-* 2>/dev/null)"

out="$(bash "$MIG" --bogus 2>&1)"; rc=$?
eq "unknown argument: exit 2" 2 "$rc"
has "names it" "migrate-poll-to-jobs: unknown argument '--bogus'" "$out"

out="$(bash "$MIG" --every 5 2>&1)"; rc=$?
eq "bad --every: exit 2" 2 "$rc"

rm -f "$CFG"
out="$(bash "$MIG" 2>&1)"; rc=$?
eq "missing config: exit 2" 2 "$rc"
has "says so" "migrate-poll-to-jobs: no engineer.yaml" "$out"

echo
echo "migrate-poll-to-jobs: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
