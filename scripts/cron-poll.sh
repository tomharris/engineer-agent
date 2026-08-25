#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
source "${PLUGIN_ROOT}/scripts/lib-paths.sh"
AGENT_DIR="$EA_AGENT_DIR"
LOG_FILE="${AGENT_DIR}/state/cron-poll.log"

# cron runs with a minimal PATH that usually omits ~/.local/bin (where the claude
# CLI is commonly installed), causing "claude: command not found". Make sure it's
# findable regardless of how the script is invoked.
export PATH="${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"
# CLAUDE_BIN can be set in the environment to select a specific Claude Code binary
# (e.g. a version shim or non-standard install path); otherwise discover it on PATH.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "${HOME}/.local/bin/claude")}"
# Per-run budget cap for the headless poll. A full 6-project × 4-source poll (GitHub + Jira +
# Slack + Slite) that reads live Slack channels and may draft a PR review / ticket intent inline
# can exceed a low cap; when it does, claude -p aborts mid-run, writes no receipt, and the next
# fire re-attempts the same work (a $2 default did exactly this after Slack reads started
# working, 2026-07-22). Override with EA_POLL_BUDGET_USD; install-cron.sh bakes it into launchd.
POLL_BUDGET_USD="${EA_POLL_BUDGET_USD:-6.00}"

# Ensure state directory exists
mkdir -p "${AGENT_DIR}/state"

# Single-run lock: a scheduled poll normally finishes in minutes, but a slow run (large
# backlog, many Slack reads) can still be in flight when the next fire lands — and a manual
# run can collide with a scheduled one. Two concurrent polls thrash the same state/receipt
# files and each burns the full budget racing the other (observed 2026-07-22). Take a PID
# lock and exit early if another poll holds it; a stale lock (dead PID) is reclaimed.
LOCK_FILE="${AGENT_DIR}/state/cron-poll.lock"
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
  echo "--- Poll skipped at $(date -u +%Y-%m-%dT%H:%M:%SZ): another poll (PID $(cat "$LOCK_FILE")) is running ---" >> "$LOG_FILE"
  exit 0
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

echo "--- Poll started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"

# LIVENESS, not dedup state. `claude -p` exits 0 whenever the CLI ran, regardless of
# whether the work happened, so the exit code is worthless as a health signal — this
# script reported success on every run for a month while every poll was being denied.
# We prove the run reached its final step by making the model echo back a token only THIS
# run knows: the script mints RUN_ID below and the prompt requires the model to copy it
# verbatim into a receipt file. Freshness is proven by the id, not by content mutation.
#
# This replaced a sha256 fingerprint of last-poll.yaml, which was wrong twice over:
#   - last-poll.yaml is a semantic dedup cutoff, not a health signal. poll-slack's
#     last_checked_ts is the highest Slack message ts seen, so a legitimate zero-message
#     poll CANNOT advance it — a Slack-only config false-warned on every quiet poll.
#   - The values are model-authored and were observed fabricated (a real run wrote a
#     last_checked 40 minutes in the future, rounded to the half hour). Content-change is
#     only a freshness signal if the content is reliably distinct per run. It isn't.
# Both files still matter — they answer different questions. Keep them separate.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECEIPT_FILE="${AGENT_DIR}/state/last-poll-receipt.yaml"

# Dependency-free top-level scalar reader (same approach as lib-ntfy.sh's yaml_ntfy_get).
# Deliberately NOT jq: cron-poll.sh has no jq dependency and install-cron.sh does not check
# for one — only the separately-installed approval-listener.sh requires it. Single awk
# process, no pipeline, so `set -euo pipefail` can't trip on SIGPIPE.
receipt_field() {
  [ -f "$RECEIPT_FILE" ] || return 0
  awk -v k="$1" '
    index($0, k ":") == 1 {
      v = substr($0, length(k) + 2)
      sub(/^ +/, "", v); sub(/ +$/, "", v)
      gsub(/^"|"$/, "", v)
      print v; exit
    }' "$RECEIPT_FILE"
}

# List the entries of the receipt's `errors:` block (one per line, quotes stripped).
# Same dependency-free awk approach as receipt_field. An inline `errors: []` yields
# nothing, which callers treat as "no detail available".
receipt_errors() {
  [ -f "$RECEIPT_FILE" ] || return 0
  awk '
    /^errors:/ { in_block = 1; next }
    in_block && /^[^ ]/ { in_block = 0 }
    in_block && /^ *- / {
      v = $0
      sub(/^ *- */, "", v)
      gsub(/^"|"$/, "", v)
      print v
    }' "$RECEIPT_FILE"
}

# The log is append-only, so any cause-extraction grep over the whole file can resurrect
# a PREVIOUS run's error line and report it as this run's cause. Record where this run's
# lines start; run_log yields only the slice this run appended.
LOG_START_LINE="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"
run_log() { tail -n "+$((LOG_START_LINE + 1))" "$LOG_FILE"; }

# Run claude headlessly with the poll command.
#
# IMPORTANT: this is a non-interactive batch run. The agent must DO the work, not
# describe a plan. We invoke the /engineer-agent poll command directly and forbid
# plan mode, and pin a non-interactive permission mode so the run never inherits the
# user's global `permissions.defaultMode` (e.g. "plan"), in which claude -p just prints
# a plan and exits 0 without doing anything.
#
# --permission-mode alone is NOT enough: `gh` is not one of the Bash commands Claude Code
# treats as built-in read-only, so it prompts in every mode — and a prompt in `-p` is a
# denial. Without the allowlist below every poll silently failed on every `gh` call.
#
# The allowlist is deliberately READ-ONLY for every integration. Polling only discovers
# work and drafts responses; posting is execute-item's job, behind the human approval
# gate. Since poll ingests untrusted text (PR/issue bodies, Slack messages), a
# prompt-injection payload must not be able to reach a write verb. So `gh pr create`,
# `gh pr review`, `gh issue create` and the Slack `send` verb (spy or slack-mcp.sh) are all
# unmatched here, as is `gh api` (`gh api -X POST` writes). Anything unmatched fails
# non-interactively, which the no-progress check below surfaces as a WARN rather than a silent
# no-op.
#
# Five gotchas encoded below, each of which silently broke a real run:
#   1. Bash rules match the literal command text, so `mv *` -- a `~/`-prefixed pattern
#      would miss the absolute paths the model actually writes.
#   2. Use Edit(...), never Write(...): the CLI rejects Write(path) rules outright ("only
#      Edit(path) rules are [matched by file permission checks]"), and one Edit rule
#      covers every file-editing tool, Write included.
#   3. Path rules need `//abs` to anchor at the filesystem root; a single leading `/`
#      anchors to the cwd instead. AGENT_DIR is already absolute, hence the extra slash
#      in "Edit(/${AGENT_DIR}/**)".
#   4. MCP tools are denied unless named explicitly, exactly like `gh`. The Jira and
#      Slite pollers drive MCP servers (there is no read-only Bash verb for them), so
#      without the entries below `poll-jira`/`poll-slite` silently skip every run —
#      Jira tickets never get queued even though auth and everything else work. Only
#      the READ verbs are listed (search + fetch); the write tools (createJiraIssue,
#      editJiraIssue, transitionJiraIssue, addComment*, slite create/edit/append) stay
#      unmatched, keeping posting behind the execute-item gate as with `gh`/`spy`.
#   5. Allowlist the read-only PREFLIGHT verbs (`gh auth status`, `gh --version`), not just the
#      data verbs. The model routinely probes a CLI's health before using it; when the probe is
#      denied it concludes the whole CLI is unavailable and aborts every source WITHOUT ever
#      trying the verbs that are allowed. Observed 2026-07-24: five consecutive polls reported
#      `status: error` with all 8 GitHub sources in `errors:` while `gh pr list` was allowlisted
#      and working the whole time — the transcripts show only `gh auth status` / `gh --version`
#      were ever issued. (The 2026-07-23 run hit the same denial and happened to recover, which
#      is why this presents as intermittent.) Identical shape to the Slack `auth` preflight fixed
#      in 162a4bb: an unallowlisted probe poisons a perfectly-allowed read path. Both verbs are
#      read-only and write nothing, so the read-only invariant is untouched.
#
# The Slack read verbs are keyed off the effective Slack binary, which depends on
# agent.slack.method (resolved in plain bash below, before claude starts):
#   - method: spy (default)  -> `spy`
#   - method: mcp-proxy      -> the bundled scripts/slack-mcp.sh (Enterprise Grid; reuses the
#                               Keychain OAuth token). It runs as ONE Bash invocation, so its
#                               internal curl/jq/security subprocesses need no separate rule —
#                               one rule covers the whole call. No `Bash(curl *)`.
# Either way only `read`/`thread` are listed; `<bin> send` stays UNMATCHED, so posting remains
# execute-item's job behind the approval gate — identical to the gh read-vs-write split above.
#
# mcp-proxy gotcha (this silently broke the first poll after Slack channels were configured, AND
# a first attempted fix that added an unexpanded `${CLAUDE_PLUGIN_ROOT}` literal rule — see below):
# poll-slack references the shim as `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh` (SKILL.md §1 — the
# plugin-root var, not an absolute path). Two facts, each confirmed from a real failing run's
# transcript, decide the rule shape:
#   1. The MODEL expands ${CLAUDE_PLUGIN_ROOT} to an absolute path before Bash sees it — it does
#      NOT pass the literal `${CLAUDE_PLUGIN_ROOT}` token. So a single-quoted literal rule never
#      matches; that earlier fix was dead code.
#   2. When the plugin is installed via marketplace it SHADOWS our `--plugin-dir`, so that expanded
#      root is the INSTALLED cache path (…/plugins/cache/engineer-agent/engineer-agent/<ver>), NOT
#      this script's dev-repo PLUGIN_ROOT. So a rule built only from PLUGIN_ROOT also misses.
# Fix: allowlist the shim's EXPANDED path for BOTH candidate roots — our script-derived PLUGIN_ROOT
# and resolve_installed_plugin_root() (the cache path the runtime actually resolves) — so whichever
# one applies, a rule matches. The spy/bin backend needs none of this: `spy` is a bare literal
# identical in rule and call.
# ---------------------------------------------------------------------------------------------
# PHASE A — deterministic collectors (scripts/poll-*.sh), gated by agent.poll.scripted_sources.
#
# WHY: the model half of a poll re-reads ~87KB of skill prose and every raw API response on EVERY
# fire, to do work that is almost entirely string comparison and file writing — and the steady
# state of this queue is items_queued: 0. A scripted collector answers "is there anything new?"
# in seconds for no model tokens, so the common case stops costing a Sonnet session entirely.
#
# It also deletes a bug class rather than warning about it. Nearly every poll-path fix in this
# repo's history is the model producing a non-deterministic string: four separate allowlist fixes
# for varying command forms and plugin roots (27380f2, bcdd023, 481286c, 162a4bb), a fabricated
# timestamp 40 minutes in the future (2501ecf), malformed JQL (822e1f9), a timezone bug (66fb442).
# None of those can occur in a script.
#
# DENY-BY-DEFAULT. An absent or empty agent.poll.scripted_sources leaves this whole block inert
# and the run behaves exactly as it did before — the same posture as agent.autonomy.auto_execute
# and projects.<slug>.exec.allowed_commands. Resolved in plain bash BEFORE claude starts, like
# SLACK_METHOD/SLACK_BIN, so untrusted text can never influence which path runs.
SCRIPTED_SOURCES="${EA_POLL_SCRIPTED_SOURCES:-$("${PLUGIN_ROOT}/scripts/ea-config.sh" list agent.poll.scripted_sources 2>/dev/null | tr '\n' ' ')}"
SCRIPTED_SOURCES="$(printf '%s' "$SCRIPTED_SOURCES" | tr ',' ' ' | tr -s ' ')"
MANIFEST="${AGENT_DIR}/state/poll-manifest.tsv"
: > "$MANIFEST" 2>/dev/null || MANIFEST=""

is_scripted() { case " $SCRIPTED_SOURCES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

SCRIPTED_RAN=""
if is_scripted github-issues; then
  echo "phase A: collecting github-issues deterministically" >> "$LOG_FILE"
  if "${PLUGIN_ROOT}/scripts/poll-github-issues.sh" --run-ts "$RUN_TS" --manifest "$MANIFEST" >> "$LOG_FILE" 2>&1; then
    SCRIPTED_RAN="${SCRIPTED_RAN} github_issues"
  else
    echo "WARN: phase A poll-github-issues.sh exited non-zero; leaving this source to the model" >> "$LOG_FILE"
  fi
fi
if is_scripted github; then
  echo "phase A: collecting github PRs deterministically" >> "$LOG_FILE"
  if "${PLUGIN_ROOT}/scripts/poll-github-prs.sh" --run-ts "$RUN_TS" --manifest "$MANIFEST" >> "$LOG_FILE" 2>&1; then
    SCRIPTED_RAN="${SCRIPTED_RAN} github"
  else
    echo "WARN: phase A poll-github-prs.sh exited non-zero; leaving this source to the model" >> "$LOG_FILE"
  fi
fi

# Can the model be skipped entirely this run? Only when EVERY configured source across every
# project was collected by a script AND the collectors produced nothing needing a draft.
#
# The check is over CONFIGURED sources only — a source that is not set up is "skipped", which the
# receipt contract already says "MUST NOT affect status". Anything left unscripted (Jira, Slite,
# Slack, PR review) keeps the model in the loop, so this can only ever skip a run that genuinely
# has no work.
model_needed=1
if [ -n "$SCRIPTED_RAN" ]; then
  unscripted=""
  while IFS= read -r pslug; do
    [ -n "$pslug" ] || continue
    while IFS="	" read -r psrc pstate; do
      [ "$pstate" = "configured" ] || continue
      case " $SCRIPTED_RAN " in *" $psrc "*) continue ;; esac
      unscripted="${unscripted} ${pslug}/${psrc}"
    done < <("${PLUGIN_ROOT}/scripts/ea-config.sh" sources "$pslug")
  done < <("${PLUGIN_ROOT}/scripts/ea-config.sh" projects)
  if [ -z "$unscripted" ] && [ -n "$MANIFEST" ] && [ ! -s "$MANIFEST" ]; then
    model_needed=0
  fi
fi

# Pre-expand the note handed to the model. Like the SLACK: directive, this is resolved in bash so
# the model is never left to work out which sources were already collected or where the manifest is.
if [ -n "$SCRIPTED_RAN" ]; then
  SCRIPTED_NOTE="The following sources were ALREADY collected this run by a deterministic script and their queue items already exist in ${AGENT_DIR}/queue/incoming/ with correct frontmatter:${SCRIPTED_RAN}. Do NOT re-poll them, do NOT re-query their APIs, and do NOT create queue files for them. Instead read the manifest at ${MANIFEST} — one tab-separated row per item: action, path, type, project, source_id, needs_routing, needs_kind_check, title. For EACH row: read the item at that path, write its '## Draft Response' section, set status: drafted, and move it to ${AGENT_DIR}/queue/drafts/. An item left in incoming/ is invisible to every approval path, so finishing this move is not optional. When needs_routing is 1 the item is project: _unrouted — apply ONLY Tier 3b of ${PLUGIN_ROOT}/references/routing-ladder.md (semantic match against each candidate's routing.description, choosing from matched_projects ONLY), then set project/routing_method: inferred/routing_rationale, remove matched_projects, and classify its kind; abstaining and leaving it _unrouted is a correct answer. When needs_kind_check is 1 apply ONLY Tier 3 Form B of ${PLUGIN_ROOT}/references/ticket-kind.md (is the leading word a true imperative verb, or a noun the title is about?) and switch the item to ticket-investigation only if it fires. Every other tier of both ladders has ALREADY been applied — do not redo them. Poll all remaining, non-scripted sources normally."
else
  SCRIPTED_NOTE="No sources were collected by a script this run. Poll every configured source yourself, as normal."
fi

if [ "$model_needed" -eq 0 ]; then
  # Write the receipt in bash from GROUND TRUTH. Note this is strictly stronger than the model-
  # written receipt below, which cron-poll.sh itself documents as "an ATTESTATION, not a
  # measurement: it cannot catch a model that confidently lies". Here the script knows what it
  # queried and what it wrote, so run_id is a measurement.
  {
    printf 'run_id: "%s"\n' "$RUN_ID"
    printf 'finished_at: "%s"\n' "$RUN_TS"
    printf 'status: ok\n'
    printf 'items_queued: 0\n'
    printf 'sources_polled:\n'
    while IFS= read -r pslug; do
      [ -n "$pslug" ] || continue
      while IFS="	" read -r psrc pstate; do
        [ "$pstate" = "configured" ] && printf '  - %s/%s\n' "$pslug" "$psrc"
      done < <("${PLUGIN_ROOT}/scripts/ea-config.sh" sources "$pslug")
    done < <("${PLUGIN_ROOT}/scripts/ea-config.sh" projects)
    printf 'skipped:\n'
    while IFS= read -r pslug; do
      [ -n "$pslug" ] || continue
      while IFS="	" read -r psrc pstate; do
        case "$pstate" in skipped:*) printf '  - "%s/%s: %s"\n' "$pslug" "$psrc" "${pstate#skipped:}" ;; esac
      done < <("${PLUGIN_ROOT}/scripts/ea-config.sh" sources "$pslug")
    done < <("${PLUGIN_ROOT}/scripts/ea-config.sh" projects)
    printf 'errors: []\n'
  } > "$RECEIPT_FILE"
  echo "phase A found no new work and every configured source is scripted; skipping the model entirely" >> "$LOG_FILE"
  POLL_STATUS=0
  SKIP_MODEL=1
else
  SKIP_MODEL=0
fi

SLACK_METHOD="$(yaml_agent_slack method)"; SLACK_METHOD="${SLACK_METHOD:-spy}"
if [ "$SLACK_METHOD" = "mcp-proxy" ]; then
  SLACK_BIN="${PLUGIN_ROOT}/scripts/slack-mcp.sh"
else
  SLACK_BIN="$(yaml_agent_slack bin)"; SLACK_BIN="${SLACK_BIN:-spy}"
fi
allowed_tools=(
  "Bash(gh pr list:*)" "Bash(gh pr view:*)" "Bash(gh pr diff:*)"
  "Bash(gh issue list:*)" "Bash(gh issue view:*)"
  "Bash(gh auth status:*)" "Bash(gh --version:*)"
  mcp__atlassian__searchJiraIssuesUsingJql mcp__atlassian__getJiraIssue
  mcp__slite__search-notes mcp__slite__get-note mcp__slite__get-note-children
  "Bash(${PLUGIN_ROOT}/scripts/notify.sh *)"
  # NOTE: ticket-investigation items need NO new verbs here. The poll only DRAFTS an investigation
  # plan — the research, the ticket comment and any transition all happen later, behind the approval
  # gate, in the listener's confined run_ticket_investigation. mcp__atlassian__getJiraIssue (the
  # source of the `issuetype` field the kind ladder needs) and Read (references/ticket-kind.md) are
  # already listed above. Do NOT add addCommentToJiraIssue / gh issue comment here: it would break
  # the "polling reads; only execute-item writes" invariant.
  "Bash(mv *)"
  # The model habitually appends a status probe (`… auth 2>&1; echo "EXIT:$?"`). Claude Code
  # evaluates each part of a compound command separately, so an unlisted `echo` gets the WHOLE
  # invocation refused with "contains multiple operations … the following part requires approval:
  # echo …". The model recovers by retrying without it, so this never failed a poll — it just
  # burned a turn on nearly every run. `echo` is read-only, so listing it costs nothing against
  # the read-only invariant.
  "Bash(echo:*)"
  Read Glob Grep
  "Edit(/${AGENT_DIR}/**)"
)

# Slack read verbs. `send` is deliberately absent under EVERY form below — that is what keeps
# posting execute-item's job, behind the approval gate. `auth` is included because the model runs
# it as a read-only token preflight before reading (observed getting denied and cascading to a
# doomed direct-connector fallback when only read/thread were allowed — 162a4bb).
SLACK_READ_VERBS=(read thread auth)

# A rule must match the command FORM the model emits, not just the shim's PATH. Two independent
# axes vary, and BOTH have caused real Slack-wide poll failures:
#
#   axis 1 — the root. ${CLAUDE_PLUGIN_ROOT} expands to one of THREE dirs depending on how the
#     plugin was loaded (dev-repo --plugin-dir, installed cache, marketplace checkout). See the
#     mcp-proxy gotcha above and lib-paths.sh.
#   axis 2 — the prefix. The model does not always invoke the shim bare; it has been observed
#     emitting `bash <abs>/scripts/slack-mcp.sh auth 2>&1`, whose executable is `bash`, matching
#     no `<abs>/…` rule. That denial is FATAL rather than recoverable: the model concludes the
#     shim is unavailable and cascades to the direct mcp__claude_ai_Slack__* connector, which is
#     also unlisted, so both Slack paths die and every Slack source reports an error.
#     Transcript-confirmed on 2026-08-01T15:00Z and 2026-08-03T13:04Z — exactly the two runs out
#     of the last sixteen that emitted a `bash `-prefixed call, and exactly the two that failed.
#
# Generate roots × verbs × forms from lists rather than hand-repeating the rules: the block this
# replaced already repeated four near-identical lines per root, and hand-doubling that is how the
# next variation gets missed. The prompt also now pins the exact binary and forbids the `bash `
# prefix (see the SLACK: directive below) — that is the real fix; this is defense in depth for
# when the model improvises anyway.
if [ "$SLACK_METHOD" = "mcp-proxy" ]; then
  SEEN_ROOTS=""
  for SHIM_ROOT in "$PLUGIN_ROOT" "$(resolve_installed_plugin_root)" "$(resolve_marketplace_plugin_root)"; do
    [ -n "$SHIM_ROOT" ] || continue
    case "$SEEN_ROOTS" in *"|${SHIM_ROOT}|"*) continue ;; esac
    SEEN_ROOTS="${SEEN_ROOTS}|${SHIM_ROOT}|"
    for VERB in "${SLACK_READ_VERBS[@]}"; do
      allowed_tools+=(
        "Bash(${SHIM_ROOT}/scripts/slack-mcp.sh ${VERB}:*)"
        "Bash(bash ${SHIM_ROOT}/scripts/slack-mcp.sh ${VERB}:*)"
      )
    done
    # notify.sh for the extra roots too, as cheap insurance in case a skill invokes it via
    # ${CLAUDE_PLUGIN_ROOT} rather than the pre-expanded path this script injects into the prompt.
    [ "$SHIM_ROOT" = "$PLUGIN_ROOT" ] || allowed_tools+=( "Bash(${SHIM_ROOT}/scripts/notify.sh *)" )
  done
else
  # spy backend: a bare literal on PATH, identical in rule and invocation — none of the above applies.
  allowed_tools+=(
    "Bash(${SLACK_BIN} read:*)" "Bash(${SLACK_BIN} thread:*)" "Bash(${SLACK_BIN} auth:*)"
  )
fi

# --add-dir: acceptEdits only auto-accepts edits under the working directory, and cron
# runs from $HOME. Naming the agent dir explicitly (alongside the scoped Edit rule above)
# is what lets the run record state and move queue files.
# `|| POLL_STATUS=$?` is required: under `set -e` a non-zero exit here (budget exhausted,
# CLI error) would abort the script before the health check below could report it — the
# loudest failures would stay the most invisible.
#
# Argument order matters: --allowedTools takes a variable number of values, so it must not
# be the last flag before the prompt or it swallows the prompt as another rule (the run
# then dies with "Input must be provided ... when using --print"). Keep a single-value
# flag between the allowlist and the prompt.
POLL_STATUS=0
if [ "${SKIP_MODEL:-0}" -eq 1 ]; then
  # Phase A already collected every configured source and found nothing to draft, and it wrote the
  # receipt from ground truth. There is no work for a model, so none is started — this is the
  # steady state of a healthy queue and the reason this change exists.
  :
else
"$CLAUDE_BIN" -p \
  --plugin-dir "$PLUGIN_ROOT" \
  --add-dir "$AGENT_DIR" \
  --model sonnet \
  --permission-mode acceptEdits \
  --allowedTools "${allowed_tools[@]}" \
  --max-budget-usd "$POLL_BUDGET_USD" \
  "Execute now — do NOT enter plan mode, do NOT output a plan, do NOT ask questions. Perform the work directly and report the results when finished.

You ARE the scheduled poll for this cycle, not an observer of it. Do NOT check whether a poll has already run, and do NOT skip a source because recent queue items or a recent last_checked suggest it was already covered. Poll every configured source yourself, now.

MEMORY: do NOT create, update, or delete memory files, and do NOT treat any pre-existing memory as evidence about this run. Record what happened ONLY in the receipt described below. A receipt is a fact about ONE run; a memory is a belief applied to ALL future runs, and an unattended run must never write the latter — a single wrong conclusion would otherwise be re-read and re-confirmed by every later poll instead of being retested. So if a tool or command appears unavailable, establish that FRESH this run, and never skip a source because a memory claims it will fail.

Run the /engineer-agent poll command for all configured sources (equivalent to '/engineer-agent poll all'). Read config from ${AGENT_DIR}/engineer.yaml and follow commands/poll.md and the per-source poll skills. Iterate over all projects in the config. For each project, check all configured sources (GitHub, Slack, Jira, Slite) for new items since the last poll recorded in ${AGENT_DIR}/state/last-poll.yaml. For each new item, create a queue file in ${AGENT_DIR}/queue/incoming/ with the standard frontmatter format documented in CLAUDE.md (include the project slug in the frontmatter), then generate a draft and move it to ${AGENT_DIR}/queue/drafts/. For EACH newly drafted item, send a push notification by running: ${PLUGIN_ROOT}/scripts/notify.sh --title '<type>: <title>' --message '<project> — <short summary>' --priority '<priority from frontmatter>' --item-id '<the queue filename>' --source-url '<source_url from frontmatter>' --tags 'inbox_tray'. (notify.sh no-ops safely if ntfy is not configured, so always call it.)

SLACK: the effective Slack CLI for this run is EXACTLY this command — ${SLACK_BIN} — and it is already installed and executable. Do NOT search the filesystem for it (no find, no ls), do NOT read \${CLAUDE_PLUGIN_ROOT}, and do NOT substitute a different copy of the same script from another directory; only the command above is permitted. Invoke it directly and bare, as '${SLACK_BIN} read <channel> <count> --json -w <workspace>' (likewise 'thread' and 'auth'). Do NOT prefix it with bash, sh, or env, and do NOT wrap it in a compound command — no ';', no '&&', no trailing 'echo'. Issue one plain command per call. If a Slack call is denied or the CLI is unavailable, record Slack as an error for that project and move on; do NOT fall back to the mcp__claude_ai_Slack__* connector tools, which are deliberately not available to this run and will only waste the attempt.

SCRIPTED: ${SCRIPTED_NOTE}

STATE: use exactly ${RUN_TS} as this poll's timestamp — do not compute or guess one. After polling each source, set that source's last_checked in ${AGENT_DIR}/state/last-poll.yaml to exactly ${RUN_TS}, WHETHER OR NOT it produced any items: a source that found zero items was still polled successfully and must have its cutoff advanced. (Exception: Slack's last_checked_ts tracks the highest Slack message timestamp actually seen — leave it unchanged when no messages were read.)

FINAL STEP — do this last, always, even if you found zero items and even if some sources failed. Write ${AGENT_DIR}/state/last-poll-receipt.yaml, replacing any existing content, with exactly this shape:

run_id: \"${RUN_ID}\"
finished_at: \"${RUN_TS}\"
status: ok
items_queued: 0
sources_polled:
  - <project-slug>/<source>
skipped: []
errors: []

Rules: copy run_id verbatim — it is how the cron proves this receipt came from THIS run and not a previous one. items_queued is the number of items you moved into drafts/ this run (0 is a normal, successful result). Every source belongs in exactly ONE of three buckets; never claim a source you did not query:
- sources_polled: a source you actually issued a query for in THIS run.
- skipped: a source that is NOT configured or NOT enabled for that project — with a one-line reason. This covers Jira when the project's tracker is not 'jira' or it has no jira section; Slite when there is no slite section; Slack when slack.channels is empty; GitHub Issues when there is no github.issues section; and the like. A skipped source is a normal, expected result and MUST NOT affect status.
- errors: a CONFIGURED source that you attempted and that FAILED (auth error, API error, or a required tool missing for an enabled source) — with a one-line reason.
status is computed over CONFIGURED sources only: 'ok' if every configured source was queried without error (skipped sources are fine); 'partial' if at least one configured source failed while at least one other configured source succeeded; 'error' if no configured source could be polled.

Be concise." \
  </dev/null >> "$LOG_FILE" 2>&1 || POLL_STATUS=$?
fi

# A bare `[ ... ] && echo` would abort the script under `set -e` whenever the test is
# false, since the list then exits non-zero. Use an explicit if.
if [ "$POLL_STATUS" -ne 0 ]; then
  echo "WARN: claude exited ${POLL_STATUS}" >> "$LOG_FILE"
fi

# Trust the filesystem, not the exit code (same principle as approval-listener.sh).
# The receipt is model-written, so it is an ATTESTATION, not a measurement: it cannot catch
# a model that confidently lies. It reliably catches every mechanical failure — execution
# error, plan mode, denied Edit, budget exhaustion, hard no-op — because all of them leave
# no receipt or a stale run_id, and RUN_ID is a value only this run knows.
FAIL_REASON=""
if [ ! -f "$RECEIPT_FILE" ]; then
  FAIL_REASON="no receipt written — the run never reached its final step"
elif [ "$(receipt_field run_id)" != "$RUN_ID" ]; then
  FAIL_REASON="receipt is stale (run_id '$(receipt_field run_id)', expected '${RUN_ID}') — this run wrote nothing"
fi

if [ -n "$FAIL_REASON" ]; then
  echo "WARN: poll did not complete: ${FAIL_REASON} — see $LOG_FILE" >> "$LOG_FILE"
  # Surface the underlying cause in the alert itself, not just the log. The receipt check tells
  # us the run didn't finish; the actual reason (an API failure: "API Error: … ENOTFOUND", a
  # misauthed CLI: "Not logged in", "command not found", budget exhaustion) is usually the last
  # recognizable error line this run logged. Prefer a real cause line; fall back to the generic
  # exit-code WARN, then "unknown" so the message is never empty. Each grep is `|| true`-guarded:
  # under pipefail a no-match grep would otherwise abort the script before the notify fires.
  LAST_ERR="$(run_log | grep -E 'API Error|Not logged in|command not found|No such file|Execution error' | tail -1 || true)"
  LAST_ERR="${LAST_ERR:-$(run_log | grep 'WARN: claude exited' | tail -1 || true)}"
  LAST_ERR="${LAST_ERR:-unknown (see log)}"
  LAST_ERR="${LAST_ERR:0:200}"
  # --priority urgent, not "high": notify.sh maps engineer-agent priorities
  # (urgent|normal|low) onto ntfy's, and an unrecognized value silently becomes
  # "default" — which would quietly downgrade this very alert.
  "${PLUGIN_ROOT}/scripts/notify.sh" \
    --title 'engineer-agent: poll failed' \
    --message "Poll did not complete (${FAIL_REASON}). Last error: ${LAST_ERR}. See state/cron-poll.log." \
    --priority urgent --tags warning --fyi >> "$LOG_FILE" 2>&1 || true
else
  RECEIPT_STATUS="$(receipt_field status)"
  echo "poll completed: status=${RECEIPT_STATUS:-unknown} items_queued=$(receipt_field items_queued)" >> "$LOG_FILE"
  # A zero-item poll is a SUCCESS: fresh receipt, status ok -> silent. Partial failure (a
  # source that errored while others succeeded) is something the old hash check could never
  # detect — a real run advanced github state while skipping github_issues entirely and
  # sailed through the fingerprint clean. A partial/error self-heals next cycle, so it goes
  # out at --priority normal, not urgent — it shouldn't wake anyone.
  if [ "$RECEIPT_STATUS" != "ok" ]; then
    echo "WARN: poll reported status=${RECEIPT_STATUS:-unknown} — see $LOG_FILE" >> "$LOG_FILE"
    # Say WHAT failed, not just that something did: inline the receipt's first errors:
    # entry (and the count) so the push is actionable from a phone. Empty errors list
    # (defensive — status != ok should always carry entries) keeps the generic wording.
    ERR_LIST="$(receipt_errors)"
    if [ -n "$ERR_LIST" ]; then
      ERR_COUNT="$(printf '%s\n' "$ERR_LIST" | wc -l)"
      FIRST_ERR="$(printf '%s\n' "$ERR_LIST" | head -1)"
      FIRST_ERR="${FIRST_ERR:0:180}"
      STATUS_MSG="Poll finished with status=${RECEIPT_STATUS:-unknown} — ${ERR_COUNT} configured source(s) failed. First: ${FIRST_ERR}. See state/last-poll-receipt.yaml."
    else
      STATUS_MSG="Poll finished with status=${RECEIPT_STATUS:-unknown}. Check state/last-poll-receipt.yaml."
    fi
    "${PLUGIN_ROOT}/scripts/notify.sh" \
      --title 'engineer-agent: poll incomplete' \
      --message "$STATUS_MSG" \
      --priority normal --tags warning --fyi >> "$LOG_FILE" 2>&1 || true
  fi
fi

# Queue invariant: at most one item per (type, source_id). Unlike the receipt above this is a
# MEASUREMENT, not an attestation — it reads the queue the poll actually produced, so it holds even
# if the model misreports what it did. That distinction is the whole point: a duplicate is invisible
# otherwise, because queue filenames carry a fresh {YYYYMMDD-HHmmss} minted at write time and so a
# second copy of a ticket never collides with the first. It just sits there, and the human reviews
# (or implements) the same work twice.
#
# Two spec contradictions produced exactly that, and one of them was self-sustaining: re-queueing
# anything "updated since last_checked" fires for tickets engineer-agent itself touched, so posting
# findings as a Jira comment re-queued the ticket that had just been completed, which produced
# another comment. See references/queue-reconciliation.md.
#
# Advisory: a duplicate is a correctness bug in the poll, not a reason to fail the cron, and it
# self-heals once the redundant copy is rejected. Normal priority — it should not wake anyone.
DUP_OUT="$("${PLUGIN_ROOT}/scripts/queue-dedup-check.sh" 2>&1)" || DUP_RC=$?
DUP_RC="${DUP_RC:-0}"
if [ "$DUP_RC" -eq 1 ]; then
  printf '%s\n' "$DUP_OUT" >> "$LOG_FILE"
  echo "WARN: queue has duplicate items — see references/queue-reconciliation.md" >> "$LOG_FILE"
  DUP_IDS="$(printf '%s\n' "$DUP_OUT" | awk '/^  [^ ]/ { print $1 }' | paste -sd, - | cut -c1-160)"
  "${PLUGIN_ROOT}/scripts/notify.sh" \
    --title 'engineer-agent: duplicate queue items' \
    --message "Poll produced duplicate queue item(s): ${DUP_IDS:-see log}. Reject the redundant copy; keep the one a human has acted on." \
    --priority normal --tags warning --fyi >> "$LOG_FILE" 2>&1 || true
elif [ "$DUP_RC" -ne 0 ]; then
  # rc 2 = queue dir missing / bad usage. Worth a log line, not a push.
  echo "WARN: queue-dedup-check could not run (exit ${DUP_RC}): ${DUP_OUT}" >> "$LOG_FILE"
fi

echo "--- Poll finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "$LOG_FILE"
