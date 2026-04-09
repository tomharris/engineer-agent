---
name: generate-standup
description: "Generate a daily standup update from recent activity. Use this skill when asked to prepare a standup, or when triggered by the daily schedule."
version: 1.0.0
model: haiku
---

# Generate Standup Update

Create a standup message from recent queue activity and git history across all projects.

## Tools Needed

- `Read` — read config, queue items
- `Glob` — find recent queue items
- `Grep` — search queue items by date
- `Bash` — `git log` for local repos, `gh api` for remote repos
- `Write` — write draft standup

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. Extract the `projects` map and `agent.standup_channel`.

### 2. Gather Yesterday's Work

**Completed queue items:** Glob for files in `~/.claude/engineer-agent/queue/completed/` with timestamps from the previous business day. Read each file's frontmatter to extract type, title, source, and project.

**Git commits per project:** For each project in the `projects` config map:

Extract `projects.<slug>.path`, `projects.<slug>.github.owner`, `projects.<slug>.github.repos`, and `projects.<slug>.github.review_requested_for`.

For local repos (where `path` exists and is accessible):
```bash
cd {path} && git log --since="{yesterday}" --author="{review_requested_for}" --oneline
```
For remote repos:
```bash
gh api "repos/{owner}/{repo}/commits?author={review_requested_for}&since={yesterday_iso}" --jq '.[].commit.message'
```

Group by project, then by category:
- PRs reviewed
- Slack questions answered
- Tickets implemented
- Docs reviewed

### 3. Gather Today's Planned Work

**Pending queue items:** Glob for files in `~/.claude/engineer-agent/queue/drafts/` and `~/.claude/engineer-agent/queue/incoming/`. These represent upcoming work. Note the `project` field for each.

**In-progress tickets:** Look for ticket-type items that are in progress or recently created.

### 4. Identify Blockers

Check for:
- Queue items with `priority: urgent` that haven't been addressed
- Ticket implementations that hit max iterations (partial completion)
- Items that were rejected with notes indicating external blockers

### 5. Write the Draft

Create a queue item in `~/.claude/engineer-agent/queue/drafts/`:

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

Auto-generated standup from engineer-agent activity across all projects.

## Draft Response

### Proposed Standup Message

**Yesterday:**

__{project-slug-1}:__
- {bullet point per completed item}
- Reviewed PR #{N}: {title} in {repo}
- Answered question from @{user} in #{channel}

__{project-slug-2}:__
- Implemented {ticket_key}: {title}

**Today:**

__{project-slug-1}:__
- Review {N} pending PR(s)

__{project-slug-2}:__
- {ticket_key}: continue implementation

**Blockers:**
- {blocker description, or "None"}
```

Keep each bullet point to one short line. This is a standup, not a report.

### 6. Report

Report: "Standup draft generated covering {N} projects. Run `/engineer-agent review-queue` to review and post."
