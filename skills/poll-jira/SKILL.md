---
name: poll-jira
description: "Poll Jira for new or updated tickets assigned to the user. Use this skill when checking Jira for work, or during an engineer-agent poll cycle."
version: 1.0.0
---

# Poll Jira for Assigned Tickets

Check Jira for tickets assigned to the configured user that need implementation.

## Tools Needed

- `mcp__atlassian__searchJiraIssuesUsingJql` — search for tickets by JQL
- `mcp__atlassian__getJiraIssue` — fetch individual ticket details
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. Extract `jira.project`, `jira.assignee`, and `jira.statuses`.

### 2. Load Dedup State

Read `${CLAUDE_PLUGIN_ROOT}/state/last-poll.yaml`. Note `jira.last_checked` and `jira.seen_tickets`.

### 3. Query Jira

Build a JQL query:
```
project = {project} AND assignee = "{assignee}" AND status IN ({statuses}) AND updated > "{last_checked}"
```

Call `mcp__atlassian__searchJiraIssuesUsingJql` with the JQL query to get matching tickets.

For each ticket that needs detailed information (description, comments), call `mcp__atlassian__getJiraIssue` with the ticket key to fetch full details including:
- summary, description, status, priority, labels
- recent comments

### 4. Filter Results

For each ticket returned:
- Exclude tickets whose key (e.g., "ENG-456") is already in `jira.seen_tickets`
- Exclude tickets whose `source_id` already exists in any queue file
- Include tickets that were previously seen but have new comments or status changes (re-queue for updated context)

### 5. Create Queue Items

For each new ticket, create a file in `${CLAUDE_PLUGIN_ROOT}/queue/incoming/`:

**Filename:** `{YYYYMMDD-HHmmss}-ticket-{ticket_key}.md`

**Content:**
```yaml
---
type: ticket
source: jira
source_url: "{base_url}/browse/{ticket_key}"
source_id: "{ticket_key}"
title: "{ticket_summary}"
priority: "{map_jira_priority}"
created_at: "{current_iso_timestamp}"
status: incoming
ticket_key: "{ticket_key}"
jira_status: "{ticket_status}"
---

## Context

**Ticket:** {ticket_key} — {ticket_summary}
**Status:** {ticket_status}
**Priority:** {ticket_priority}

### Description
{ticket_description}

### Acceptance Criteria
{extract from description if present, otherwise note "No explicit acceptance criteria"}

### Recent Comments
{last 3-5 comments if any}
```

Map Jira priorities: Highest/High → `urgent`, Medium → `normal`, Low/Lowest → `low`.

### 6. Process Incoming Items

For ticket items, the processing is different from PR reviews. Instead of generating a full draft immediately, create an **implementation plan** draft:

1. Read the ticket details
2. Identify which repo this ticket likely applies to (from labels, description, or config)
3. Draft a brief implementation plan (which files to change, approach)
4. Move to `drafts/` with status `drafted`

The `## Draft Response` section for tickets:

```markdown
## Draft Response

### Implementation Plan

**Target repo:** {repo}
**Branch:** engineer-agent/{ticket_key}
**Approach:** {2-3 sentence summary}

### Files to Modify
- {file_path} — {what changes}

### Implementation Method
This ticket will be implemented using Ralph Loop with:
- Max iterations: 10
- Completion promise: "All acceptance criteria met and tests pass"

### Action on Approval
Approving this item will start a Ralph Loop session to implement the changes, then open a draft PR.
```

### 7. Update State

Update `jira.last_checked` and append new ticket keys to `jira.seen_tickets` in `state/last-poll.yaml`.

### 8. Report

Report: "Found N new Jira tickets."
