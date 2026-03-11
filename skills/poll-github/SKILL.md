---
name: poll-github
description: "Poll GitHub for new pull requests that need review. Use this skill when checking for new PRs, when running an engineer-agent poll cycle, or when the user asks to check GitHub for work."
version: 1.0.0
---

# Poll GitHub for New PRs

Check configured GitHub repos for pull requests that need review and create queue items for each. Iterates over all projects that have GitHub configured.

## Tools Needed

- `Bash` — `gh` CLI commands for GitHub API access, file operations
- `Read` — read config and state files
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. Extract the `projects` map and `agent` settings.

If config is missing, report the error and stop.

### 2. Load Dedup State

Read `~/.claude/engineer-agent/state/last-poll.yaml` if it exists. This contains per-project state under `projects.<slug>`.

If the state file doesn't exist, treat everything as new (use epoch as last_checked).

### 3. Iterate Over Projects

For each project slug in the `projects` config map that has a `github` section configured:

Extract `projects.<slug>.github.owner`, `projects.<slug>.github.repos`, `projects.<slug>.github.review_requested_for`, and `projects.<slug>.github.ignore_labels`.

Load dedup state from `projects.<slug>.github` in last-poll.yaml (use epoch defaults if missing).

#### 3a. Poll Each Repo

For each repo in `projects.<slug>.github.repos`:

1. Run via Bash:
   ```bash
   gh pr list --repo {owner}/{repo} --state open --json number,title,author,url,labels,headRefName,baseRefName,changedFiles,reviewRequests,body --limit 100
   ```
   This returns JSON with PR details. The `reviewRequests` array contains objects with `login` fields to match against `review_requested_for`.

2. Filter results:
   - Only PRs where review is requested from `review_requested_for`
   - Exclude PRs with any label in `ignore_labels`
   - Exclude PRs whose `source_id` (`{owner}/{repo}#{number}`) already exists in any queue file (check with Glob across all queue subdirectories for files containing that source_id)
   - Exclude PRs already in `projects.<slug>.github.seen_prs`

3. For PRs with more than `agent.max_pr_files` changed files (default 50), skip and log a warning.

#### 3b. Create Queue Items

For each new PR found, create a file in `~/.claude/engineer-agent/queue/incoming/` with:

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
project: "{slug}"
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

#### 3c. Process Incoming Items

After creating queue items, for each new item in `incoming/`, invoke the **review-pr** skill behavior:
- Fetch the PR details and diff via Bash:
  ```bash
  gh pr view {number} --repo {owner}/{repo} --json title,body,author,files,commits,headRefName,baseRefName,url,number
  gh pr diff {number} --repo {owner}/{repo}
  ```
- Generate a structured review
- Write the review to the `## Draft Response` section
- Move the file from `incoming/` to `drafts/`
- Update the frontmatter `status` to `drafted`

#### 3d. Update State

Update `~/.claude/engineer-agent/state/last-poll.yaml` under `projects.<slug>.github` with:
- `last_checked`: current ISO timestamp
- `seen_prs`: append newly found PR source_ids

### 4. Report

Report how many new PRs were found per project: "Found N new PRs for review across M projects. Run `/engineer review-queue` to review drafts."
