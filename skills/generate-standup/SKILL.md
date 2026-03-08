---
name: generate-standup
description: "Generate a daily standup update from recent activity. Use this skill when asked to prepare a standup, or when triggered by the daily schedule."
version: 1.0.0
---

# Generate Standup Update

Create a standup message from recent queue activity and git history.

## Tools Needed

- `Read` — read config, queue items
- `Glob` — find recent queue items
- `Grep` — search queue items by date
- `Bash` — git log across repos
- `Write` — write draft standup
- `mcp__plugin_github_github__list_commits` — recent commits in configured repos

## Steps

### 1. Load Config

Read `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. Extract `github.owner`, `github.repos`, `github.review_requested_for`, and `agent.standup_channel`.

### 2. Gather Yesterday's Work

**Completed queue items:** Glob for files in `${CLAUDE_PLUGIN_ROOT}/queue/completed/` with timestamps from the previous business day. Read each file's frontmatter to extract type, title, and source.

**Git commits:** For each repo in config, call `mcp__plugin_github_github__list_commits` filtering by the configured user and the previous day's date range.

Group by category:
- PRs reviewed
- Slack questions answered
- Tickets implemented
- Docs reviewed

### 3. Gather Today's Planned Work

**Pending queue items:** Glob for files in `${CLAUDE_PLUGIN_ROOT}/queue/drafts/` and `${CLAUDE_PLUGIN_ROOT}/queue/incoming/`. These represent upcoming work.

**In-progress tickets:** Look for ticket-type items that are in progress or recently created.

### 4. Identify Blockers

Check for:
- Queue items with `priority: urgent` that haven't been addressed
- Ticket implementations that hit max iterations (partial completion)
- Items that were rejected with notes indicating external blockers

### 5. Write the Draft

Create a queue item in `${CLAUDE_PLUGIN_ROOT}/queue/drafts/`:

**Filename:** `{YYYYMMDD-HHmmss}-standup.md`

**Content:**
```yaml
---
type: standup
source: internal
source_id: "standup-{YYYY-MM-DD}"
title: "Standup for {YYYY-MM-DD}"
priority: normal
created_at: "{current_iso_timestamp}"
status: drafted
target_channel: "{standup_channel}"
---

## Context

Auto-generated standup from engineer-agent activity.

## Draft Response

### Proposed Standup Message

**Yesterday:**
- {bullet point per completed item, grouped by type}
- Reviewed PR #{N}: {title} in {repo}
- Answered question from @{user} in #{channel}
- Implemented {ticket_key}: {title}

**Today:**
- {bullet point per planned item}
- Review {N} pending PR(s)
- {ticket_key}: continue implementation

**Blockers:**
- {blocker description, or "None"}
```

Keep each bullet point to one short line. This is a standup, not a report.

### 6. Report

Report: "Standup draft generated. Run `/engineer review-queue` to review and post."
