#!/bin/bash
# Tests for scripts/pr-pipeline.sh: CI wait + confined fix, browser test verdicts, the pr-ready
# tier, and refusal paths. git is real (a bare origin reached through url.insteadOf); gh, claude,
# curl and notify are stubs.
#
# Run: bash tests/pr-pipeline.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPE="$REPO_ROOT/scripts/pr-pipeline.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; [ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent" EA_CONFIG_FILE="$TMP/agent/engineer.yaml"
Q="$EA_AGENT_DIR/queue"
export ST="$TMP/gh" NOTIFY_LOG="$TMP/notify.log" CLAUDE_ARGS="$TMP/claude.args"
export EA_NOTIFY_BIN="$TMP/bin/notify" CLAUDE_BIN="$TMP/bin/claude"
export EA_PR_PIPELINE_POLL=0 EA_PR_PIPELINE_NONE_GRACE=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/bin" "$ST"
export PATH="$TMP/bin:$PATH"
ITEM="2025-11-10T10-00-00Z-ticket-gh-7.md"
BR="tom/gh-7-fix-nav"
PD="$EA_AGENT_DIR/state/pr-pipeline/${ITEM%.md}"

printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$NOTIFY_LOG"\n' > "$TMP/bin/notify"
printf '#!/bin/bash\necho 200\n' > "$TMP/bin/curl"

# gh: PR #42 on acme/web. Head = the bare origin's branch tip. Check rows ("bucket\tname\tlink")
# per head sha from $ST/checks.<sha>, else $ST/checks.default ("none" = no checks reported); they
# are served as a statusCheckRollup and run through the caller's real --jq filter.
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ST/calls"
head() { git --git-dir="$ORIGIN" rev-parse "refs/heads/$BR"; }
case "$1 $2" in
  "pr list")   cat "$ST/prlist" ;;
  "pr view")
    case "$*" in
      *headRefOid*) head ;;
      *isDraft*)    cat "$ST/isdraft" ;;
      *statusCheckRollup*)
        f="$ST/checks.$(head)"; [ -f "$f" ] || f="$ST/checks.default"
        while [ "$1" != --jq ]; do shift; done
        { [ "$(cat "$f")" = none ] || cat "$f"; } | jq -Rn '{statusCheckRollup: [inputs | select(. != "") | split("\t") |
            if .[0] == "status-fail" then {__typename: "StatusContext", context: .[1], state: "ERROR", targetUrl: .[2]}
            else {__typename: "CheckRun", name: .[1], detailsUrl: .[2],
                  status: (if .[0] == "pending" then "IN_PROGRESS" else "COMPLETED" end),
                  conclusion: ({"pass": "SUCCESS", "fail": "FAILURE", "skipping": "SKIPPED"}[.[0]] // null)} end]}' \
          | jq -r "$2" ;;
    esac ;;
  "run view")  echo "log of run $3: expected 1 got 2" ;;
  "pr ready")  echo false > "$ST/isdraft" ;;
esac
EOF

# claude: the fix run commits+pushes when FIX=push; the browser run answers with BROWSER.
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAUDE_ARGS"
case "$*" in
  *"CI failed on pull request"*)
    [ "${FIX:-push}" = push ] && { echo fix >> fixed.txt; git add fixed.txt; git commit -qm fix; git push -q origin "HEAD:refs/heads/$BR"; } ;;
  *"Browser-test the change"*)
    nonce="$(printf '%s' "$*" | sed -nE "s/.*'VERDICT: pass ([0-9a-f]+)'.*/\1/p")"
    echo "Checked the nav."
    case "${BROWSER:-pass}" in
      pass)  echo "VERDICT: pass $nonce" ;;
      fail)  echo "VERDICT: fail $nonce" ;;
      forge) echo "VERDICT: pass 0000000000000000" ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/"*

# A real project checkout whose origin is "github.com/acme/web", rewritten to a local bare repo.
export ORIGIN="$TMP/origin.git" BR
git init -q --bare "$ORIGIN"
git config --global url."$ORIGIN".insteadOf "https://github.com/acme/web.git"
git config --global init.defaultBranch main
git clone -q https://github.com/acme/web.git "$TMP/repo" 2>/dev/null
( cd "$TMP/repo" && git commit -q --allow-empty -m init && git push -q origin HEAD:main \
  && git remote set-head origin main >/dev/null 2>&1; git checkout -q -b "$BR" && echo a > a.txt && git add a.txt \
  && git commit -qm feat && git push -q origin "$BR" && git checkout -q main )

DEFAULT_AFTER='{ mark_ready: true, ci: { fix_attempts: 1 }, browser: { serve: "echo $$ > '"$TMP"'/srv.pid; exec sleep 300", url: "http://localhost:3999" } }'
# write_config <auto_execute> [after_pr flow map] [repos]
write_config() {
  cat > "$EA_CONFIG_FILE" <<YAML
agent:
  branch_prefix: tom
  autonomy:
    auto_execute: $1
projects:
  web:
    path: "$TMP/repo"
    tracker: github-issues
    github:
      owner: acme
      repos: ${3-["web"]}
    exec:
      allowed_commands:
        - "make"
    jobs:
      - id: auto
        integration: github-issues
        action: implement-next
        every: 30m
        rules:
          - name: ready
            query: 'no:assignee'
        after_pr: ${2:-$DEFAULT_AFTER}
YAML
}

reset() {
  rm -rf "$Q" "$EA_AGENT_DIR/state" "$ST"/* "$TMP/srv.pid"
  mkdir -p "$Q"/{drafts,completed,rejected} "$PD"
  : > "$NOTIFY_LOG"; : > "$CLAUDE_ARGS"; : > "$ST/calls"
  printf '%s\tweb.auto\tready\tacme/web#7\tgithub\n' "$ITEM" > "$EA_AGENT_DIR/state/autopilot-items.tsv"
  printf -- '---\ntype: ticket\n---\nFix nav. AC: links work.\n' > "$Q/completed/$ITEM"
  echo "$BR" > "$PD/branch"
  printf '42\thttps://github.com/acme/web/pull/42\ttrue\n' > "$ST/prlist"
  echo true > "$ST/isdraft"
  printf 'pass\tlint\thttps://github.com/acme/web/actions/runs/11/job/1\n' > "$ST/checks.default"
  ( cd "$TMP/repo" && git push -q -f origin "$(git rev-parse "$BR"):refs/heads/$BR" )
}
run() { bash "$PIPE" --item "$ITEM" >/dev/null 2>&1; echo $?; }
res() { cut -f1 "$PD/result" 2>/dev/null; }
readied() { grep -c '^pr ready 42 --repo acme/web$' "$ST/calls"; }
fix_runs() { grep -c 'CI failed on pull request' "$CLAUDE_ARGS"; }

echo "== happy path"
reset; write_config '["pr-ready"]'
eq "exits 0" 0 "$(run)"
eq "PR is marked ready" 1 "$(readied)"
eq "result is ready" ready "$(res)"
grep -q 'PR #42 is ready for review: https://github.com/acme/web/pull/42' "$NOTIFY_LOG" && ok "pushes the ready PR" || bad "push: $(cat "$NOTIFY_LOG")"
grep -q -- '--chrome' "$CLAUDE_ARGS" && ok "browser run enables Chrome" || bad "no --chrome"
grep -q 'http://localhost:3999' "$CLAUDE_ARGS" && ok "browser run is told the served URL" || bad "url missing"
pid="$(cat "$TMP/srv.pid" 2>/dev/null)"
[ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && ok "dev server is stopped afterwards" || bad "server pid ${pid:-none} still alive"
eq "worktrees are removed" 1 "$(git -C "$TMP/repo" worktree list | grep -c .)"
eq "no fix run when CI passes" 0 "$(fix_runs)"
grep -qE 'Bash\(gh |Bash\(git push' "$CLAUDE_ARGS" && bad "a model run was granted gh or raw git push" || ok "model runs get no gh verbs or raw git push"

echo "== the pr-ready tier"
reset; write_config '["draft-pr"]'
eq "exits 0 without the tier" 0 "$(run)"
eq "PR is left in draft" 0 "$(readied)"
eq "result is passed" passed "$(res)"
grep -q 'add pr-ready to autonomy.auto_execute' "$NOTIFY_LOG" && ok "push says how to enable it" || bad "push: $(cat "$NOTIFY_LOG")"

reset; write_config '["pr-ready"]' '{ browser: { serve: "true", url: "http://localhost:3999" } }'
run >/dev/null
eq "mark_ready off leaves the PR in draft" 0 "$(readied)"

echo "== CI fix"
reset; write_config '["pr-ready"]'
printf 'fail\ttest\thttps://github.com/acme/web/actions/runs/77/job/5\npass\tlint\thttps://x\n' > "$ST/checks.$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$BR")"
eq "exits 0 after a successful fix" 0 "$(run)"
eq "one fix run" 1 "$(fix_runs)"
grep -q 'log of run 77: expected 1 got 2' "$PD/ci-failure.log" && ok "failed run log handed to the fix run" || bad "log: $(cat "$PD/ci-failure.log")"
grep -q 'FAILED CHECK: test' "$PD/ci-failure.log" && ok "failing check named" || bad "check name missing"
grep -q 'confined-push.sh:\*' "$CLAUDE_ARGS" && ok "fix run may push only via confined-push" || bad "no confined-push rule"
grep -q 'Bash(make \*)' "$CLAUDE_ARGS" && ok "fix run gets the project's build rules" || bad "no build rules"
eq "PR is marked ready after the fix" 1 "$(readied)"

reset; write_config '["pr-ready"]'
printf 'fail\ttest\thttps://github.com/acme/web/actions/runs/77/job/5\n' > "$ST/checks.default"
eq "still failing after the fix stops" 1 "$(run)"
eq "fix_attempts 1 means one fix run" 1 "$(fix_runs)"
eq "result is stopped" stopped "$(res)"
eq "PR stays draft" 0 "$(readied)"
grep -q 'urgent.*CI still failing after 1 fix attempt(s): test' "$NOTIFY_LOG" && ok "urgent push names the failing check" || bad "push: $(cat "$NOTIFY_LOG")"

reset; write_config '["pr-ready"]'
printf 'fail\ttest\thttps://github.com/acme/web/actions/runs/77/job/5\n' > "$ST/checks.default"
eq "a fix run that pushes nothing stops" 1 "$(FIX=none run)"
grep -q 'fix attempt 1 pushed nothing' "$PD/result" && ok "reason recorded" || bad "result: $(cat "$PD/result")"

reset; write_config '["pr-ready"]' '{ mark_ready: true, ci: { fix_attempts: 0 } }'
printf 'fail\ttest\thttps://x\n' > "$ST/checks.default"
eq "fix_attempts 0 stops on the first failure" 1 "$(run)"
eq "no fix run" 0 "$(fix_runs)"

reset; write_config '["pr-ready"]' '{ mark_ready: true, ci: { fix_attempts: 0 } }'
printf 'pass\tlint\thttps://x\nskipping\tdeploy\thttps://x\n' > "$ST/checks.default"
eq "skipped checks do not block a pass" 0 "$(run)"
reset; write_config '["pr-ready"]' '{ mark_ready: true, ci: { fix_attempts: 0 } }'
printf 'pass\tlint\thttps://x\nstatus-fail\tci/ext\thttps://x\n' > "$ST/checks.default"
eq "a failed commit status is a failure" 1 "$(run)"
grep -q 'ci/ext' "$PD/result" && ok "reason names the status context" || bad "result: $(cat "$PD/result")"

reset; write_config '["pr-ready"]'
echo none > "$ST/checks.default"
eq "no checks reported stops" 1 "$(run)"
grep -q 'no CI checks reported' "$PD/result" && ok "reason: no checks" || bad "result: $(cat "$PD/result")"

echo "== browser verdicts"
reset; write_config '["pr-ready"]'
eq "browser fail stops" 1 "$(BROWSER=fail run)"
eq "PR stays draft on browser fail" 0 "$(readied)"
grep -q 'Checked the nav.' "$PD/browser-report.md" && ok "report kept" || bad "no report"

reset; write_config '["pr-ready"]'
eq "a verdict without this run's nonce is not a pass" 1 "$(BROWSER=forge run)"
grep -q 'gave no verdict' "$PD/result" && ok "reason: no verdict" || bad "result: $(cat "$PD/result")"

reset; write_config '["pr-ready"]' '{ mark_ready: true, browser: { serve: "exit 3", url: "http://localhost:3999" } }'
printf '#!/bin/bash\necho 000\n' > "$TMP/bin/curl"
eq "a server that never answers stops" 1 "$(run)"
grep -q 'browser.serve exited before' "$PD/result" && ok "reason: server exited" || bad "result: $(cat "$PD/result")"
printf '#!/bin/bash\necho 200\n' > "$TMP/bin/curl"

echo "== refusals"
reset; write_config '["pr-ready"]'
: > "$EA_AGENT_DIR/state/autopilot-items.tsv"
eq "an item not in the ledger is refused" 2 "$(run)"
eq "no GitHub calls for it" 0 "$(grep -c . "$ST/calls")"

reset; write_config '["pr-ready"]' "" '["other"]'
eq "an origin outside github.repos is refused" 2 "$(run)"
grep -q "origin 'acme/web' is not one of" "$PD/result" && ok "reason names the origin" || bad "result: $(cat "$PD/result")"

reset; write_config '["pr-ready"]'
rm -f "$Q/completed/$ITEM"
eq "an item not in completed/ is refused" 2 "$(run)"

reset; write_config '["pr-ready"]'
printf '42\thttps://x/1\ttrue\n43\thttps://x/2\ttrue\n' > "$ST/prlist"
eq "two open PRs for the branch stops" 1 "$(run)"
eq "nothing marked ready" 0 "$(readied)"

echo "== branch recording"
rec() { ( PLUGIN_ROOT="$REPO_ROOT"; . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-confined-run.sh"
          log() { :; }; record_ticket_branch "$ITEM" "$1" ); cat "$PD/branch" 2>/dev/null; }
reset; write_config '[]'; rm -f "$PD/branch"
git -C "$TMP/repo" checkout -q "$BR"
eq "a prefixed branch is recorded" "$BR" "$(rec "$TMP/repo")"
rm -f "$PD/branch"; git -C "$TMP/repo" checkout -q main
eq "the base branch is not recorded" "" "$(rec "$TMP/repo")"
git -C "$TMP/repo" checkout -q --detach
eq "a detached HEAD is not recorded" "" "$(rec "$TMP/repo")"
git -C "$TMP/repo" checkout -q main

echo "== validation"
valid() { ( . "$REPO_ROOT/scripts/lib-paths.sh"; . "$REPO_ROOT/scripts/lib-jobs.sh"
            rows="$(jobs_enumerate)"; jobs_validate "$(printf '%s\n' "$rows" | head -1)" "$rows" ); }
write_config '[]'
eq "the default after_pr is valid" "" "$(valid)"
write_config '[]' '{ mark_redy: true }'
eq "unknown after_pr key is refused" "after_pr: unknown key 'mark_redy' (allowed: budget_usd max_runtime mark_ready ci browser)" "$(valid)"
write_config '[]' '{ browser: { serve: "npm run dev", url: "https://staging.example.com" } }'
eq "a non-localhost browser url is refused" "after_pr.browser.url must be an http://localhost[:port] URL (the branch is served locally)" "$(valid)"
write_config '[]' '{ browser: { url: "http://localhost:3000" } }'
eq "browser without serve is refused" "after_pr.browser.serve is required" "$(valid)"
write_config '[]' '{ ci: { fix_attempts: 5 } }'
eq "fix_attempts above 3 is refused" "after_pr.ci.fix_attempts '5' must be 0-3" "$(valid)"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
