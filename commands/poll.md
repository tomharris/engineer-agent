---
description: "Poll configured sources for new work items"
argument-hint: "[github|slack|jira|slite|all]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Agent", "mcp__plugin_github_github__list_pull_requests", "mcp__plugin_github_github__pull_request_read", "mcp__plugin_github_github__get_file_contents", "mcp__plugin_github_github__list_commits", "mcp__claude_ai_Slack__slack_read_channel", "mcp__claude_ai_Slack__slack_read_thread", "mcp__claude_ai_Slack__slack_search_public_and_private", "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__getJiraIssue", "mcp__slite__search-notes", "mcp__slite__get-note", "mcp__slite__get-note-children", "mcp__slite__append-blocks"]
---

# Engineer Agent: Poll for New Work

Manually trigger a poll of configured sources for new work items.

## Arguments

`$ARGUMENTS` specifies which source to poll. Options:
- `github` — poll GitHub only
- `slack` — poll Slack only
- `jira` — poll Jira only
- `slite` — poll Slite only
- `all` or empty — poll all configured sources

## Steps

### 1. Load Config

Read `.claude/engineer-agent/engineer.yaml`. If missing, tell the user to copy `engineer.example.yaml` and stop.

### 2. Determine Sources

Parse `$ARGUMENTS` to determine which sources to poll. Default to `all` if no argument provided.

For each selected source, check if the relevant config section exists and has values. Skip sources with empty or missing config and report which were skipped.

### 3. Poll Each Source

Run the appropriate poll skill behavior for each selected source:

- **github**: Follow the `poll-github` skill steps — list PRs, filter, create queue items, generate review drafts.
- **slack**: Follow the `poll-slack` skill steps — read channels, find questions matching keywords, create queue items, generate answer drafts.
- **jira**: Follow the `poll-jira` skill steps — query assigned tickets, create queue items.
- **slite**: Follow the `poll-slite` skill steps — check for docs tagged for review, create queue items.

### 4. Report Results

Summarize what was found across all polled sources:

```
Poll complete:
- GitHub: Found N new PRs
- Slack: Found N new questions
- Jira: Found N new tickets
- Slite: Found N new docs for review

Total: N new items queued. Run `/engineer review-queue` to review drafts.
```

Only include sources that were actually polled.
