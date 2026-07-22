#!/bin/bash
# approval-listener.sh — subscribe to the ntfy command topic and execute approvals.
#
# Streams the ntfy command_topic. Each "Approve"/"Reject" button tap on your phone
# arrives here as a message "approve|<item-id>" / "reject|<item-id>". For each new
# message this shells out to a headless `claude -p` running /engineer-agent execute.
#
# Run it under a process supervisor (see install-listener.sh) so it restarts on crash.
#
# SECURITY: on public ntfy.sh, anyone who knows command_topic can publish to it. The
# topic name is a secret — use a high-entropy name and/or an auth_token, or self-host.
# As defense in depth this script (a) accepts only `approve`/`reject` decisions,
# (b) accepts only item ids matching a strict queue-filename pattern, and (c) lets
# execute-item ignore anything no longer sitting in queue/drafts/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib-ntfy.sh
source "${SCRIPT_DIR}/lib-ntfy.sh"

# Self-reexec guard: remember our own path + mtime at startup. The reconnect loop
# (below) re-execs the script when this file changes on disk, so a code deploy that
# isn't followed by a service restart can't keep running stale — which once left the
# daemon silently missing the whole acknowledgement feature. Portable across Linux
# (stat -c) and macOS (stat -f).
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
script_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
SELF_MTIME="$(script_mtime "$SELF")"

# CLAUDE_BIN can be set in the environment to select a specific Claude Code binary
# (e.g. a version shim or non-standard install path); otherwise discover it on PATH.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "${HOME}/.local/bin/claude")}"
# NOTIFY_BIN can be overridden (e.g. by tests) to point at a stub notifier;
# otherwise use the plugin's notify.sh. Mirrors the CLAUDE_BIN override above.
NOTIFY_BIN="${NOTIFY_BIN:-${PLUGIN_ROOT}/scripts/notify.sh}"

# Per-item-type spend cap for the headless execute run. Implementing a ticket
# (implement-ticket runs a full inline implementation + self-review session) costs far more than posting a review or
# an answer, so `ticket` gets a generous cap and everything else a modest default.
# A flat 0.50 was too low even for some PR reviews and aborted every ticket approval
# with "Exceeded USD budget", stranding the item in drafts/. Tune to your appetite;
# an unknown/missing type falls back to the default.
DEFAULT_BUDGET_USD="${EA_EXECUTE_BUDGET_USD:-2.00}"
TICKET_BUDGET_USD="${EA_TICKET_BUDGET_USD:-8.00}"
# QA generation is a SEPARATE claude -p run after a ticket implementation (read + queue-draft
# only, no code), so it gets its own modest cap distinct from the implementation's TICKET cap.
QA_BUDGET_USD="${EA_QA_BUDGET_USD:-2.00}"

AGENT_DIR="${EA_AGENT_DIR}"
STATE_DIR="${AGENT_DIR}/state"
LOG_FILE="${STATE_DIR}/approval-listener.log"
SEEN_FILE="${STATE_DIR}/ntfy-seen.yaml"
SINCE_FILE="${STATE_DIR}/ntfy-listener.since"

mkdir -p "$STATE_DIR"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE" >&2; }

# push_ack — best-effort acknowledgement back to the user's outbound ntfy topic.
# Never fails the caller: an ntfy hiccup must not crash or stall the listen loop.
# priority is engineer-agent vocabulary (urgent|normal|low); notify.sh maps it.
push_ack() {
  local priority="$1" message="$2"
  "$NOTIFY_BIN" --fyi --title "engineer-agent" --priority "$priority" --message "$message" \
    </dev/null >>"$LOG_FILE" 2>&1 || true
}

# run_generic_execute — the read/post path for every non-ticket type (and any reject).
# Runs the shared execute-item skill via commands/execute.md with the allowlist that
# posts a review/answer/issue but physically cannot run a coding session.
#
# Pin --permission-mode so this headless run never inherits the user's global
# `permissions.defaultMode` (e.g. "plan"): in plan mode claude -p just prints a plan and
# exits 0 without executing, silently leaving the item in drafts/.
#
# Use acceptEdits + a tight --allowedTools allowlist rather than bypassPermissions:
# execute-item reads UNTRUSTED draft-body content (Slack/Jira/GitHub text), so a
# prompt-injection payload must not be able to run arbitrary commands. The allowlist is
# exactly what execute-item / execute.md legitimately need — gh, the Slack backend (spy AND
# slack-mcp.sh, so a reply posts under either agent.slack.method), mv, the plugin's
# notify.sh, the file-editing tools, and the slite/atlassian MCP tools. Anything else is
# denied; under acceptEdits a denied tool fails non-interactively, which the drafts/
# check surfaces as a WARN (no longer a silent no-op).
# Redirect stdin from /dev/null so claude doesn't try to read the listener's curl stream.
run_generic_execute() {
  local item="$1" decision="$2" budget="$3"
  # Both Slack backends are allowlisted so an approved slack-question reply posts under either
  # method: `spy send …` OR `slack-mcp.sh send …` (agent.slack.method: mcp-proxy). This is the
  # gated WRITE path — correct here, behind the ntfy approval — unlike the read-only poll.
  #
  # The `${PLUGIN_ROOT}/scripts/slack-mcp.sh *` rule uses the shell-expanded abs path, but the
  # skills invoke the shim via the UNEXPANDED `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh`, which
  # Claude Code's permission matcher compares literally (it does NOT expand the var). So without
  # the literal form below a mcp-proxy Slack read/send is denied headlessly — same gotcha that
  # broke the first poll after Slack was configured. Single-quote it so THIS script's bash leaves
  # the (empty here) var untouched; it resolves inside the claude run.
  local allowed_tools=(
    "Bash(gh *)" "Bash(spy *)" "Bash(${PLUGIN_ROOT}/scripts/slack-mcp.sh *)"
    'Bash(${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh *)'
    "Bash(mv *)" "Bash(${PLUGIN_ROOT}/scripts/notify.sh *)"
    Read Edit Write Glob Grep
    "mcp__slite__append-blocks" "mcp__slite__create-note" "mcp__atlassian__createJiraIssue"
  )
  "$CLAUDE_BIN" -p \
    --plugin-dir "$PLUGIN_ROOT" \
    --model sonnet \
    --permission-mode acceptEdits \
    --allowedTools "${allowed_tools[@]}" \
    --max-budget-usd "$budget" \
    "Run the engineer-agent execute command (commands/execute.md) for queue item '${item}' with decision '${decision}'. Read config from ${EA_CONFIG_FILE}. Be concise." \
    </dev/null >> "$LOG_FILE" 2>&1
}

# run_ticket_implementation — confined headless implementation of an approved `ticket`.
# A ticket is the one item type whose execution WRITES CODE in the target repo, so it
# cannot use the read/post allowlist above. Confinement (the "medium" posture) is three
# layers, and the two that define the sandbox are decided HERE in bash — before claude
# starts — so untrusted ticket text can influence code inside the sandbox but never the
# shape of the sandbox:
#   1. Path isolation — a throwaway git worktree checked out at the base branch, run as
#      cwd. The user's real checkout is never the target. Removed when done.
#   2. Narrow allowlist — build/test commands come from projects.<slug>.exec.allowed_commands,
#      each expanded to a Bash(<cmd> *) rule. DENY-BY-DEFAULT: no list => we refuse rather
#      than fall back to an unconfined session. Never Bash(*) / bypassPermissions.
#   3. (downstream) the output is a DRAFT PR the human reviews before merge.
# Honest limit: Claude Code Bash() rules are command-prefix matches, not cwd-scoped, so
# Bash(git *) also permits `git -C /elsewhere`. The worktree bounds the default target and
# the command set is curated; that prefix-vs-path gap is why this is "medium," not airtight.
#
# Returns 1 (refuses to start) when the project/path/allowlist can't be resolved — the item
# then stays in drafts/ and the caller's drafts/ check emits the ⚠️ Failed ack with the
# reason logged. Returns 0 once it has launched the run (success is judged by drafts/).
run_ticket_implementation() {
  local item="$1" budget="$2" draft="${AGENT_DIR}/queue/drafts/${item}"
  local project project_path base wt c

  project="$(grep -m1 '^project:' "$draft" 2>/dev/null | sed 's/^project:[[:space:]]*//; s/["'\'' ]//g')"
  if [ -z "$project" ] || [ "$project" = "_unrouted" ]; then
    log "WARN: ticket ${item} has no routable project ('${project:-}'); cannot implement headlessly"
    return 1
  fi
  project_path="$(yaml_project_scalar "$project" path)"
  if [ -z "$project_path" ] || [ ! -d "$project_path" ]; then
    log "WARN: project '${project}' path unresolved or missing ('${project_path:-}'); cannot implement ${item}"
    return 1
  fi

  # Narrow allowlist: expand each configured build command into a Bash(cmd *) rule.
  # Config is trusted, but validate each entry against a safe charset as defense in depth —
  # an allowlist rule is security-load-bearing, so a stray metacharacter must not widen it.
  local build_rules=()
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [[ "$c" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      build_rules+=( "Bash(${c} *)" )
    else
      log "WARN: ignoring unsafe exec.allowed_commands entry '${c}' for project '${project}'"
    fi
  done < <(yaml_project_list "$project" exec allowed_commands)

  if [ ${#build_rules[@]} -eq 0 ]; then
    log "WARN: project '${project}' has no valid exec.allowed_commands; refusing headless ticket implementation. Set projects.${project}.exec.allowed_commands in ${EA_CONFIG_FILE}."
    return 1
  fi

  # Path isolation: throwaway worktree at the base branch (detached HEAD).
  base="$(git -C "$project_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  base="${base:-main}"
  wt="${AGENT_DIR}/worktrees/${item%.md}-$(date +%s)"
  mkdir -p "$(dirname "$wt")"
  git -C "$project_path" fetch --quiet origin "$base" >>"$LOG_FILE" 2>&1 || true
  if ! git -C "$project_path" worktree add --detach "$wt" "origin/${base}" >>"$LOG_FILE" 2>&1; then
    if ! git -C "$project_path" worktree add --detach "$wt" "$base" >>"$LOG_FILE" 2>&1; then
      log "WARN: could not create worktree for ${item} at ${wt}; cannot implement"
      return 1
    fi
  fi
  log "implementing ticket ${item} in isolated worktree ${wt} (project ${project}, base ${base}); build tools: ${build_rules[*]}"

  # Confined tool set: file edits + git + the narrow build rules + gh (draft PR) + mv
  # (queue move) + notify (draft-pr FYI). No spy/slite/atlassian — a ticket implementation
  # posts nowhere but GitHub, and only a DRAFT PR at that.
  local allowed_tools=(
    Read Edit Write Glob Grep
    "Bash(git *)" "${build_rules[@]}"
    "Bash(gh *)" "Bash(mv *)" "Bash(${PLUGIN_ROOT}/scripts/notify.sh *)"
  )
  local prompt="Implement the engineer-agent ticket in queue item '${item}' (approved). \
The current working directory is an isolated git worktree of the target repo, checked out on a detached HEAD at the base branch. \
Read config from ${EA_CONFIG_FILE}. Follow skills/implement-ticket/SKILL.md: create the ticket branch HERE (stay inside this worktree — do not cd elsewhere), implement iteratively inline, self-review the branch diff and fix findings BEFORE opening any PR, then push the branch and open a DRAFT pull request. \
To finalize the queue item, WRITE the completed record to ${AGENT_DIR}/queue/completed/${item} (status: completed). You do NOT need to delete the drafts/ original — the listener reconciles that afterward; do not spend effort trying to remove it. \
Operate ONLY inside this working directory (plus writing that one completed/ queue file). Be concise."

  ( cd "$wt" && "$CLAUDE_BIN" -p \
      --plugin-dir "$PLUGIN_ROOT" \
      --model sonnet \
      --permission-mode acceptEdits \
      --allowedTools "${allowed_tools[@]}" \
      --max-budget-usd "$budget" \
      "$prompt" \
      </dev/null ) >> "$LOG_FILE" 2>&1

  # Best-effort QA test plan for the branch we just built — a SEPARATE confined run (its own
  # allowlist adds curl + a Jira read verb and drops the build rules; see run_qa_generation).
  # Run it HERE, before teardown, while the worktree is still checked out on the ticket branch
  # so `git diff <base>...HEAD` sees the changes. Gate on the implementation having actually
  # succeeded (completed/<item> present — the same side-effect signal the reconcile below uses):
  # no PR, no QA. It never fails the ticket — the ticket's ✅/⚠️ ack is decided by the caller
  # from the drafts/ check alone.
  if [ -e "${AGENT_DIR}/queue/completed/${item}" ]; then
    run_qa_generation "$item" "$project" "$base" "$wt" "$QA_BUDGET_USD" || true
  fi

  # Tear down the worktree regardless of outcome. The branch and any pushed commits / draft
  # PR persist in the repo; only the working copy is disposable.
  git -C "$project_path" worktree remove --force "$wt" >>"$LOG_FILE" 2>&1 || true
  git -C "$project_path" worktree prune >>"$LOG_FILE" 2>&1 || true

  # Reconcile the queue move on the privileged side of the sandbox boundary. The confined
  # run writes completed/<item> (the terminal record) but CANNOT delete the drafts/<item>
  # original: that path is outside the worktree cwd and the narrow allowlist grants it no
  # delete, so the run leaves a stub behind. The move succeeded in intent — finish it here
  # in plain bash so the caller's "drafts/ empty?" success check reflects the shipped PR
  # instead of false-flagging it. Guarded on completed/<item> existing, so we never remove a
  # drafts item that wasn't actually completed. (The draft PR is the real review gate; this
  # move grants no new capability.)
  if [ -e "${AGENT_DIR}/queue/completed/${item}" ] && [ -e "$draft" ]; then
    rm -f "$draft" && log "reconciled: removed stale drafts/${item} (completed/ copy present after implementation)"
  fi
  return 0
}

# run_qa_generation — best-effort QA test plan for a freshly-implemented ticket branch.
# Called by run_ticket_implementation after a successful draft PR, from INSIDE the still-live
# worktree (cwd), which is checked out on the ticket branch. Produces a `qa-test-plan` queue
# DRAFT for later interactive review — it posts nothing external (Slite publishing happens
# later, at review-queue/execute-item), so like the poll it only reads and drafts and needs no
# approval gate.
#
# This is deliberately a SEPARATE claude -p run from the implementation, with a different
# allowlist: QA needs curl (Pass 3 execution) + a Jira read verb but must NOT carry the
# build-command rules, and the implementation needs the build rules but must NOT gain network
# egress. Keeping them apart preserves the tight code-writing sandbox (untrusted issue text can
# steer code but never reach curl/MCP).
#
# Opt-in + non-fatal: skipped (return 0) when the project has no qa.base_url configured, and it
# never flips the ticket's ✅/⚠️ outcome — a QA hiccup must not fail a shipped PR.
run_qa_generation() {
  local item="$1" project="$2" base="$3" wt="$4" budget="$5"
  local base_url
  base_url="$(yaml_project_subscalar "$project" qa base_url)"
  if [ -z "$base_url" ]; then
    log "skipping QA generation for ${item}: project ${project} has no qa.base_url configured"
    return 0
  fi

  # QA-shaped allowlist: read + queue-draft-write. Adds curl (script execution) and the Jira
  # read verb (ticket AC for jira projects) vs. the implementation set; drops the build rules
  # (QA writes no code). gh is read-only in practice here (ticket / PR fetch).
  local allowed_tools=(
    Read Edit Write Glob Grep
    "Bash(git *)" "Bash(gh *)" "Bash(curl *)" "Bash(mv *)"
    "mcp__atlassian__getJiraIssue"
  )
  local prompt="Generate a QA test plan for the engineer-agent ticket in queue item '${item}' (just implemented). \
The current working directory is an isolated git worktree of the target repo, checked out on the ticket branch. \
Read config from ${EA_CONFIG_FILE}. Follow skills/generate-qa/SKILL.md via the engineer-agent qa command (commands/qa.md): \
project '${project}', base branch '${base}', deriving the ticket from the current branch / the queue item — gather the ticket AC, any PR, and the branch diff, create a qa-test-plan queue item, and draft it. \
Use 'mv' (not rm) for the incoming/ -> drafts/ queue move. \
Do NOT modify the already-completed ticket record at ${AGENT_DIR}/queue/completed/${item}. Operate only inside this working directory and the engineer-agent queue. Be concise."

  ( cd "$wt" && "$CLAUDE_BIN" -p \
      --plugin-dir "$PLUGIN_ROOT" \
      --model sonnet \
      --permission-mode acceptEdits \
      --allowedTools "${allowed_tools[@]}" \
      --max-budget-usd "$budget" \
      "$prompt" \
      </dev/null ) >> "$LOG_FILE" 2>&1

  # Judge success by a real side effect (never by claude -p's exit code): a new qa-test-plan
  # draft landing in the queue. FYI only — qa-test-plan is interactive-only for approval, so we
  # surface it as information, never as an actionable Approve/Reject push.
  if compgen -G "${AGENT_DIR}/queue/drafts/*qa-test-plan*" >/dev/null 2>&1; then
    log "QA test plan drafted for ${item} (project ${project})"
    push_ack normal "🧪 QA test plan drafted for ${item} — review in terminal"
  else
    log "WARN: QA generation for ${item} produced no qa-test-plan draft; skipping (ticket outcome unaffected)"
  fi
  return 0
}

command -v jq >/dev/null 2>&1 || { log "FATAL: jq is required but not found on PATH"; exit 1; }
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { log "FATAL: claude CLI not found (CLAUDE_BIN='${CLAUDE_BIN}')"; exit 1; }

resolve_ntfy_settings
if [ -z "$NTFY_COMMAND_TOPIC" ]; then
  log "FATAL: agent.notify.ntfy.command_topic is not configured; nothing to listen to"
  exit 1
fi

# First run starts from "now" so we never replay historical approvals.
[ -f "$SINCE_FILE" ] || date +%s > "$SINCE_FILE"
touch "$SEEN_FILE"

AUTH_ARGS=()
[ -n "$NTFY_AUTH_TOKEN" ] && AUTH_ARGS=(-H "Authorization: Bearer ${NTFY_AUTH_TOKEN}")

log "listening on ${NTFY_SERVER}/${NTFY_COMMAND_TOPIC} (plugin: ${PLUGIN_ROOT})"

handle_line() {
  local line="$1" evt id mtime msg decision item
  evt="$(jq -r '.event // empty' <<<"$line" 2>/dev/null)" || return 0
  [ "$evt" = "message" ] || return 0

  id="$(jq -r '.id // empty' <<<"$line")"
  mtime="$(jq -r '.time // empty' <<<"$line")"
  msg="$(jq -r '.message // empty' <<<"$line")"
  [ -n "$id" ] && [ -n "$msg" ] || return 0

  # Idempotency: skip messages we have already acted on.
  if grep -qF "\"${id}\"" "$SEEN_FILE"; then return 0; fi

  decision="${msg%%|*}"
  item="${msg#*|}"

  # Validation / hardening: strict decision + filename allowlist.
  case "$decision" in
    approve|reject) ;;
    *) log "ignoring message ${id}: bad decision '${decision}'"; echo "- \"${id}\"" >> "$SEEN_FILE"; return 0;;
  esac
  if ! [[ "$item" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log "ignoring message ${id}: item '${item}' fails filename allowlist"
    echo "- \"${id}\"" >> "$SEEN_FILE"; return 0
  fi

  log "executing: ${decision} ${item} (msg ${id})"
  echo "- \"${id}\"" >> "$SEEN_FILE"           # record before acting: at-most-once
  [ -n "$mtime" ] && echo "$mtime" > "$SINCE_FILE"
  push_ack low "📨 Received: ${decision} ${item} — working…"

  # Choose the execute spend cap by item type, read straight from the draft
  # frontmatter (the listener is plain bash, not subject to the claude allowlist).
  # Defensive: a missing file or unknown type falls back to the default, and only
  # `ticket` unlocks the higher cap — so untrusted frontmatter can at worst pick
  # between two fixed values, never inflate spend past TICKET_BUDGET_USD.
  local item_type budget
  item_type="$(grep -m1 '^type:' "${AGENT_DIR}/queue/drafts/${item}" 2>/dev/null \
    | sed 's/^type:[[:space:]]*//; s/["'\'' ]//g')"
  case "$item_type" in
    ticket) budget="$TICKET_BUDGET_USD" ;;
    *)      budget="$DEFAULT_BUDGET_USD" ;;
  esac
  log "execute budget for ${item} (type=${item_type:-unknown}): \$${budget}"

  # Dispatch by type. An approved `ticket` runs a CONFINED implementation — isolated
  # worktree + a narrow, config-driven build allowlist (see run_ticket_implementation),
  # because it is the one type that writes code. Every other type, and any reject, goes
  # through the shared execute-item path with the read/post allowlist that cannot run a
  # coding session (see run_generic_execute). Both judge success by the drafts/ check below.
  if [ "$decision" = "approve" ] && [ "$item_type" = "ticket" ]; then
    run_ticket_implementation "$item" "$budget" || true
  else
    run_generic_execute "$item" "$decision" "$budget"
  fi

  # Trust the filesystem, not claude -p's exit code (which is 0 whenever the CLI ran,
  # regardless of whether execute-item actually performed the action). execute-item moves
  # the file out of drafts/ on success and leaves it on failure, so its location is the
  # authoritative done/failed signal.
  if [ ! -e "${AGENT_DIR}/queue/drafts/${item}" ]; then
    log "done: ${decision} ${item}"
    push_ack normal "✅ Done: ${decision} ${item}"
  else
    log "WARN: ${decision} ${item} did not complete (still in drafts/); see log above. Re-run after fixing."
    push_ack urgent "⚠️ Failed: ${decision} ${item} — still queued, re-run"
  fi
}

# Reconnect loop with capped backoff. Dedup makes replays on reconnect harmless.
# Guarded so the script can be sourced by tests (which drive handle_line directly)
# without launching the stream.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  BACKOFF=2
  while true; do
    # Reload guard: if this script changed on disk since startup, exec the new copy.
    # The top of the reconnect loop is the only point guaranteed to be *between*
    # executes, so no in-flight approval is interrupted. The supervisor (systemd /
    # launchd / nohup) keeps tracking the re-exec'd process.
    if [ -s "$SELF" ] && [ "$(script_mtime "$SELF")" != "$SELF_MTIME" ]; then
      log "listener script changed on disk — re-executing to load new code"
      exec "$SELF"
    fi
    SINCE="$(cat "$SINCE_FILE" 2>/dev/null || echo now)"
    STREAM_URL="${NTFY_SERVER}/${NTFY_COMMAND_TOPIC}/json?since=${SINCE}"
    while IFS= read -r line; do
      [ -n "$line" ] && handle_line "$line"
      BACKOFF=2   # reset backoff once we are receiving data
    done < <(curl -sN "${AUTH_ARGS[@]}" "$STREAM_URL" 2>>"$LOG_FILE")

    log "stream closed; reconnecting in ${BACKOFF}s"
    sleep "$BACKOFF"
    BACKOFF=$(( BACKOFF < 60 ? BACKOFF * 2 : 60 ))
  done
fi
