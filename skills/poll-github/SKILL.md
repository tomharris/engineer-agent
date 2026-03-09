---
name: poll-github
description: "Poll GitHub for new pull requests that need review. Use this skill when checking for new PRs, when running an engineer-agent poll cycle, or when the user asks to check GitHub for work."
version: 1.0.0
---

# Poll GitHub for New PRs

Check configured GitHub repos for pull requests that need review and create queue items for each.

## Tools Needed

- `mcp__plugin_github_github__list_pull_requests` — list PRs per repo
- `mcp__plugin_github_github__pull_request_read` — read PR details
- `Read` — read config and state files
- `Write` — create queue items
- `Glob` — check for existing queue items
- `Bash` — file operations

## Steps

### 1. Load Config

Read `.claude/engineer-agent/engineer.yaml`. Extract `github.owner`, `github.repos`, `github.review_requested_for`, and `github.ignore_labels`.

If config is missing, report the error and stop.

### 2. Load Dedup State

Read `.claude/engineer-agent/state/last-poll.yaml` if it exists. Note the `github.last_checked` timestamp and `github.seen_prs` list.

If the state file doesn't exist, treat everything as new (use epoch as last_checked).

### 3. Poll Each Repo

For each repo in `github.repos`:

1. Call `mcp__plugin_github_github__list_pull_requests` with:
   - `owner`: from config `github.owner`
   - `repo`: the repo name
   - `state`: "open"

2. Filter results:
   - Only PRs where review is requested from `github.review_requested_for`
   - Exclude PRs with any label in `github.ignore_labels`
   - Exclude PRs whose `source_id` (`{owner}/{repo}#{number}`) already exists in any queue file (check with Glob across all queue subdirectories for files containing that source_id)
   - Exclude PRs already in `github.seen_prs`

3. For PRs with more than `agent.max_pr_files` changed files (default 50), skip and log a warning.

### 4. Create Queue Items

For each new PR found, create a file in `.claude/engineer-agent/queue/incoming/` with:

**Filename:** `{YYYYMMDD-HHmmss}-pr-review-{repo}-{number}.md`

**Content:**
```yaml
---
type: pr-review
source: github
source_url: "{pr_html_url}"
source_id: "{owner}/{repo}#{number}"
title: "{pr_title}"
priority: normal
created_at: "{current_iso_timestamp}"
status: incoming
pr_author: "{pr_author}"
repo: "{owner}/{repo}"
pr_number: {number}
---

## Context

PR #{number} in {owner}/{repo} by @{pr_author}
Files changed: {files_count}
Branch: {head_branch} → {base_branch}

### Description
{pr_body}
```

### 5. Process Incoming Items

After creating queue items, for each new item in `incoming/`, invoke the **review-pr** skill behavior:
- Read the PR diff and details
- Generate a structured review
- Write the review to the `## Draft Response` section
- Move the file from `incoming/` to `drafts/`
- Update the frontmatter `status` to `drafted`

### 6. Update State

Update `.claude/engineer-agent/state/last-poll.yaml` with:
- `github.last_checked`: current ISO timestamp
- `github.seen_prs`: append newly found PR source_ids

Create the `.claude/engineer-agent/state/` directory and file if they don't exist.

### 7. Report

Report how many new PRs were found and queued: "Found N new PRs for review. Run `/engineer review-queue` to review drafts."
