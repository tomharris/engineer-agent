---
description: "Review and approve/reject queued engineer-agent work items"
model: sonnet
argument-hint: "[filter: pr|slack|ticket|ticket-plan|doc|spec|design|refinement|gap|qa|audit|codify] [--all] [--project <slug>]"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Agent", "AskUserQuestion", "mcp__slite__append-blocks", "mcp__slite__create-note", "mcp__slite__list-channels"]
---

# Engineer Agent: Review Queue

Review pending draft items and approve, edit, or reject them.

## Arguments

- `$ARGUMENTS` may contain a filter: `pr`, `slack`, `ticket`, `ticket-plan`, `doc`, `spec`, `design`, `refinement`, `gap`, `qa`, `audit`, or `codify` to show only that type. `audit` matches `code-audit-finding`; `codify` matches `codify-candidate`.
- `$ARGUMENTS` may contain `--all` to show all items including completed/rejected
- `$ARGUMENTS` may contain `--project <slug>` to show only items for a specific project

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop. Extract `agent.branch_prefix` (required — read the literal string from the yaml; do not assume a default. If missing or empty, stop and tell the user to set `agent.branch_prefix`). When substituting `{branch_prefix}` in the `gh pr create --head` arguments below, use this exact value verbatim.

### 2. List Draft and Unrouted Items

Use Glob to find all `.md` files in `~/.claude/engineer-agent/queue/drafts/` (excluding `.gitkeep`).

Also scan `~/.claude/engineer-agent/queue/incoming/` for items with `project: _unrouted` in their frontmatter. These are tickets that could not be automatically routed to a project and need manual assignment.

If a filter was provided in `$ARGUMENTS`, only show items matching that type in their YAML frontmatter `type` field.

If `--project <slug>` was provided, only show items whose `project` frontmatter field matches the slug. Note: `_unrouted` items are always shown regardless of project filter (since they have no project yet).

If no items found, report: "No items to review. Run `/engineer-agent poll` to check for new work."

### 3. Display Summary Table

Read each file's YAML frontmatter and display a numbered summary:

```
# Engineer Agent Queue (N items)

| #  | Project | Type       | Source             | Title                        | Priority | Age     |
|----|---------|------------|--------------------|------------------------------|----------|---------|
| 1  | ⚠ ---   | Ticket (unrouted) | ENG-789       | Refactor auth middleware     | normal   | 1h ago  |
| 2  | my-api  | PR Review  | org/repo#142       | Add caching layer to auth... | normal   | 2h ago  |
| 3  | my-app  | Slack Q&A  | #engineering       | How does auth cache work?    | normal   | 45m ago |
```

Sort by: unrouted items first, then priority (urgent first), then by created_at (oldest first). Unrouted items display with `⚠ ---` in the Project column.

### 4. User Selects Item

Ask the user which item to review (by number). Also offer "approve all" if all items are low-risk (no urgent priority, no ticket implementations).

### 5. Handle Unrouted Items (if applicable)

If the selected item has `project: _unrouted` in its frontmatter, run the assignment flow before proceeding:

1. Show the ticket context: description, Jira components (`jira_components` frontmatter), Jira labels (`jira_labels` frontmatter), and source URL
2. Check `matched_projects` in frontmatter:
   - If non-empty (multi-match): "This ticket matched multiple projects: {list}. Which should it be assigned to?" — present the matched projects as options
   - If empty (no match): "No routing rules matched this ticket. Which project should it be assigned to?" — list all projects in config where `tracker` resolves to `jira`
3. User selects a project slug
4. Update the queue item frontmatter:
   - Set `project` to the selected slug
   - Remove the `matched_projects` field
5. Generate a draft for the ticket:
   - Read `projects.<selected_slug>` config for repo info
   - Create the `## Draft Response` section with implementation plan (same as poll-jira step 6)
   - Update `status` to `drafted`
   - Move the file from `incoming/` to `drafts/`
6. Continue to Step 5a (Show Full Draft) with the now-drafted item

### 5a. Show Full Draft

Read the selected file completely and display:
- The `project` field
- The `## Context` section with source details
- The `## Draft Response` section with the full proposed content
- The source URL for reference

### 6. User Chooses Action

Ask the user what to do:

**Approve** — Execute the action via the shared **execute-item** skill. That skill is the
single source of truth for what each item type does on approval — and it is the exact same
code path the remote ntfy approval listener uses (`/engineer-agent execute`), so the terminal
and phone approval routes never drift.

Invoke the `execute-item` skill with `item` = the selected file and `decision` = `approve`.
It performs the type-specific external action (submit the PR review, post the Slack reply,
create the draft PR, create the design doc, create issues from a ticket-plan, acknowledge a
gap-audit, etc.), sets `status: completed`, and moves the file to
`~/.claude/engineer-agent/queue/completed/`. Display the one-line result it returns. If it
reports a failure, the item stays in `drafts/` — surface the error and let the user retry.

**Exception — `qa-test-plan`:** this type is interactive and is NOT delegated (execute-item
refuses it). Run its three-phase flow here:

  **Phase 1 — Run automated tests:**
  1. Extract the test script (the bash code block under `### Test Script`) from the `## Draft Response`
  2. Create a temporary directory and save the script as `qa-test.sh`
  3. Run the script via Bash: `bash qa-test.sh`
  4. Display the output to the user (pass/fail for each test, final summary)
  5. If any tests fail, use AskUserQuestion: "Some automated tests failed. What would you like to do?" Options: "Continue to manual checklist", "Re-run tests", "Reject this QA plan"
  6. If the user chooses to re-run, repeat from step 3
  7. If the user chooses to reject, follow the **Reject** flow below

  **Phase 2 — Manual checklist:**
  1. Display the `### Manual Checklist` section from the draft
  2. Display the `### REPL/Console Tests` section if present, and ask the user to run those manually
  3. Use AskUserQuestion: "Have you completed the manual checklist and REPL/console tests?" Options: "Yes, all checks passed", "Yes, but some items failed", "Not yet — I'll come back later"
  4. If "not yet", leave the queue item in `drafts/` and print: "QA plan remains in queue. Run `/engineer-agent review-queue qa` when ready to complete."
  5. If "some items failed", ask the user to describe which items failed. Record this in the results.

  **Phase 3 — Archive:**
  1. Create directory `~/.claude/engineer-agent/qa-plans/{branch}-{YYYYMMDD-HHmmss}/`
  2. Save `qa-test.sh` — the test script extracted in Phase 1
  3. Save `test-plan.md` — the full `## Draft Response` content including manual checklist
  4. Save `results.md` — containing:
     - Automated test output (stdout from the script run)
     - Pass/fail counts
     - Manual checklist completion status
     - Any notes about failed manual items
     - Timestamp of completion
  5. Print: "QA complete. Plan archived to `~/.claude/engineer-agent/qa-plans/{branch}-{timestamp}/`"

After the three QA phases complete, update the file's frontmatter `status` to `completed` and move it from `~/.claude/engineer-agent/queue/drafts/` to `~/.claude/engineer-agent/queue/completed/` (write to new location, delete from old). (For all other types, execute-item has already done this.)

  **Phase 3b — Document the completed plan (optional):**

  This runs last — only after the plan is fully completed (frontmatter `status: completed`,
  moved to `completed/`) and locally archived above. It is best-effort: a failure here is
  reported but never un-completes the plan.

  1. Read `projects.<project>.qa.document_to` from `~/.claude/engineer-agent/engineer.yaml`.
     - Empty or absent → skip silently (feature disabled).
     - `slite` → continue.
     - Any other value → print `unrecognized qa.document_to value '{value}'; skipping QA documentation` and skip.
  2. Resolve the Slite parent id:
     - If `projects.<project>.qa.document_parent` is set, use it.
     - If empty/absent, call `mcp__slite__list-channels` and select the user's personal
       channel — the channel whose id is prefixed `user-`. Use that id as the parent.
       If no personal channel can be resolved, print `could not resolve a private Slite
       channel; skipping QA documentation` and skip.
  3. Compose the note content (a complete record), in order:
     - A header: ticket key + `source_url`, PR URL (`pr_url` or "None"), `branch`, `base`,
       base URL, and the completion timestamp.
     - The full test plan — the `test-plan.md` content saved in Phase 3 (manual checklist,
       REPL/console tests, coverage summary).
     - The generated `qa-test.sh` script inlined in a fenced ```bash code block.
     - The execution results — the `results.md` content saved in Phase 3 (stdout, pass/fail
       counts, manual checklist status, notes on failed items).
  4. Call `mcp__slite__create-note` with:
     - title: `QA Plan: {ticket-key} — {title} ({branch})`
     - parent: the resolved parent id from step 2
     - content: the composed record from step 3
  5. On success, print: `QA plan documented to Slite: {note_url}`.
     On any failure (channel resolution or note creation), print a warning with the error
     and continue — the plan remains completed and locally archived.

**Edit** — Two options:
1. **Inline**: Ask the user what to change. Apply their feedback to the `## Draft Response` section using Edit. Then re-display and ask for approval again.
2. **Editor**: Tell the user the file path and ask them to edit it in their editor. When they confirm they're done, re-read the file and ask for approval.

**Reject** — Ask for a brief reason, then invoke the `execute-item` skill with `item` = the selected file, `decision` = `reject`, and `reason` = the reason. It records `rejected_reason`, sets `status: rejected`, and moves the file to `~/.claude/engineer-agent/queue/rejected/`.

**Skip** — Leave the file in `~/.claude/engineer-agent/queue/drafts/` unchanged. Move to the next item.

### 7. Loop

After handling one item, return to the summary table (Step 3) with updated counts. Continue until all items are handled or the user exits.

### 8. Summary

When done, report: "Reviewed N items: X approved, Y rejected, Z skipped."
