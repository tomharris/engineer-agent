---
description: "Generate a QA test plan for a feature branch using ticket acceptance criteria and code changes"
model: sonnet
argument-hint: "[ticket-url-or-key] [--project <slug>] [--base <branch>]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion", "Agent",
  "mcp__atlassian__getJiraIssue",
  "mcp__plugin_github_github__issue_read"]
---

# Engineer Agent: QA

Generate a QA test plan for a feature branch by cross-referencing ticket acceptance criteria, PR testing notes, and code changes. Produces a runnable test script (curl commands for API changes, REPL snippets for service changes) and a manual checklist for items requiring human judgment.

## Arguments

- `$ARGUMENTS` may contain a ticket URL, Jira key (e.g. `ENG-123`), or GitHub issue URL to use instead of inferring from the branch name
- `$ARGUMENTS` may contain `--project <slug>` to associate with a specific project
- `$ARGUMENTS` may contain `--base <branch>` to specify the base branch for diffing (default: `main`)

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

### 2. Determine Project

If `--project <slug>` is specified in `$ARGUMENTS`, use that slug. Otherwise, try to infer the project from the current working directory by matching against `projects.<slug>.path` values in config. If no match, ask the user which project this belongs to (list available slugs).

Verify the project has a `qa` section in config. If `qa.base_url` is missing, warn the user and default to `http://localhost:3000`.

### 3. Infer Branch & Ticket

Get the current branch:
```bash
git rev-parse --abbrev-ref HEAD
```

If `$ARGUMENTS` contains a ticket URL or key, use that directly:
- **Jira key** (e.g. `ENG-123`): use as-is
- **GitHub issue URL** (e.g. `https://github.com/org/repo/issues/42`): extract `#42`
- **Jira URL** (e.g. `https://myorg.atlassian.net/browse/ENG-123`): extract `ENG-123`

Otherwise, extract the ticket ID from the branch name using these patterns (try in order):
1. `{prefix}/{KEY-123}` → `KEY-123` (e.g. with configured prefix `myprefix`: `myprefix/ENG-123` → `ENG-123`)
2. `{prefix}/{KEY-123}-{slug}` → `KEY-123` (e.g. `myprefix/ENG-123-add-caching` → `ENG-123`)
3. `{prefix}/issue-{number}-{slug}` → `#{number}` (e.g. `myprefix/issue-42-add-caching` → `#42`)
4. `{KEY-123}-{slug}` → `KEY-123` (e.g. `ENG-123-add-caching` → `ENG-123`)
5. `feature/{KEY-123}` → `KEY-123`
6. `feature/{KEY-123}-{slug}` → `KEY-123`

Where `{prefix}` matches the configured `agent.branch_prefix` and `{KEY-123}` is an uppercase project key followed by a dash and number.

If no ticket ID can be extracted and no argument was provided, ask the user for a ticket URL or key using AskUserQuestion.

Determine the base branch: use `--base` argument if provided, otherwise default to `main`.

### 4. Gather Sources

Collect context from all available sources:

#### 4a. Fetch Ticket Details

Determine the tracker type for this project (`projects.<project>.tracker`, or infer from config sections).

- **If Jira:** Fetch via `mcp__atlassian__getJiraIssue` using the Jira key. Extract:
  - Title/summary
  - Description
  - Acceptance criteria (look in description, or in a custom "Acceptance Criteria" field)
  - Testing notes (look for a "Testing Notes" or "Test Plan" section/field)
  - Status

- **If GitHub Issues:** Fetch via Bash:
  ```bash
  gh issue view {number} --repo {owner}/{repo} --json title,body,labels,state
  ```
  Extract:
  - Title
  - Body (look for `## Acceptance Criteria`, `## Testing Notes`, or `## Test Plan` sections)
  - Labels

If the ticket cannot be found, warn the user but continue — the QA plan will be based on code changes only, with no AC mapping.

#### 4b. Check for PR

Check if a PR exists for the current branch:
```bash
gh pr list --head {branch} --repo {owner}/{repo} --json number,title,body,url --limit 1
```

If a PR exists, extract:
- PR number and URL
- PR description
- Testing notes (look for `## Testing`, `## Test Plan`, `## QA`, or `## How to Test` sections in the body)

#### 4c. Get Code Changes

```bash
git diff --name-status {base}...HEAD
git diff {base}...HEAD
```

### 5. Create Queue Item

Generate a timestamp for the filename. Use the ticket key as the short ID (e.g. `ENG-123` or `issue-42`).

Create the queue item at `~/.claude/engineer-agent/queue/incoming/{YYYYMMDD-HHmmss}-qa-test-plan-{ticket-key}.md`:

Set `source` based on tracker type: `jira` if tracker is `jira`, `github` if tracker is `github-issues` or if no ticket was found.

```yaml
---
type: qa-test-plan
source: "{jira or github — based on tracker type}"
source_url: "{ticket_url}"
source_id: "{ticket-key}"
title: "QA: {ticket_title}"
priority: normal
created_at: "{ISO 8601}"
status: incoming
project: "{slug}"
branch: "{branch_name}"
base: "{base_branch}"
pr_url: "{pr_url or empty}"
pr_number: {pr_number or empty}
ticket_key: "{ticket_key}"
---

## Context

### Ticket: {ticket_key} — {ticket_title}

**Status:** {status}
**Tracker:** {tracker_type}
**URL:** {ticket_url}

### Description

{ticket_description}

### Acceptance Criteria

{acceptance_criteria — each criterion on its own line, numbered if possible}

{if no acceptance criteria found:}
_No explicit acceptance criteria found in ticket. The generate-qa skill will infer testable requirements from the description and code changes._

### Testing Notes

{testing_notes_from_ticket}

{if no testing notes:}
_No testing notes found in ticket._

### PR Testing Notes

{if PR exists:}
**PR:** #{pr_number} — {pr_title}
**URL:** {pr_url}

{testing_notes_from_pr}

{if no PR:}
_No PR found for branch {branch}._

### Changed Files

```
{git diff --name-status output}
```

### Diff

```diff
{git diff output}
```

## Draft Response

_(to be filled by generate-qa skill)_
```

### 6. Process with Skill

Invoke the `generate-qa` skill to process the queue item and fill in the `## Draft Response`.

### 7. Report

Report: "QA test plan drafted for {ticket-key} on branch {branch}. Run `/engineer-agent review-queue qa` to review."
