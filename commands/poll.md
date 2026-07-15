---
description: "Poll configured sources for new work items"
model: haiku
argument-hint: "[github|slack|jira|github-issues|slite|all] [--project <slug>]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Agent", "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__getJiraIssue", "mcp__slite__search-notes", "mcp__slite__get-note", "mcp__slite__get-note-children", "mcp__slite__append-blocks"]
---

# Engineer Agent: Poll for New Work

Manually trigger a poll of configured sources for new work items.

## Arguments

`$ARGUMENTS` specifies which source to poll and optionally which project. Options:
- `github` — poll GitHub PRs only
- `slack` — poll Slack only
- `jira` — poll Jira only
- `github-issues` — poll GitHub Issues only
- `slite` — poll Slite only
- `all` or empty — poll all configured sources
- `--project <slug>` — poll only the specified project (default: all projects)

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

### 2. Determine Scope

Parse `$ARGUMENTS` to determine which sources to poll and which projects to include.

If `--project <slug>` is specified, only poll that project. Otherwise, iterate over all projects in the `projects` config map.

Default to `all` sources if no source argument provided.

### 3. Poll Each Project and Source

For each project in scope, for each selected source:

Check if the project has that integration configured (e.g., `projects.<slug>.github` exists and has values). Skip sources with empty or missing config and report which were skipped.

Run the appropriate poll skill behavior:
- **github**: Follow the `poll-github` skill steps — list PRs, filter, create queue items, generate review drafts.
- **slack**: Follow the `poll-slack` skill steps — read channels, find questions matching keywords, create queue items, generate answer drafts.
- **jira**: Follow the `poll-jira` skill steps — query assigned tickets, create queue items. Only for projects where tracker resolves to `jira`.
- **github-issues**: Follow the `poll-github-issues` skill steps — query assigned issues, create queue items. Only for projects where tracker resolves to `github-issues`.
- **slite**: Follow the `poll-slite` skill steps — check for docs tagged for review, create queue items.

Each queue item must include `project: "<slug>"` in its frontmatter.

### 4. Report Results

Summarize what was found across all polled projects and sources:

```
Poll complete:

my-api:
- GitHub: Found N new PRs
- Slack: Found N new questions

my-app:
- Jira: Found N new tickets

Total: N new items queued. Run `/engineer-agent review-queue` to review drafts.
```

Only include projects and sources that were actually polled.
