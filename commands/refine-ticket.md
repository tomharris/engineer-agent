---
description: "Analyze existing tickets for scope, feasibility, testability, and sizing"
model: sonnet
argument-hint: "<jira-key|github-url|--jql \"...\"|--text \"...\"> [--project <slug>]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Agent", "AskUserQuestion",
  "mcp__atlassian__getJiraIssue", "mcp__atlassian__searchJiraIssuesUsingJql"]
---

# Engineer Agent: Refine Ticket

Analyze existing tickets for scope clarity, implementation feasibility, testability, and Fibonacci sizing.

## Arguments

- `$ARGUMENTS` should contain one or more ticket sources:
  - Jira key: `ENG-123`
  - Multiple Jira keys: `ENG-123 ENG-124 ENG-125`
  - JQL query: `--jql "project = ENG AND status = 'To Do'"`
  - GitHub issue URL: `https://github.com/org/repo/issues/45`
  - Pasted text: `--text "As a user, I want to..."`
- `$ARGUMENTS` may contain `--project <slug>` to associate with a specific project

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

### 2. Determine Project

If `--project <slug>` is specified, use that slug. Otherwise, try to infer the project from the current working directory by matching against `projects.<slug>.path` values in config. If no match, ask the user which project this belongs to (list available slugs).

### 3. Parse Source Arguments

Detect the source type from `$ARGUMENTS`:

- **Jira key(s):** Matches pattern like `ENG-123`, `PROJ-42`, etc. (uppercase letters, dash, digits). Multiple keys may be space-separated.
- **JQL query:** Present if `--jql "..."` is in arguments. Extract the query string.
- **GitHub issue URL:** Matches `https://github.com/{owner}/{repo}/issues/{number}`.
- **Pasted text:** Present if `--text "..."` is in arguments. Extract the text content.
- If no source argument provided, ask the user what ticket to refine.

### 4. Fetch Ticket(s)

**For Jira key(s):**
Call `mcp__atlassian__getJiraIssue` for each key. Extract title, description, acceptance criteria, labels, and linked issues.

**For JQL query:**
Call `mcp__atlassian__searchJiraIssuesUsingJql` with the query. For each result, extract the same fields as above.

**For GitHub issue URL:**
Parse the owner, repo, and issue number from the URL. Use Bash to run:
```bash
gh issue view {number} --repo {owner}/{repo} --json title,body,labels,assignees,milestone
```

**For pasted text:**
Use the text as-is. Set ticket_key to `TEXT-{timestamp_short}`.

If any fetch fails, report the error for that ticket and continue with others.

### 5. Create Queue Items

For each ticket, generate a timestamp and write a new file to `~/.claude/engineer-agent/queue/incoming/`:

Filename: `{YYYYMMDD-HHmmss}-ticket-refinement-{ticket_key_short}.md`
- For Jira: use the key lowercased (e.g., `eng-123`)
- For GitHub: use `gh-{number}` (e.g., `gh-45`)
- For text: use `text-{timestamp_short}`

```yaml
---
type: ticket-refinement
source: "{jira|github|text}"
source_url: "{ticket_url_or_empty}"
source_id: "{jira:ENG-123|github:org/repo#45|text:{id}}"
title: "Refine: {ticket_title}"
priority: normal
created_at: "{ISO 8601 timestamp}"
status: incoming
project: "{slug}"
ticket_key: "{ENG-123|org/repo#45|TEXT-{id}}"
estimated_size: null
---

## Context

**Ticket:** {ticket_key}
**Title:** {ticket_title}
**Source:** {source_url or "pasted text"}
**Project:** {slug}
**Fetched:** {timestamp}

{full ticket content — description, acceptance criteria, labels, etc.}

## Draft Response

_(to be filled by refine-ticket skill)_
```

### 6. Process Tickets

**Single ticket:** Follow the `refine-ticket` skill behavior directly to analyze the ticket and fill in the `## Draft Response` section.

**Multiple tickets (2+):** Dispatch parallel agents using the `Agent` tool — one agent per queue item. Each agent should:
- Read the queue item from `~/.claude/engineer-agent/queue/incoming/`
- Follow the `refine-ticket` skill to analyze the ticket against the codebase
- Write the draft and move the item to `~/.claude/engineer-agent/queue/drafts/`

Launch all agents in a single message so they run concurrently. Wait for all to complete before reporting.

If any agent fails, report which ticket(s) failed and continue with the successes.

### 7. Report

Report: "Refined {N} ticket(s) for project '{slug}'. Run `/engineer-agent review-queue refinement` to review."
