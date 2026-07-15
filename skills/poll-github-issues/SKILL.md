---
name: poll-github-issues
description: "Poll GitHub Issues for new or updated issues assigned to the user. Use this skill when checking GitHub Issues for work, or during an engineer-agent poll cycle."
version: 1.0.0
model: haiku
---

# Poll GitHub Issues for Assigned Issues

Check GitHub Issues for issues assigned to the configured user that need implementation. Iterates over all projects that have GitHub Issues configured as their tracker.

## Tools Needed

- `Bash` — run `gh` CLI commands to query GitHub Issues
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract the `projects` map and `agent.branch_prefix` (required — read the literal string from the yaml; do not assume a default. If missing or empty, stop and tell the user to set `agent.branch_prefix`).

### 2. Load Dedup State

Read `~/.local/share/engineer-agent/state/last-poll.yaml`. This contains per-project state under `projects.<slug>`.

### 3. Iterate Over Projects

For each project slug in the `projects` config map where the tracker resolves to `github-issues`:

- If `tracker` is explicitly `"github-issues"`, proceed
- If `tracker` is absent, proceed only if `github.issues` section exists and no `jira` section exists
- Skip projects where `tracker` is explicitly set to something other than `"github-issues"`

Extract `projects.<slug>.github.owner`, `projects.<slug>.github.repos`, and `projects.<slug>.github.issues` (assignee, labels).

Load dedup state from `projects.<slug>.github_issues` in last-poll.yaml (use epoch defaults if missing).

#### 3a. Query GitHub Issues

For each repo in `projects.<slug>.github.repos`, run via Bash:

```bash
gh issue list --assignee {assignee} --repo {owner}/{repo} --state open --json number,title,body,labels,url,assignees,milestone,createdAt,updatedAt
```

If `github.issues.labels` is non-empty, add `--label {label}` flags for each label.

#### 3b. Filter Results

For each issue returned:
- Exclude issues whose source_id (e.g., `"myorg/my-app#45"`) is already in `projects.<slug>.github_issues.seen_issues`
- Exclude issues whose `source_id` already exists in any queue file
- Include issues that were previously seen but have `updatedAt` newer than `last_checked` (re-queue for updated context)

#### 3c. Create Queue Items

For each new issue, create a file in `~/.local/share/engineer-agent/queue/incoming/`:

**Filename:** `{YYYYMMDD-HHmmss}-ticket-gh-{number}.md`

**Content:**
```yaml
---
type: ticket
source: github
source_url: "{issue_url}"
source_id: "{owner}/{repo}#{number}"
title: "{issue_title}"
priority: "{mapped_priority}"
created_at: "{current_iso_timestamp}"
status: incoming
project: "{slug}"
ticket_key: "#{number}"
---

## Context

**Ticket:** #{number} — {issue_title}
**Status:** Open
**Priority:** {mapped_priority}
**Project:** {slug}
**URL:** {issue_url}

### Description
{issue_body}

### Acceptance Criteria
{extract from body if present, otherwise note "No explicit acceptance criteria"}

### Labels
{comma-separated label names}
```

**Priority mapping:** GitHub Issues don't have built-in priority. Default to `normal`. If the issue has a label matching `priority:high` or `urgent` → `urgent`. If label matches `priority:low` → `low`.

#### 3d. Process Incoming Items

For ticket items, create an **implementation plan** draft:

1. Read the issue details
2. Identify which repo this issue applies to (from labels, description, or the project's config)
3. Derive a branch slug from the title: lowercase, replace non-alphanumeric characters with hyphens, truncate to 40 chars, strip trailing hyphens
4. Draft a brief implementation plan (which files to change, approach)
5. Move to `drafts/` with status `drafted`

The `## Draft Response` section for tickets:

```markdown
## Draft Response

### Implementation Plan

**Target repo:** {repo}
**Branch:** {branch_prefix}/issue-{number}-{slug}
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

#### 3e. Update State

Update `projects.<slug>.github_issues.last_checked` and append new issue source_ids to `projects.<slug>.github_issues.seen_issues` in `~/.local/share/engineer-agent/state/last-poll.yaml`.

### 4. Report

Report: "Found N new GitHub issues across M projects."
