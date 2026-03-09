---
name: generate-digest
description: "Generate a daily activity digest summarizing all engineer-agent work. Use this skill when asked to create a digest, or when triggered by the daily schedule."
version: 1.0.0
---

# Generate Daily Digest

Create a comprehensive summary of all agent activity for the day.

## Tools Needed

- `Read` — read config, queue items
- `Glob` — find queue items by date
- `Bash` — count and aggregate
- `Write` — write draft digest

## Steps

### 1. Load Config

Read `.claude/engineer-agent/engineer.yaml`. Extract `agent.digest_channel`.

### 2. Gather All Activity

Scan all queue directories for items from the current day (or since the last digest):

**Completed items** (`.claude/engineer-agent/queue/completed/`):
- Count by type (pr-review, slack-question, ticket, doc-review)
- List each with title and source

**Rejected items** (`.claude/engineer-agent/queue/rejected/`):
- Count and list with rejection reasons

**Pending items** (`.claude/engineer-agent/queue/drafts/`):
- Count by type
- Note any aging items (older than 24h)

**Incoming items** (`.claude/engineer-agent/queue/incoming/`):
- Count any unprocessed items (shouldn't normally be any)

### 3. Calculate Metrics

- Total items processed today
- Approval rate (completed / (completed + rejected))
- Items by type breakdown
- Average time from detection to approval (if timestamps allow)
- Any items still pending from previous days

### 4. Write the Draft

Create a queue item in `.claude/engineer-agent/queue/drafts/`:

**Filename:** `{YYYYMMDD-HHmmss}-digest.md`

**Content:**
```yaml
---
type: digest
source: internal
source_id: "digest-{YYYY-MM-DD}"
title: "Daily Digest for {YYYY-MM-DD}"
priority: low
created_at: "{current_iso_timestamp}"
status: drafted
target_channel: "{digest_channel}"
---

## Context

Auto-generated daily digest from engineer-agent activity.

## Draft Response

### Proposed Digest Message

**Engineer Agent Daily Digest — {YYYY-MM-DD}**

**Summary:** Processed {N} items today ({X} approved, {Y} rejected, {Z} pending).

**PR Reviews:** {N}
{bullet list of reviewed PRs with recommendations}

**Slack Q&A:** {N}
{bullet list of answered questions}

**Tickets:** {N}
{bullet list of tickets worked on with status}

**Doc Reviews:** {N}
{bullet list of reviewed docs}

**Pending:** {N} items awaiting review
{list if any, especially aging items}
```

### 5. Report

Report: "Daily digest generated. Run `/engineer review-queue` to review and post."
