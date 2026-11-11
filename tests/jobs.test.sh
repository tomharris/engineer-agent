#!/bin/bash
# Tests for scheduled jobs: scripts/lib-jobs.sh, jobs-tick.sh, jobs-draft.sh, jobs-ctl.sh,
# job-slack-watch.sh, and the `exclusive` skip in ea-config.sh.
#
# The clock is frozen with EA_NOW and TZ=UTC. The Slack collector is replaced by a stub handler
# (EA_JOB_HANDLER_SLACK_WATCH) for dispatcher mechanics; section 9 drives the REAL collector
# against stubbed `spy` and `curl`. `claude` and `notify.sh` are stubbed via CLAUDE_BIN /
# EA_NOTIFY_BIN.
#
# Run: bash tests/jobs.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TICK="${REPO_ROOT}/scripts/jobs-tick.sh"
CTL="${REPO_ROOT}/scripts/jobs-ctl.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — [$2] not in [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
export HOME="$TMP/home"
export TZ=UTC
mkdir -p "$EA_AGENT_DIR"/queue/{incoming,drafts,completed,rejected} "$EA_AGENT_DIR/state" "$TMP/bin" "$HOME"
export PATH="$TMP/bin:$PATH"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"

# Monday 2026-11-09 10:00:00 UTC
T0=1794218400
export EA_NOW="$T0"
STATE="$EA_AGENT_DIR/state/jobs"
CFG="$EA_AGENT_DIR/engineer.yaml"

# notify stub: one line per push
export PUSHES="$TMP/pushes"; : > "$PUSHES"
cat > "$TMP/notify" <<'EOF'
#!/bin/bash
title=""; while [ $# -gt 0 ]; do case "$1" in --title) title="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "$title" >> "$PUSHES"
EOF
chmod +x "$TMP/notify"
export EA_NOTIFY_BIN="$TMP/notify"

# Stub collector. Behaviour per job key comes from files, so one stub serves every case:
#   $TMP/h.<key>.rc       exit code (default 0)
#   $TMP/h.<key>.sleep    seconds to sleep first
#   $TMP/h.<key>.items    queue filenames to create in incoming/ and emit into the manifest
#   $TMP/h.<key>.err      a Phase A error line to record
export HSTUB="$TMP"
cat > "$TMP/handler" <<'EOF'
#!/bin/bash
job=""; manifest=""; errors=""
while [ $# -gt 0 ]; do
  case "$1" in --job) job="$2"; shift 2 ;; --manifest) manifest="$2"; shift 2 ;; --errors) errors="$2"; shift 2 ;; *) shift ;; esac
done
echo "$$" > "$HSTUB/h.$job.pid"
echo "$job" >> "$HSTUB/h.calls"
[ -f "$HSTUB/h.$job.sleep" ] && sleep "$(cat "$HSTUB/h.$job.sleep")"
[ -f "$HSTUB/h.$job.err" ] && cat "$HSTUB/h.$job.err" >> "$errors"
if [ -f "$HSTUB/h.$job.items" ]; then
  while read -r f; do
    p="$EA_AGENT_DIR/queue/incoming/$f"
    printf -- '---\ntype: slack-question\nsource: slack\nsource_id: "slack:%s"\nproject: alpha\nchannel_id: "C1"\nmessage_ts: "1700000000.000100"\n---\n## Context\n' "$f" > "$p"
    printf 'create\t%s\tslack-question\talpha\tslack:%s\t0\t0\ttitle\n' "$p" "$f" >> "$manifest"
  done < "$HSTUB/h.$job.items"
fi
exit "$(cat "$HSTUB/h.$job.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$TMP/handler"
export EA_JOB_HANDLER_SLACK_WATCH="$TMP/handler"

# claude stub: CLAUDE_MODE=move moves every manifest row to drafts/; anything else does nothing.
cat > "$TMP/claude" <<'EOF'
#!/bin/bash
echo "$*" >> "$HSTUB/claude.calls"
if [ "${CLAUDE_MODE:-}" = "move" ]; then
  for f in "$EA_AGENT_DIR"/queue/incoming/*.md; do [ -e "$f" ] && mv "$f" "$EA_AGENT_DIR/queue/drafts/"; done
fi
exit 0
EOF
chmod +x "$TMP/claude"
export CLAUDE_BIN="$TMP/claude"

calls() { local n; n="$(grep -c "^$1\$" "$TMP/h.calls" 2>/dev/null)"; echo "${n:-0}"; }
rfield() { awk -v k="$2" 'index($0, k ": ") == 1 { v = substr($0, length(k) + 3); gsub(/^"|"$/, "", v); print v; exit }' "$STATE/$1.receipt" 2>/dev/null; }
tick() { bash "$TICK" --foreground "$@"; }
reset_state() { rm -rf "$STATE" "$TMP"/h.* "$TMP/claude.calls"; : > "$PUSHES"; rm -f "$EA_AGENT_DIR"/queue/*/*.md; }

base_config() {
  local every="${EVERY:-5m}"
  cat > "$CFG" <<YAML
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "none"
    slack:
      channels: ["C1"]
    jobs:
      - id: watch
        integration: slack
        action: watch
        every: ${every}
        watch: [channels]
${1:-}
YAML
}

# --------------------------------------------------------------------------------------------
echo "== 1. exclusive: the global poll skips a source only an able, unpaused job owns =="
base_config "        exclusive: true"
eq "exclusive job owns the source" "skipped:owned by scheduled job watch" \
  "$(bash "$REPO_ROOT/scripts/ea-config.sh" sources alpha | awk -F'\t' '$1=="slack"{print $2}')"
eq "the job's own run still sees it configured" "configured" \
  "$(EA_JOBS_IGNORE_EXCLUSIVE=1 bash "$REPO_ROOT/scripts/ea-config.sh" sources alpha | awk -F'\t' '$1=="slack"{print $2}')"
mkdir -p "$STATE"; touch "$STATE/alpha.watch.paused"
eq "a paused job does not own it (no silent outage)" "configured" \
  "$(bash "$REPO_ROOT/scripts/ea-config.sh" sources alpha | awk -F'\t' '$1=="slack"{print $2}')"
rm -f "$STATE/alpha.watch.paused"
base_config
eq "without exclusive the source stays with the poll" "configured" \
  "$(bash "$REPO_ROOT/scripts/ea-config.sh" sources alpha | awk -F'\t' '$1=="slack"{print $2}')"
cat > "$CFG" <<'YAML'
projects:
  alpha:
    path: "/tmp/alpha"
    jira:
      project: "ENG"
    jobs:
      - id: auto
        integration: jira
        action: triage
        every: 30m
        exclusive: true
YAML
eq "an unsupported job cannot claim exclusivity" "configured" \
  "$(bash "$REPO_ROOT/scripts/ea-config.sh" sources alpha | awk -F'\t' '$1=="jira"{print $2}')"

# --------------------------------------------------------------------------------------------
echo "== 2. validation =="
v() {  # v <every> <hours> <days> <watch> [id] [integ:action] [pause]
  local pair="${6:-slack:watch}"
  local integ="${pair%%:*}" action="${pair#*:}"
  local sup=0; [ "${integ}:${action}" = "slack:watch" ] && sup=1
  local row="alpha|0|${5:-watch}|${integ}|${action}|$1|$2|$3|$4||${sup}||${7:-}"
  ( . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-jobs.sh"; jobs_validate "$row" "$row" )
}
eq "valid job" "" "$(v 5m 9-17 mon,fri channels)"
has "every below floor" "below the 1m floor" "$(v 30s '' '' channels)"
has "every malformed" "must look like" "$(v 5 '' '' channels)"
has "hours start >= end" "0 <= start < end <= 24" "$(v 5m 17-9 '' channels)"
has "hours past 24" "0 <= start < end <= 24" "$(v 5m 9-25 '' channels)"
has "hours malformed" "must look like 9-17" "$(v 5m 9 '' channels)"
has "unknown day" "days entry 'monday'" "$(v 5m '' monday channels)"
has "unbuilt watch source" "watch source 'reactions' is not supported yet" "$(v 5m '' '' channels,reactions)"
has "mentions without agent.slack.user_id" "needs agent.slack.user_id" "$(EA_JOBS_CFG='agent.slack.method=spy' v 5m '' '' channels,mentions)"
eq "mentions with agent.slack.user_id" "" "$(EA_JOBS_CFG='agent.slack.user_id=UME' v 5m '' '' mentions,my-threads)"
has "bad thread_ttl" "thread_ttl '7 days'" "$(EA_JOBS_CFG='projects.alpha.job.0.thread_ttl=7 days' v 5m '' '' my-threads)"
has "bad id" "must match" "$(v 5m '' '' channels 'Watch!')"
has "unsupported pair" "unsupported integration/action 'github:merge'" "$(v 5m '' '' '' auto github:merge)"
has "bad pause_after" "positive integer" "$(v 5m '' '' channels watch slack:watch 0)"
dup="alpha|0|watch|slack|watch|5m||||||1||
alpha|1|watch|slack|watch|5m||||||1||"
has "duplicate id" "duplicate job id 'watch'" \
  "$( . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-jobs.sh"; jobs_validate "$(printf '%s' "$dup" | head -1)" "$dup")"

# --------------------------------------------------------------------------------------------
echo "== 3. hours/days window (local time) =="
w() { ( . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-jobs.sh"; jobs_in_window "$1" "$2" "$3" ) && echo in || echo out; }
eq "10:00 inside 9-17"                 in  "$(w 9-17 '' "$T0")"
eq "17:00 is the exclusive end"        out "$(w 9-17 '' $((T0 + 7*3600)))"
eq "09:00 is the inclusive start"      in  "$(w 9-17 '' $((T0 - 3600)))"
eq "Monday is in mon,tue"              in  "$(w '' mon,tue "$T0")"
eq "Monday is not in sat,sun"          out "$(w '' sat,sun "$T0")"
eq "window follows TZ (10:00Z is 03:00 in Denver)" out "$(TZ=America/Denver w 9-17 '' "$T0")"

# --------------------------------------------------------------------------------------------
echo "== 4. due: first tick runs, then every N =="
reset_state; base_config
tick
eq "first tick runs the job" 1 "$(calls alpha.watch)"
eq "receipt status ok" ok "$(rfield alpha.watch status)"
eq "receipt items 0" 0 "$(rfield alpha.watch items)"
eq "last-run is the tick time" "$T0" "$(cat "$STATE/alpha.watch.last-run")"
first_run="$(rfield alpha.watch run_id)"
EA_NOW=$((T0 + 240)) tick
eq "not due 4m later" 1 "$(calls alpha.watch)"
EA_NOW=$((T0 + 300)) tick
eq "due at exactly 5m" 2 "$(calls alpha.watch)"
[ "$(rfield alpha.watch run_id)" != "$first_run" ] && ok "a new run_id per run" || bad "run_id was reused"

# launchd execs the script, so its shebang's bash runs it (3.2 on macOS).
reset_state; base_config
"$TICK" --foreground
eq "a tick run by its shebang runs the job" 1 "$(calls alpha.watch)"
eq "and writes an ok receipt" ok "$(rfield alpha.watch status)"

base_config "        hours: \"12-13\""
reset_state
tick
eq "outside its window it does not run" 0 "$(calls alpha.watch)"
bash "$CTL" run alpha.watch >/dev/null
eq "jobs-ctl run ignores the window" 1 "$(calls alpha.watch)"

# --------------------------------------------------------------------------------------------
echo "== 5. a held lock skips that job only =="
reset_state
cat > "$CFG" <<'YAML'
projects:
  alpha:
    path: "/tmp/alpha"
    slack:
      channels: ["C1"]
    jobs:
      - id: one
        integration: slack
        action: watch
        every: 5m
      - id: two
        integration: slack
        action: watch
        every: 5m
YAML
mkdir -p "$STATE"
sleep 30 & LIVE=$!
echo "$LIVE" > "$STATE/alpha.one.lock"
tick
eq "locked job skipped" 0 "$(calls alpha.one)"
eq "other job ran" 1 "$(calls alpha.two)"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
echo 999999 > "$STATE/alpha.one.lock"
EA_NOW=$((T0 + 600)) tick
eq "a stale lock (dead PID) is reclaimed" 1 "$(calls alpha.one)"
[ -e "$STATE/alpha.one.lock" ] && bad "lock left behind after run" || ok "lock released after run"

# --------------------------------------------------------------------------------------------
echo "== 6. failure streak: one push, then pause at the threshold =="
reset_state; base_config "        guards:
          pause_after_failures: 3"
mkdir -p "$TMP"; echo 1 > "$TMP/h.alpha.watch.rc"
tick
eq "failed run => status error" error "$(rfield alpha.watch status)"
has "error names the collector exit" "collector exited 1" "$(cat "$STATE/alpha.watch.receipt")"
eq "first failure pushes once" 1 "$(grep -c 'job alpha.watch failed' "$PUSHES")"
EA_NOW=$((T0 + 300)) tick
eq "second failure is silent" 1 "$(wc -l < "$PUSHES" | tr -d ' ')"
EA_NOW=$((T0 + 600)) tick
[ -e "$STATE/alpha.watch.paused" ] && ok "third failure pauses the job" || bad "job not paused"
eq "pause pushes once" 1 "$(grep -c 'job alpha.watch paused' "$PUSHES")"
EA_NOW=$((T0 + 900)) tick
eq "a paused job does not run" 3 "$(calls alpha.watch)"
has "list shows paused" "paused" "$(bash "$CTL" list)"
rm -f "$TMP/h.alpha.watch.rc"
bash "$CTL" resume alpha.watch >/dev/null
EA_NOW=$((T0 + 1200)) tick
eq "resumed job runs and succeeds" ok "$(rfield alpha.watch status)"
[ -e "$STATE/alpha.watch.failures" ] && bad "streak not cleared by success" || ok "success clears the streak"

echo 3 > "$TMP/h.alpha.watch.rc"
EA_NOW=$((T0 + 1500)) tick
has "exit 3 explains the missing credential" "agent.typesafe credential" "$(cat "$STATE/alpha.watch.receipt")"
rm -f "$TMP/h.alpha.watch.rc"

echo "collector: C9 read failed" > "$TMP/h.alpha.watch.err"
EA_NOW=$((T0 + 1800)) tick
eq "a logged Phase A error => partial" partial "$(rfield alpha.watch status)"
rm -f "$TMP/h.alpha.watch.err"

# --------------------------------------------------------------------------------------------
echo "== 7. a hung job is killed at its timeout and still leaves a receipt =="
reset_state; base_config
echo 30 > "$TMP/h.alpha.watch.sleep"
t_start=$(date +%s)
EA_JOB_MAX_SECONDS=2 tick
t_took=$(( $(date +%s) - t_start ))
[ "$t_took" -lt 15 ] && ok "run ended at the timeout (${t_took}s), not when the handler finished" || bad "run waited ${t_took}s for the hung handler"
eq "timed-out run => error" error "$(rfield alpha.watch status)"
has "receipt says timed out" "timed out after 2s" "$(cat "$STATE/alpha.watch.receipt")"
hpid="$(cat "$TMP/h.alpha.watch.pid")"
sleep 1
kill -0 "$hpid" 2>/dev/null && bad "hung handler survived" || ok "hung handler was killed"
rm -f "$TMP/h.alpha.watch.sleep"

# --------------------------------------------------------------------------------------------
echo "== 8. drafting: ground truth decides, and the poll lock defers =="
reset_state; base_config
echo "20261109-100000-slack-question-a.md" > "$TMP/h.alpha.watch.items"
CLAUDE_MODE=move tick
eq "items counted" 1 "$(rfield alpha.watch items)"
eq "drafting done when the file reached drafts/" done "$(rfield alpha.watch drafting)"
eq "status ok" ok "$(rfield alpha.watch status)"
[ -f "$EA_AGENT_DIR/queue/drafts/20261109-100000-slack-question-a.md" ] && ok "item is in drafts/" || bad "item not in drafts/"
has "drafting prompt forbids polling" "Do NOT poll any source" "$(cat "$TMP/claude.calls")"
has "drafting run uses the poll allowlist" "Bash(gh pr view:*)" "$(cat "$TMP/claude.calls")"
case "$(cat "$TMP/claude.calls")" in *"slack-mcp.sh send"*|*"spy send"*) bad "send verb leaked into the allowlist" ;; *) ok "no Slack send verb" ;; esac

printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$TMP/spy.argv" > "$TMP/bin/spy"; chmod +x "$TMP/bin/spy"
reset_state; base_config; rm -f "$TMP/spy.argv"
printf 'agent:\n  autonomy:\n    auto_execute: [slack-react]\n  slack:\n    reactions:\n      drafted: memo\n' >> "$CFG"
echo "20261109-100000-slack-question-r.md" > "$TMP/h.alpha.watch.items"
tick
eq "no drafted reaction for an item that did not reach drafts/" "" "$(cat "$TMP/spy.argv" 2>/dev/null)"
reset_state; base_config; rm -f "$TMP/spy.argv"
printf 'agent:\n  autonomy:\n    auto_execute: [slack-react]\n  slack:\n    reactions:\n      drafted: memo\n' >> "$CFG"
echo "20261109-100000-slack-question-r.md" > "$TMP/h.alpha.watch.items"
CLAUDE_MODE=move tick
eq "a drafted Slack item gets the drafted reaction" "react C1 1700000000.000100 memo --json" "$(cat "$TMP/spy.argv" 2>/dev/null)"

reset_state; base_config
echo "20261109-100000-slack-question-b.md" > "$TMP/h.alpha.watch.items"
CLAUDE_MODE=none tick
eq "model claimed nothing moved => incomplete" incomplete "$(rfield alpha.watch drafting)"
eq "incomplete drafting => partial" partial "$(rfield alpha.watch status)"

reset_state; base_config
echo "20261109-100000-slack-question-c.md" > "$TMP/h.alpha.watch.items"
sleep 30 & LIVE=$!
echo "$LIVE" > "$EA_AGENT_DIR/state/cron-poll.lock"
CLAUDE_MODE=move tick
eq "poll running => drafting deferred" deferred "$(rfield alpha.watch drafting)"
eq "deferral is not a failure" ok "$(rfield alpha.watch status)"
[ -e "$TMP/claude.calls" ] && bad "claude ran despite the poll lock" || ok "claude not started while the poll runs"
[ "$(cat "$EA_AGENT_DIR/state/cron-poll.lock")" = "$LIVE" ] && ok "the poll's lock is left alone" || bad "poll lock clobbered"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; rm -f "$EA_AGENT_DIR/state/cron-poll.lock"

# --------------------------------------------------------------------------------------------
echo "== 9. invalid jobs are recorded, not run =="
reset_state; EVERY=10s base_config
tick
eq "invalid job did not run" 0 "$(calls alpha.watch)"
has "reason recorded" "below the 1m floor" "$(cat "$STATE/alpha.watch.invalid" 2>/dev/null)"
has "list shows invalid with its reason" "invalid: every '10s'" "$(bash "$CTL" list)"
before="$(grep -c invalid "$EA_AGENT_DIR/state/jobs.log")"
EA_NOW=$((T0 + 60)) tick
eq "unchanged reason is not re-logged every tick" "$before" "$(grep -c invalid "$EA_AGENT_DIR/state/jobs.log")"

# --------------------------------------------------------------------------------------------
echo "== 10. no jobs => the tick is inert =="
reset_state
printf 'projects:\n  alpha:\n    path: "/tmp/alpha"\n' > "$CFG"
tick
[ -e "$STATE" ] && [ -n "$(ls -A "$STATE")" ] && bad "state written with no jobs" || ok "nothing written"
has "list says none" "No scheduled jobs configured." "$(bash "$CTL" list)"

# --------------------------------------------------------------------------------------------
echo "== 10b. slack/cr-qa: validation, dispatch, exclusivity =="
export EA_JOB_HANDLER_SLACK_CR_QA="$TMP/handler"
crqa_config() {  # crqa_config <line-to-drop-regex> [extra job lines]
  cat <<YAML | grep -vE "${1:-^\$NONE}" > "$CFG"
projects:
  web:
    path: "/tmp/web"
    tracker: jira
    github:
      owner: acme
      repos: [web]
    slack:
      channels: ["C0123456789"]
    jobs:
      - id: crqa
        integration: slack
        action: cr-qa
        every: 5m
        channel: C0123456789
        trusted_slack_users: [U0TRUSTED]
        trusted_authors: ["acc-tom"]
        transition: "Ready for Upload"
        security:
          command: ~/bin/review.sh
${2:-}
YAML
}
reset_state; crqa_config
tick
eq "valid cr-qa job runs its handler" 1 "$(calls web.crqa)"
[ -e "$STATE/web.crqa.invalid" ] && bad "valid job marked invalid: $(cat "$STATE/web.crqa.invalid")" || ok "no invalid file"
list_out="$(bash "$CTL" list 2>&1)"
printf '%s' "$list_out" | grep -qE 'invalid|unbound' && bad "jobs-ctl list misreports a valid cr-qa job: $list_out" || ok "jobs-ctl list shows the cr-qa job as valid"
inv() { reset_state; crqa_config "$1" "${2:-}"; tick; cat "$STATE/web.crqa.invalid" 2>/dev/null; }
eq "needs channel" "cr-qa needs channel" "$(inv '^        channel:')"
eq "needs trusted_slack_users" "cr-qa needs trusted_slack_users" "$(inv 'trusted_slack_users')"
eq "needs trusted_authors" "cr-qa needs trusted_authors" "$(inv 'trusted_authors')"
eq "needs transition" "cr-qa needs transition" "$(inv 'transition:')"
eq "needs jira tracker" "cr-qa needs projects.web.tracker: jira" "$(inv 'tracker: jira')"
eq "needs github repos" "cr-qa needs projects.web.github.repos" "$(inv 'repos: \[web\]')"
eq "needs security.command" "cr-qa security.command is required" "$(inv 'command:')"
eq "relative security.command" "cr-qa security.command 'bin/review.sh' must be an absolute or ~/ path" \
  "$(reset_state; crqa_config '' ; sed -i.bak 's#~/bin/review.sh#bin/review.sh#' "$CFG"; tick; cat "$STATE/web.crqa.invalid")"
has "unknown reactions key" "reactions" "$(inv '^\$NONE' '        reactions: { claim: eyes, aprove: approve }')"
eq "invalid job did not run" 0 "$(calls web.crqa)"
reset_state; crqa_config '' '        exclusive: true'
eq "exclusive cr-qa owns the project's Slack source" "skipped:owned by scheduled job crqa" \
  "$(bash "$REPO_ROOT/scripts/ea-config.sh" sources web | awk -F'\t' '$1=="slack"{print $2}')"
mkdir -p "$STATE"; touch "$STATE/web.crqa.paused"
eq "paused cr-qa gives the source back" "configured" \
  "$(bash "$REPO_ROOT/scripts/ea-config.sh" sources web | awk -F'\t' '$1=="slack"{print $2}')"

# --------------------------------------------------------------------------------------------
echo "== 11. the real Slack collector: own channels only, own cutoff file =="
if command -v jq >/dev/null 2>&1; then
  reset_state; unset EA_JOB_HANDLER_SLACK_WATCH
  export SPY_ARGV="$TMP/spy.argv"; : > "$SPY_ARGV"
  cat > "$TMP/bin/spy" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SPY_ARGV"
case "${1:-}" in
  read) [ "$2" = "C1" ] && printf '[{"ts":"1794218000.000100","user_id":"UX","user_name":"x","reply_count":0,"thread_ts":null,"text":"how do I deploy this?"}]' || echo '[]' ;;
  *) echo '[]' ;;
esac
EOF
  chmod +x "$TMP/bin/spy"
  cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out=""; prev=""
for a in "$@"; do case "$prev" in -o) out="$a" ;; esac; prev="$a"; done
cat > /dev/null
printf '%s' '{"model":"jev-latest","answers":{"is_question":{"type":"noul","noul":0.9},"directed_at_user":{"type":"noul","noul":0.9},"already_answered":{"type":"noul","noul":0.1},"needs_engineer":{"type":"noul","noul":0.9}},"usage":{"input_tokens":1,"output_tokens":1}}' > "$out"
printf '200'
EOF
  chmod +x "$TMP/bin/curl"
  export EA_TEST_TS_KEY="k"
  cat > "$CFG" <<'YAML'
agent:
  slack:
    workspace: "myco"
  typesafe:
    api_key_env: "EA_TEST_TS_KEY"
projects:
  alpha:
    path: "/tmp/alpha"
    tracker: "none"
    slack:
      channels: ["C1"]
      keywords: ["deploy"]
    jobs:
      - id: watch
        integration: slack
        action: watch
        every: 5m
        exclusive: true
  beta:
    path: "/tmp/beta"
    tracker: "none"
    slack:
      channels: ["C2"]
      keywords: ["deploy"]
YAML
  echo "global" > "$EA_AGENT_DIR/state/last-poll.yaml.marker"
  cp "$EA_AGENT_DIR/state/last-poll.yaml.marker" "$EA_AGENT_DIR/state/last-poll.yaml"
  CLAUDE_MODE=move tick
  has "read the job's channel" "read C1" "$(cat "$SPY_ARGV")"
  case "$(cat "$SPY_ARGV")" in *"read C2"*) bad "read another project's channel" ;; *) ok "did not read beta's channel" ;; esac
  eq "one item drafted" 1 "$(ls "$EA_AGENT_DIR/queue/drafts" | wc -l | tr -d ' ')"
  has "cutoff written to the job's own state file" "last_checked_ts" "$(cat "$STATE/alpha.watch.state.yaml" 2>/dev/null)"
  eq "global last-poll.yaml untouched" "global" "$(cat "$EA_AGENT_DIR/state/last-poll.yaml")"
  eq "receipt ok" ok "$(rfield alpha.watch status)"
else
  echo "  SKIP: jq not installed"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
