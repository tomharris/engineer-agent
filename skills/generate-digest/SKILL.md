---
name: generate-digest
description: "Generate a daily activity digest summarizing all engineer-agent work. Use this skill when asked to create a digest, or when triggered by the daily schedule."
version: 1.0.0
model: haiku
---

# Generate Daily Digest

Create a comprehensive summary of all agent activity for the day, grouped by project.

## Tools Needed

- `Read` — read config, queue items
- `Glob` — find queue items by date
- `Bash` — count and aggregate
- `Write` — write draft digest

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract the `projects` map and `agent.digest_channel`.

### 2. Gather All Activity

Scan all queue directories for items from the current day (or since the last digest):

**Completed items** (`~/.local/share/engineer-agent/queue/completed/`):
- Count by type and by project (pr-review, slack-question, ticket, doc-review)
- List each with title, source, and project

**Rejected items** (`~/.local/share/engineer-agent/queue/rejected/`):
- Count and list with rejection reasons and project

**Pending items** (`~/.local/share/engineer-agent/queue/drafts/`):
- Count by type and project
- Note any aging items (older than 24h)

**Incoming items** (`~/.local/share/engineer-agent/queue/incoming/`):
- Count any unprocessed items (shouldn't normally be any)

### 3. Calculate Metrics

- Total items processed today
- Approval rate (completed / (completed + rejected))
- Items by type breakdown
- Items by project breakdown
- Average time from detection to approval (if timestamps allow)
- Any items still pending from previous days

### 4. Write the Draft

Create a queue item in `~/.local/share/engineer-agent/queue/drafts/`:

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

Auto-generated daily digest from engineer-agent activity across all projects.

## Draft Response

### Proposed Digest Message

**Engineer Agent Daily Digest — {YYYY-MM-DD}**

**Summary:** Processed {N} items today ({X} approved, {Y} rejected, {Z} pending) across {M} projects.

**By Project:**

__{project-slug-1}:__
- PR Reviews: {N} — {bullet list}
- Slack Q&A: {N} — {bullet list}

__{project-slug-2}:__
- Tickets: {N} — {bullet list}
- Doc Reviews: {N} — {bullet list}

**Pending:** {N} items awaiting review
{list if any, especially aging items}
```

### 5. Report

Report: "Daily digest generated covering {M} projects. Run `/engineer-agent review-queue` to review and post."
