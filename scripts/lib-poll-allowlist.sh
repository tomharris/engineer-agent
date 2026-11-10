#!/bin/bash
# lib-poll-allowlist.sh — the READ-ONLY --allowedTools set for an unattended drafting run.
#
# Shared by cron-poll.sh and jobs-draft.sh so the two cannot drift: an allowlist that differs by one
# rule is how every past silent poll outage started (see cron-poll.sh's gotcha list). The rationale
# for each rule lives in cron-poll.sh's comment block above its `claude -p` call.
#
# poll_build_allowlist — sets the globals SLACK_METHOD, SLACK_BIN and the array allowed_tools.
# Requires PLUGIN_ROOT, AGENT_DIR and lib-paths.sh.

poll_build_allowlist() {
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
}
