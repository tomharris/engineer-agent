#!/bin/bash
# lib-confined-run.sh — the confined sandbox for a headless `ticket` implementation, shared by the
# approval listener (an Approve tap) and the jira implement-next scheduled job, so there is one
# definition of what a headless ticket run may touch.
#
# Caller provides: AGENT_DIR, LOG_FILE, CLAUDE_BIN, PLUGIN_ROOT, EA_CONFIG_FILE, QA_BUDGET_USD,
# and the functions log and push_ack. Requires lib-paths.sh (yaml_project_scalar & co.).

# shellcheck source=lib-queue.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-queue.sh"

# NO_MEMORY_RULE — appended to every headless prompt below. A queue item is a fact about ONE
# item; a memory is a belief applied to ALL future runs, so an unattended run must not write
# one. This is not hypothetical: on 2026-07-24 a failing cron poll wrote a memory asserting
# `gh` was permanently blocked ("Do not treat this as transient and just rerun"), and every
# later poll loaded it and re-confirmed the wrong conclusion instead of retesting — one flake
# became five identical failures (fixed in cron-poll.sh; see CLAUDE.md's headless-run notes).
# The listener is exposed to the SAME pool: memory is keyed by CWD, and this service runs from
# $HOME, so run_generic_execute shares ~/.claude/projects/-home-tom/memory/ with the poll and
# would have loaded that same poisoned file. (The ticket/QA runs cd into a per-run worktree, so
# they get a throwaway namespace — isolated only as a side effect of the path sandbox. Applied
# uniformly here so the guarantee does not depend on that accident.)
NO_MEMORY_RULE="MEMORY: do NOT create or update memory files, and do NOT treat any pre-existing memory as evidence about this run — a wrong conclusion recorded once would otherwise be re-read and re-confirmed by every later run instead of being retested. If a tool or command appears unavailable, establish that fresh THIS run."

# git/gh verbs for confined runs, enumerated rather than `Bash(git *)` / `Bash(gh *)`. The broad
# prefixes also grant `git -C /elsewhere`, `git -c alias.x='!cmd' x` (arbitrary exec), `gh api -X
# POST`, `gh pr merge` and `gh secret`. A rule is a command PREFIX, so anything may follow it:
#   - no raw `git push`: it takes any refspec (`HEAD:main --force`, `--delete`). Pushes go through
#     confined-push.sh, which pushes one prefixed branch to the same name, never forced.
#   - no `git branch`, `git stash`, plain `git checkout`/`git switch`: a linked worktree shares refs
#     with the user's own checkout, so `branch -f`, `stash clear` or `checkout -B` reach it. New
#     branches only, via `checkout -b` / `switch -c`.
# Residual, accepted: `git diff/log/show --output=<path>` writes a file anywhere,
# and repo-tracked hooks run on `git commit` — the same class as the build commands, which run
# files the model can edit. That is why an UNATTENDED run additionally requires trusted authors
# (job-jira-implement-next.sh), not just these rules.
CONFINED_GIT_READ_RULES=(
  "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)"
  "Bash(git rev-parse:*)" "Bash(git symbolic-ref:*)" "Bash(git show-ref:*)" "Bash(git ls-files:*)"
  "Bash(git merge-base:*)"
)
CONFINED_GIT_WRITE_RULES=(
  "${CONFINED_GIT_READ_RULES[@]}"
  "Bash(git checkout -b:*)" "Bash(git switch -c:*)" "Bash(git add:*)" "Bash(git commit:*)"
  "Bash(git restore:*)" "Bash(git rm:*)" "Bash(git mv:*)"
  "Bash(git ls-remote --exit-code --heads origin:*)"
  "Bash(${PLUGIN_ROOT}/scripts/confined-push.sh:*)"
)
CONFINED_GH_READ_RULES=(
  "Bash(gh pr view:*)" "Bash(gh pr list:*)" "Bash(gh issue view:*)"
  "Bash(gh auth status:*)" "Bash(gh --version:*)"
)

# In-flight markers: one file per running implementation, state/implement-inflight/<item>, holding
# "<pid>\t<project>". Written by run_ticket_implementation whichever entry point called it, so the
# implement-next job's max_in_flight guard also counts an Approve tap's run on the same project.
# A marker whose pid is dead is stale (crashed run) and does not count.
INFLIGHT_DIR="${EA_AGENT_DIR}/state/implement-inflight"
inflight_begin() { mkdir -p "$INFLIGHT_DIR"; printf '%s\t%s\n' "$BASHPID" "$2" > "${INFLIGHT_DIR}/$1"; }
inflight_end()   { rm -f "${INFLIGHT_DIR}/$1"; }
# inflight_count <project> — live implementations for this project; reclaims stale markers.
inflight_count() {
  local f pid proj n=0
  for f in "$INFLIGHT_DIR"/*; do
    [ -f "$f" ] || continue
    IFS="	" read -r pid proj < "$f"
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$f"; continue; fi
    [ "$proj" = "$1" ] && n=$((n+1))
  done
  echo "$n"
}

# project_build_rules <project> — sets BUILD_RULES to one Bash(<cmd> *) rule per
# exec.allowed_commands entry. Config is trusted, but each entry is checked against a safe charset
# as defense in depth: an allowlist rule is security-load-bearing, so a stray metacharacter must
# not widen it.
project_build_rules() {
  local c
  BUILD_RULES=()
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [[ "$c" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      BUILD_RULES+=( "Bash(${c} *)" )
    else
      log "WARN: ignoring unsafe exec.allowed_commands entry '${c}' for project '${1}'"
    fi
  done < <(yaml_project_list "$1" exec allowed_commands)
}

# run_ticket_implementation — the confined SANDBOX for a headless approved `ticket`.
#
# This function builds the sandbox; it does NOT decide what approving a ticket means. That
# decision lives in skills/execute-item/SKILL.md, the single source of truth every entry point
# shares, which probes for the ticket branch and delegates to implement-ticket when there is
# none. Everything security-load-bearing (worktree, build allowlist, budget, turn-notify env)
# is still resolved HERE, in plain bash, before claude starts.
# Throwaway worktree at the base branch, shared by the implementation and investigation paths.
# Kept as ONE function for the reason reconcile_queue_move is: two copies of this setup already
# drifted once, and only one of them would have learned about a stale base.
#
# Sets WT_PATH / WT_BASE / WT_BASE_SHA / WT_STALE; returns 1 if no worktree could be created.
#
# A failed `git fetch` is deliberately NOT fatal: github being briefly unreachable must not
# strand the item in drafts/ and fire a ⚠️ Failed push (which invites a retry) for a transient
# blip. But it must not be silent either. Before this, the failure was swallowed by `|| true`
# and the run proceeded from whatever the LOCAL origin/<base> ref happened to say — observed
# detaching at a days-old release commit while the log still reported a reassuring "base main".
# So the outcome is recorded and every site that reports the base names the sha and the
# staleness (see wt_base_desc).
create_run_worktree() {
  local project_path="$1" item="$2"
  WT_STALE=0
  WT_BASE="$(git -C "$project_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  WT_BASE="${WT_BASE:-main}"
  WT_PATH="${AGENT_DIR}/worktrees/${item%.md}-$(date +%s)"
  mkdir -p "$(dirname "$WT_PATH")"
  if ! git -C "$project_path" fetch --quiet origin "$WT_BASE" >>"$LOG_FILE" 2>&1; then
    WT_STALE=1
    log "WARN: git fetch origin ${WT_BASE} failed for ${item} — proceeding from the LOCAL origin/${WT_BASE} ref, which may be behind"
  fi
  if ! git -C "$project_path" worktree add --detach "$WT_PATH" "origin/${WT_BASE}" >>"$LOG_FILE" 2>&1; then
    if ! git -C "$project_path" worktree add --detach "$WT_PATH" "$WT_BASE" >>"$LOG_FILE" 2>&1; then
      return 1
    fi
  fi
  WT_BASE_SHA="$(git -C "$WT_PATH" rev-parse --short HEAD 2>/dev/null)"
  WT_BASE_SHA="${WT_BASE_SHA:-unknown}"
  return 0
}

# How the base is named in every log line: the branch, the commit actually checked out, and
# whether that commit is trustworthy. "base main" alone is what made the stale-base failure
# invisible for two runs.
wt_base_desc() {
  if [ "${WT_STALE:-0}" = "1" ]; then
    printf '%s @ %s (STALE: fetch failed, local ref may be behind)' "$WT_BASE" "$WT_BASE_SHA"
  else
    printf '%s @ %s' "$WT_BASE" "$WT_BASE_SHA"
  fi
}

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
# Honest limit: this is "medium," not airtight. Bash() rules are prefix matches, not
# cwd-scoped, and the build commands run files the model can edit, so ticket text that steers
# the model can run code as the user. git/gh are enumerated (CONFINED_GIT_*_RULES above); the
# remaining gap is why an unattended run needs trusted authors.
#
# Returns 1 (refuses to start) when the project/path/allowlist can't be resolved — the item
# then stays in drafts/ and the caller's drafts/ check emits the ⚠️ Failed ack with the
# reason logged. Returns 0 once it has launched the run (success is judged by drafts/).
# UNATTENDED (3rd arg 1, the implement-next job with no Approve tap): the trust gate vouched only
# for the queue item's text, so this run may read nothing else that strangers write — no `gh
# issue/pr view` — and gets no QA follow-on, whose allowlist reads Jira live and holds curl.
run_ticket_implementation() {
  local item="$1" budget="$2" unattended="${3:-0}" draft="${AGENT_DIR}/queue/drafts/${item}"
  local project project_path base wt

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

  local build_rules=()
  project_build_rules "$project"
  [ ${#BUILD_RULES[@]} -eq 0 ] || build_rules=( "${BUILD_RULES[@]}" )

  if [ ${#build_rules[@]} -eq 0 ]; then
    log "WARN: project '${project}' has no valid exec.allowed_commands; refusing headless ticket implementation. Set projects.${project}.exec.allowed_commands in ${EA_CONFIG_FILE}."
    return 1
  fi

  # Path isolation: throwaway worktree at the base branch (detached HEAD).
  if ! create_run_worktree "$project_path" "$item"; then
    log "WARN: could not create worktree for ${item} at ${WT_PATH}; cannot implement"
    return 1
  fi
  base="$WT_BASE"; wt="$WT_PATH"
  log "implementing ticket ${item} in isolated worktree ${wt} (project ${project}, base $(wt_base_desc)); build tools: ${build_rules[*]}"
  inflight_begin "$item" "$project"

  # Confined tool set: file edits + git + the narrow build rules + gh (draft PR) + mv
  # (queue move) + notify (draft-pr FYI). No spy/slite/atlassian — a ticket implementation
  # posts nowhere but GitHub, and only a DRAFT PR at that.
  local gh_rules=( "${CONFINED_GH_READ_RULES[@]}" )
  [ "$unattended" = 1 ] && gh_rules=( "Bash(gh auth status:*)" "Bash(gh --version:*)" )
  local allowed_tools=(
    Read Edit Write Glob Grep
    "${CONFINED_GIT_WRITE_RULES[@]}" "${build_rules[@]}"
    "${gh_rules[@]}" "Bash(gh pr create:*)" "Bash(echo:*)"
    "Bash(mv *)" "Bash(${PLUGIN_ROOT}/scripts/notify.sh *)"
  )
  # Dispatch goes through execute-item, exactly like every other item type. This function's job
  # is the SANDBOX (worktree, build allowlist, budget, turn-notify env, QA follow-on, teardown,
  # reconcile) — all of it decided above in plain bash, before claude starts. What approving a
  # ticket *means* is execute-item's job: it probes for the branch and either finishes a pushed
  # one or delegates the coding session to implement-ticket. Keeping the two separate is what
  # stopped the interactive path from silently having no implementation step at all.
  #
  # The prompt names the SKILL FILE rather than invoking the Skill tool, and rather than going
  # through commands/execute.md: `Skill` is deliberately absent from every confined allowlist in
  # this repo (see CLAUDE.md on cron-poll.sh), and commands/execute.md would send a second
  # notify.sh FYI on top of the listener's own outcome ack.
  local prompt="Execute the approved engineer-agent queue item '${item}' (decision: approve). \
Read ${PLUGIN_ROOT}/skills/execute-item/SKILL.md and follow it with item='${item}' and decision='approve'. Its ticket case probes for the ticket branch and, when the branch does not exist yet, implements the ticket by following ${PLUGIN_ROOT}/skills/implement-ticket/SKILL.md before opening a DRAFT pull request. \
The current working directory is an isolated git worktree of the target repo, checked out on a detached HEAD at the base branch. Create the ticket branch HERE and stay inside this worktree — do not cd elsewhere. Self-review the branch diff and fix findings BEFORE opening any PR. \
PUSH ONLY with: ${PLUGIN_ROOT}/scripts/confined-push.sh --no-verify (from the ticket branch). Plain git push is not permitted in this run and will be denied; this replaces the push commands in the skill files. \
Read config from ${EA_CONFIG_FILE}. \
To finalize the queue item, WRITE the completed record to ${AGENT_DIR}/queue/completed/${item} (status: completed). You do NOT need to delete the drafts/ original — the listener reconciles that afterward; do not spend effort trying to remove it. \
Operate ONLY inside this working directory (plus writing that one completed/ queue file). \
${NO_MEMORY_RULE} Be concise."

  # Turn-completion push (opt-in: agent.notify.turn_completions). hooks/hooks.json fires
  # scripts/turn-notify-hook.sh at the end of every turn, but ONLY when armed — and this run is
  # armed by environment, not by a marker file: nothing to correlate, nothing orphaned if the run
  # dies. Resolved HERE, in plain bash, on the privileged side of the sandbox boundary — the same
  # rule as the worktree and the allowlist: untrusted ticket text may influence the code produced
  # inside the sandbox, never whether or what we notify. ${item} is already validated
  # ^[A-Za-z0-9._-]+$ by handle_line.
  #
  # Passed as an INLINE `env` on this ONE process, so it reaches this run's hooks and nothing
  # else — notably NOT run_qa_generation's separate run below, which stays silent.
  #
  # NOTE: hook commands are NOT subject to --allowedTools. That grants nothing new here (the
  # allowlist above already carries Bash(notify.sh *)), but see CLAUDE.md — the general rule is
  # that a plugin hook is a capability outside every allowlist in this repo.
  local turn_notify=0
  case "${EA_TURN_NOTIFY_ENABLED:-$(yaml_agent_notify turn_completions)}" in
    true|yes|1|on) turn_notify=1 ;;
  esac

  # Always pass 0|1 rather than conditionally building an array: `set -u` plus an empty-array
  # expansion is an unbound-variable error on bash 3.2, which macOS still ships.
  ( cd "$wt" && env "EA_TURN_NOTIFY=${turn_notify}" "EA_TURN_NOTIFY_LABEL=${item%.md}" \
      "$CLAUDE_BIN" -p \
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
  if [ "$unattended" = 1 ]; then
    log "skipping QA generation for ${item}: unattended run"
  elif [ -e "${AGENT_DIR}/queue/completed/${item}" ]; then
    run_qa_generation "$item" "$project" "$base" "$wt" "$QA_BUDGET_USD" || true
  fi

  # The ticket branch, read by bash rather than reported by the model, for pr-pipeline.sh.
  [ -e "${AGENT_DIR}/queue/completed/${item}" ] && record_ticket_branch "$item" "$wt"

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
  reconcile_queue_move "$item"
  inflight_end "$item"
  return 0
}

# record_ticket_branch <item> <worktree> — state/pr-pipeline/<item>/branch, only for a branch under
# agent.branch_prefix (the same shape confined-push.sh would push).
PR_PIPELINE_DIR="${EA_AGENT_DIR}/state/pr-pipeline"
record_ticket_branch() {
  local br prefix d="${PR_PIPELINE_DIR}/${1%.md}"
  br="$(git -C "$2" symbolic-ref --quiet --short HEAD 2>/dev/null)" || { log "WARN: ${1} finished on a detached HEAD; no branch recorded"; return 0; }
  prefix="$("${PLUGIN_ROOT}/scripts/ea-config.sh" dump 2>/dev/null | awk -F= '$1=="agent.branch_prefix" {print $2; exit}')"
  case "$br" in "${prefix:-engineer-agent}/"?*) ;; *) log "WARN: ${1} branch '${br}' is not under the branch prefix; not recorded"; return 0 ;; esac
  [[ "$br" =~ ^[A-Za-z0-9._/-]+$ ]] || return 0
  mkdir -p "$d" && printf '%s\n' "$br" > "${d}/branch"
}

# reconcile_queue_move — finish a confined run's queue move on the privileged side of the sandbox
# boundary. A confined run writes completed/<item> but CANNOT delete the drafts/<item> original:
# that path is outside the worktree cwd and the narrow allowlist grants no delete, so the run
# leaves a stub behind. Guarded on completed/<item> existing, so we never remove a drafts item
# that wasn't actually completed. Shared by run_ticket_implementation and
# run_ticket_investigation so the two cannot drift (without it, a shipped result false-flags as
# "⚠️ Failed" because the drafts/ copy lingers).
reconcile_queue_move() {
  local item="$1" draft="${AGENT_DIR}/queue/drafts/${1}"
  if [ -e "${AGENT_DIR}/queue/completed/${item}" ] && [ -e "$draft" ]; then
    rm -f "$draft" && log "reconciled: removed stale drafts/${item} (completed/ copy present)"
  fi
}

# reconcile_incoming_draft_move — the incoming/ -> drafts/ half of the same problem.
# run_qa_generation's confined run creates its queue item in incoming/ and must then move it to
# drafts/, but drafts/ is the ONLY dir the approval gate reads, and the move is a delete outside
# the worktree cwd — which the sandbox refuses regardless of the `Bash(mv *)` rule. So the run
# writes the drafts/ copy and the incoming/ original survives: a live duplicate of the exact same
# (type, source_id), reported by queue-dedup-check.sh on every poll from then on.
#
# Same resolution as reconcile_queue_move: the run states intent by writing the destination, and
# the listener finishes the move here in plain bash. Guarded on the drafts/ counterpart existing
# under the identical basename — same timestamp, type and id means it IS the same item mid-move,
# never a different one. Scoped by glob to the type this run produces, so an unrelated item parked
# in incoming/ is left for poll_resume_candidates to heal.
reconcile_incoming_draft_move() {
  local pattern="$1" f base
  for f in "${AGENT_DIR}/queue/incoming/"$pattern; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    if [ -e "${AGENT_DIR}/queue/drafts/${base}" ]; then
      rm -f "$f" && log "reconciled: removed stale incoming/${base} (drafts/ copy present)"
    fi
  done
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
    "${CONFINED_GIT_READ_RULES[@]}" "${CONFINED_GH_READ_RULES[@]}" "Bash(echo:*)"
    "Bash(curl *)" "Bash(mv *)"
    "mcp__atlassian__getJiraIssue"
  )
  local prompt="Generate a QA test plan for the engineer-agent ticket in queue item '${item}' (just implemented). \
The current working directory is an isolated git worktree of the target repo, checked out on the ticket branch. \
Read config from ${EA_CONFIG_FILE}. Follow skills/generate-qa/SKILL.md via the engineer-agent qa command (commands/qa.md): \
project '${project}', base branch '${base}', deriving the ticket from the current branch / the queue item — gather the ticket AC, any PR, and the branch diff, create a qa-test-plan queue item, and draft it. \
Leave the drafted item in ${AGENT_DIR}/queue/drafts/ (write it there directly); you do NOT need to delete the incoming/ original — the listener reconciles that afterward; do not spend effort trying to remove it. \
Do NOT modify the already-completed ticket record at ${AGENT_DIR}/queue/completed/${item}. Operate only inside this working directory and the engineer-agent queue. \
${NO_MEMORY_RULE} Be concise."

  # Success marker, stamped immediately before the run. The side-effect check below asks "did
  # THIS run touch a QA draft", not "does the queue contain one" — drafts/ accumulates
  # qa-test-plan items from every previous ticket, so a bare glob reports success whenever any
  # older plan is still awaiting review, which is the steady state. `find -newer` also catches
  # the update-in-place case (the run reconciling an existing draft for this source_id rather
  # than minting a new file), which a before/after filename snapshot would miss.
  local marker="${AGENT_DIR}/state/.qa-run-marker.$$"
  mkdir -p "${AGENT_DIR}/state"
  : > "$marker"

  ( cd "$wt" && "$CLAUDE_BIN" -p \
      --plugin-dir "$PLUGIN_ROOT" \
      --model sonnet \
      --permission-mode acceptEdits \
      --allowedTools "${allowed_tools[@]}" \
      --max-budget-usd "$budget" \
      "$prompt" \
      </dev/null ) >> "$LOG_FILE" 2>&1

  # Finish the incoming/ -> drafts/ move the confined run could not complete (see above).
  reconcile_incoming_draft_move '*qa-test-plan*.md'

  local fresh_qa
  fresh_qa="$(find "${AGENT_DIR}/queue/drafts" -maxdepth 1 -name '*qa-test-plan*.md' -newer "$marker" -print 2>/dev/null | head -n 1)"
  rm -f "$marker"

  # Judge success by a real side effect (never by claude -p's exit code): a qa-test-plan draft
  # this run actually wrote. FYI only — qa-test-plan is interactive-only for approval, so we
  # surface it as information, never as an actionable Approve/Reject push.
  if [ -n "$fresh_qa" ]; then
    log "QA test plan drafted for ${item} (project ${project})"
    push_ack normal "🧪 QA test plan drafted for ${item} — review in terminal"
  else
    log "WARN: QA generation for ${item} produced no qa-test-plan draft; skipping (ticket outcome unaffected)"
  fi
  return 0
}

# --- Autopilot (jira / github-issues implement-next) ------------------------------------------
# state/autopilot-items.tsv: "<item>\t<job key>\t<rule>\t<ticket key>[\t<tracker>]", one row per
# item a job wrote; tracker is `github` for github-issues jobs, absent (jira) for rows written
# before it existed. It is the ONLY provenance the listener honors: queue frontmatter can be written
# by a drafting model that read untrusted text, so `autopilot: true` there never triggers a claim.
AUTOPILOT_LEDGER="${EA_AGENT_DIR}/state/autopilot-items.tsv"
autopilot_record() { mkdir -p "$(dirname "$AUTOPILOT_LEDGER")"; printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-jira}" >> "$AUTOPILOT_LEDGER"; }
# autopilot_lookup <item> — prints "<job>\t<rule>\t<key>\t<tracker>"; rc 1 if not an autopilot pick.
autopilot_lookup() {
  [ -f "$AUTOPILOT_LEDGER" ] || return 1
  awk -F'\t' -v i="$1" '$1==i {print $2 "\t" $3 "\t" $4 "\t" ($5 == "" ? "jira" : $5); f=1; exit} END {exit !f}' "$AUTOPILOT_LEDGER"
}
# autopilot_pending <job> — items this job picked that still sit in drafts/ awaiting a human.
autopilot_pending() {
  [ -f "$AUTOPILOT_LEDGER" ] || return 0
  awk -F'\t' -v j="$1" '$2==j {print $1}' "$AUTOPILOT_LEDGER" | while IFS= read -r i; do
    [ -e "${AGENT_DIR}/queue/drafts/${i}" ] && printf '%s\n' "$i"
  done
}

# _autopilot_claim_cmd <claim|release> <item> [--approved] — the run id is the item name: one claim
# per item, and the listener and the job agree on it without sharing state. The claim script is
# chosen by the ledger's tracker column, never by the item.
_autopilot_claim_cmd() {
  local mode="$1" item="$2" row job rule key tracker script
  row="$(autopilot_lookup "$item")" || return 2
  IFS="	" read -r job rule key tracker <<< "$row"
  case "$tracker" in
    github) script=gh-claim.sh ;;
    jira)   script=jira-claim.sh ;;
    *)      return 2 ;;
  esac
  shift 2
  bash "${PLUGIN_ROOT}/scripts/${script}" "$mode" --job "$job" --rule "$rule" --key "$key" \
    --item "${AGENT_DIR}/queue/drafts/${item}" --run-id "${item%.md}" "$@" >>"$LOG_FILE" 2>&1
}
autopilot_claim()   { _autopilot_claim_cmd claim "$@"; }
autopilot_release() { _autopilot_claim_cmd release "$1"; }

# autopilot_implement <item> <budget> [--approved] — claim, implement, roll back on failure.
# rc 0 implemented, 3 someone else claimed it first (item moved to rejected/), 1 failed (claim
# rolled back, item left in drafts/).
autopilot_implement() {
  local item="$1" budget="$2" rc draft="${AGENT_DIR}/queue/drafts/$1" unattended=1
  shift 2
  [ "${1:-}" = --approved ] && unattended=0
  autopilot_claim "$item" "$@"; rc=$?
  case "$rc" in
    0) ;;
    3) fm_set "$draft" rejected_reason "autopilot: ticket was claimed by someone else first"
       fm_set "$draft" status rejected
       mv "$draft" "${AGENT_DIR}/queue/rejected/${item}"
       log "autopilot: ${item} lost the claim race; moved to rejected/"
       push_ack low "ℹ️ Autopilot skipped ${item}: someone else took the ticket first"
       return 3 ;;
    *) log "autopilot: claim failed for ${item} (exit ${rc}); rolling back"
       autopilot_release "$item"
       return 1 ;;
  esac
  run_ticket_implementation "$item" "$budget" "$unattended"
  if [ -e "$draft" ]; then
    log "autopilot: ${item} did not complete; releasing the claim"
    autopilot_release "$item"
    return 1
  fi
  pr_pipeline_launch "$item"
  return 0
}

# pr_pipeline_launch <item> — start scripts/pr-pipeline.sh detached when the item's job (from the
# ledger) has an after_pr block. Detached so the CI wait is bounded by after_pr.max_runtime, not
# held under the job's own watchdog, whose TERM trap would release a claim whose PR already exists.
pr_pipeline_launch() {
  local row job slug idx EA_JOBS_CFG=""   # fresh config: the listener is long-lived
  row="$(autopilot_lookup "$1")" || return 0
  job="$(printf '%s' "$row" | cut -f1)"
  command -v jobs_enumerate >/dev/null 2>&1 || . "${PLUGIN_ROOT}/scripts/lib-jobs.sh"
  jobs_cfg_load
  IFS='|' read -r slug idx _ <<< "$(jobs_enumerate | awk -F'|' -v k="$job" '($1 "." $3) == k { print; exit }')"
  [ -n "${slug:-}" ] && [ -n "$(_ar_children "projects.${slug}.job.${idx}.after_pr")" ] || return 0
  log "autopilot: starting pr-pipeline for ${1}"
  if [ "${EA_PR_PIPELINE_FOREGROUND:-0}" = 1 ]; then
    bash "${EA_PR_PIPELINE_BIN:-${PLUGIN_ROOT}/scripts/pr-pipeline.sh}" --item "$1" </dev/null >>"$LOG_FILE" 2>&1
  else
    nohup bash "${EA_PR_PIPELINE_BIN:-${PLUGIN_ROOT}/scripts/pr-pipeline.sh}" --item "$1" </dev/null >>"$LOG_FILE" 2>&1 &
  fi
  return 0
}
