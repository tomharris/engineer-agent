---
description: "Review and approve/reject queued engineer-agent work items"
argument-hint: "[filter: pr|slack|ticket|doc] [--all]"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Agent", "AskUserQuestion", "mcp__plugin_github_github__pull_request_review_write", "mcp__plugin_github_github__create_pull_request", "mcp__plugin_github_github__add_issue_comment", "mcp__claude_ai_Slack__slack_send_message"]
---

# Engineer Agent: Review Queue

Review pending draft items and approve, edit, or reject them.

## Arguments

- `$ARGUMENTS` may contain a filter: `pr`, `slack`, `ticket`, or `doc` to show only that type
- `$ARGUMENTS` may contain `--all` to show all items including completed/rejected

## Steps

### 1. Load Config

Read `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. If missing, tell the user to copy `engineer.example.yaml` and stop.

### 2. List Draft Items

Use Glob to find all `.md` files in `${CLAUDE_PLUGIN_ROOT}/queue/drafts/` (excluding `.gitkeep`).

If a filter was provided in `$ARGUMENTS`, only show items matching that type in their YAML frontmatter `type` field.

If no items found, report: "No items to review. Run `/engineer poll` to check for new work."

### 3. Display Summary Table

Read each file's YAML frontmatter and display a numbered summary:

```
# Engineer Agent Queue (N items)

| #  | Type       | Source             | Title                        | Priority | Age     |
|----|------------|--------------------|------------------------------|----------|---------|
| 1  | PR Review  | org/repo#142       | Add caching layer to auth... | normal   | 2h ago  |
| 2  | Slack Q&A  | #engineering       | How does auth cache work?    | normal   | 45m ago |
```

Sort by priority (urgent first) then by created_at (oldest first).

### 4. User Selects Item

Ask the user which item to review (by number). Also offer "approve all" if all items are low-risk (no urgent priority, no ticket implementations).

### 5. Show Full Draft

Read the selected file completely and display:
- The `## Context` section with source details
- The `## Draft Response` section with the full proposed content
- The source URL for reference

### 6. User Chooses Action

Ask the user what to do:

**Approve** — Execute the action:
- For `pr-review` type: Call `mcp__plugin_github_github__pull_request_review_write` to submit the review on the PR.
- For `slack-question` type: Call `mcp__claude_ai_Slack__slack_send_message` to post the reply in the thread.
- For `ticket` type: Call `mcp__plugin_github_github__create_pull_request` to open a PR from the implementation branch.
- For `doc-review` type: Use Bash with curl to post comments to the Slite API.

After executing, update the file's frontmatter `status` to `completed` and move it from `queue/drafts/` to `queue/completed/` (write to new location, delete from old).

**Edit** — Two options:
1. **Inline**: Ask the user what to change. Apply their feedback to the `## Draft Response` section using Edit. Then re-display and ask for approval again.
2. **Editor**: Tell the user the file path and ask them to edit it in their editor. When they confirm they're done, re-read the file and ask for approval.

**Reject** — Ask for a brief reason. Add a `rejected_reason` field to the frontmatter. Update `status` to `rejected`. Move the file to `queue/rejected/`.

**Skip** — Leave the file in `queue/drafts/` unchanged. Move to the next item.

### 7. Loop

After handling one item, return to the summary table (Step 3) with updated counts. Continue until all items are handled or the user exits.

### 8. Summary

When done, report: "Reviewed N items: X approved, Y rejected, Z skipped."
