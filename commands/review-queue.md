---
description: "Review and approve/reject queued engineer-agent work items"
argument-hint: "[filter: pr|slack|ticket|ticket-plan|doc|spec|design|refinement] [--all] [--project <slug>]"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Agent", "AskUserQuestion", "mcp__claude_ai_Slack__slack_send_message", "mcp__slite__append-blocks", "mcp__slite__create-note"]
---

# Engineer Agent: Review Queue

Review pending draft items and approve, edit, or reject them.

## Arguments

- `$ARGUMENTS` may contain a filter: `pr`, `slack`, `ticket`, `ticket-plan`, `doc`, `spec`, `design`, or `refinement` to show only that type
- `$ARGUMENTS` may contain `--all` to show all items including completed/rejected
- `$ARGUMENTS` may contain `--project <slug>` to show only items for a specific project

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer setup` and stop. Extract `agent.branch_prefix` (default: `engineer-agent`).

### 2. List Draft Items

Use Glob to find all `.md` files in `~/.claude/engineer-agent/queue/drafts/` (excluding `.gitkeep`).

If a filter was provided in `$ARGUMENTS`, only show items matching that type in their YAML frontmatter `type` field.

If `--project <slug>` was provided, only show items whose `project` frontmatter field matches the slug.

If no items found, report: "No items to review. Run `/engineer poll` to check for new work."

### 3. Display Summary Table

Read each file's YAML frontmatter and display a numbered summary:

```
# Engineer Agent Queue (N items)

| #  | Project | Type       | Source             | Title                        | Priority | Age     |
|----|---------|------------|--------------------|------------------------------|----------|---------|
| 1  | my-api  | PR Review  | org/repo#142       | Add caching layer to auth... | normal   | 2h ago  |
| 2  | my-app  | Slack Q&A  | #engineering       | How does auth cache work?    | normal   | 45m ago |
```

Sort by priority (urgent first) then by created_at (oldest first).

### 4. User Selects Item

Ask the user which item to review (by number). Also offer "approve all" if all items are low-risk (no urgent priority, no ticket implementations).

### 5. Show Full Draft

Read the selected file completely and display:
- The `project` field
- The `## Context` section with source details
- The `## Draft Response` section with the full proposed content
- The source URL for reference

### 6. User Chooses Action

Ask the user what to do:

**Approve** — Execute the action:
- For `pr-review` type: Submit the review via Bash:
  ```bash
  gh pr review {pr_number} --repo {repo} --{approve|comment|request-changes} --body "{review_body}"
  ```
  Use `--approve`, `--comment`, or `--request-changes` based on the draft's **Recommendation** field.
- For `slack-question` type: Call `mcp__claude_ai_Slack__slack_send_message` to post the reply in the thread.
- For `ticket` type: Look up the project's config. Determine the tracker type (`projects.<project>.tracker`, or infer from `source` frontmatter: `github` → `github-issues`, `jira` → `jira`). Create a draft PR via Bash:
  - **If tracker is `github-issues`:** Extract issue number from `ticket_key` (strip `#`), derive slug from title (lowercase, non-alphanumeric → hyphens, truncate 40 chars):
    ```bash
    gh pr create --repo {owner}/{repo} --title "#{number}: {title}" --body "{body with 'Closes #{number}'}" --head "{branch_prefix}/issue-{number}-{slug}" --base main --draft
    ```
  - **If tracker is `jira`:**
    ```bash
    gh pr create --repo {owner}/{repo} --title "{ticket_key}: {title}" --body "{body}" --head "{branch_prefix}/{ticket_key}" --base main --draft
    ```
- For `doc-review` type: Call `mcp__slite__append-blocks` to post review comments on the document.
- For `spec-refinement` type: No external action needed. Move to `~/.claude/engineer-agent/queue/completed/`. Print: "Spec refinement complete. Run `/engineer create-design-doc {source_url}` to generate the design doc."
- For `design-doc` type: Look up `projects.<project>.slite.design_doc_parent` from config. Call `mcp__slite__create-note` with title from frontmatter, parent from config, and content from `## Draft Response`. Print: "Design doc created in Slite: {url}"
- For `ticket-refinement` type: No external action needed. Move to `~/.claude/engineer-agent/queue/completed/`. Print: "Ticket refinement complete for {ticket_key}. Estimated size: {estimated_size} points."
- For `ticket-plan` type: Determine the tracker type for the item's project.
  - **If tracker is `github-issues`:** Create GitHub Issues for each ticket in the plan via `gh issue create --repo {owner}/{repo} --title "{title}" --body "{body}" --label "{labels}"`. Report created issue URLs. Move to `~/.claude/engineer-agent/queue/completed/`.
  - **If tracker is `jira`:** No automated creation. Move to `~/.claude/engineer-agent/queue/completed/`. Print: "Ticket plan approved. Use as reference when creating tickets in Jira."
  - **If tracker is `none`:** Move to `~/.claude/engineer-agent/queue/completed/`. Print: "Ticket plan approved. Use as reference when creating tickets in your project tracker."

After executing, update the file's frontmatter `status` to `completed` and move it from `~/.claude/engineer-agent/queue/drafts/` to `~/.claude/engineer-agent/queue/completed/` (write to new location, delete from old).

**Edit** — Two options:
1. **Inline**: Ask the user what to change. Apply their feedback to the `## Draft Response` section using Edit. Then re-display and ask for approval again.
2. **Editor**: Tell the user the file path and ask them to edit it in their editor. When they confirm they're done, re-read the file and ask for approval.

**Reject** — Ask for a brief reason. Add a `rejected_reason` field to the frontmatter. Update `status` to `rejected`. Move the file to `~/.claude/engineer-agent/queue/rejected/`.

**Skip** — Leave the file in `~/.claude/engineer-agent/queue/drafts/` unchanged. Move to the next item.

### 7. Loop

After handling one item, return to the summary table (Step 3) with updated counts. Continue until all items are handled or the user exits.

### 8. Summary

When done, report: "Reviewed N items: X approved, Y rejected, Z skipped."
