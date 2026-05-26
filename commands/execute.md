---
description: "Headlessly execute (approve/reject) a single queue item — used by the ntfy remote-approval listener"
model: sonnet
argument-hint: "<item-id> <approve|reject> [reason...]"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "mcp__claude_ai_Slack__slack_send_message", "mcp__slite__append-blocks", "mcp__slite__create-note"]
---

# Engineer Agent: Execute Item

Execute the approved or rejected action for a single queue item, non-interactively.
This is the headless entry point that `scripts/approval-listener.sh` invokes when you tap
**Approve** / **Reject** on an ntfy notification from your phone. It does the same work as
`/engineer-agent review-queue` — it just operates on exactly one item with the decision
already made, so it must never prompt.

## Arguments

`$ARGUMENTS` is: `<item-id> <approve|reject> [reason...]`
- `<item-id>` — a queue filename (e.g. `20260525-120000-pr-review-142.md`) or absolute path.
- `<approve|reject>` — the decision.
- `[reason...]` — optional free text; recorded as the rejection reason when rejecting.

## Steps

### 1. Parse Arguments

Split `$ARGUMENTS`. The first token is the item id, the second is the decision, the rest
(if any) is the reason. If the decision is not exactly `approve` or `reject`, stop and report
the usage line above. Do not ask the user anything — this command runs unattended.

### 2. Execute via the Shared Skill

Invoke the **execute-item** skill with the parsed `item`, `decision`, and `reason`. That
skill loads config, resolves the item against `~/.claude/engineer-agent/queue/drafts/`
(idempotently — an already-handled item is a no-op), performs the type-specific external
action, and moves the file to `completed/` or `rejected/`.

Honor its outcomes exactly:
- `already-handled` — the item was not in `drafts/`; report and stop (no notification).
- `qa-test-plan must be completed interactively …` — report and stop; send the FYI in step 3
  noting it needs the terminal.
- success — capture the one-line result string.
- failure — capture the error; the item stays in `drafts/` for retry.

### 3. Send a Confirmation Notification

Call `scripts/notify.sh` (resolve `${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh`) in `--fyi` mode
to push a confirmation back to your phone, so a remote tap gets an acknowledgement:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" --fyi \
  --title "engineer-agent: {approved|rejected|failed}" \
  --message "{the one-line result string}" \
  --priority {normal on success, urgent on failure} \
  --tags {white_check_mark on approve, x on reject, warning on failure} \
  [--source-url {source_url if available}]
```

Skip the notification only for the `already-handled` case (nothing happened).

### 4. Report

Print the result string to stdout (the listener logs it).
