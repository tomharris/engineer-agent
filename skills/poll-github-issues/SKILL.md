---
name: poll-github-issues
description: "Poll GitHub Issues for new or updated issues assigned to the user. Use this skill when checking GitHub Issues for work, or during an engineer-agent poll cycle."
version: 2.0.0
model: haiku
---

# Poll GitHub Issues for Assigned Issues

Check GitHub Issues for issues assigned to the configured user that need implementation. Supports
multiple engineer-agent projects watching the same repo, with routing via
`references/routing-ladder.md`.

## Tools Needed

- `Bash` — run `gh` CLI commands to query GitHub Issues
- `Read` — read config, state, and the routing ladder
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract the `projects` map and `agent.branch_prefix` (required — read the literal string from the yaml; do not assume a default. If missing or empty, stop and tell the user to set `agent.branch_prefix`).

### 2. Load Dedup State

Read `~/.local/share/engineer-agent/state/last-poll.yaml`. This contains:
- `github_repos.<owner>/<repo>.last_checked` — per-repo timestamps (the collection boundary)
- `projects.<slug>.github_issues.seen_issues` — per-engineer-agent-project seen issue lists

### 3. Select Projects

For each project slug in the `projects` config map where the tracker resolves to `github-issues`:

- If `tracker` is explicitly `"github-issues"`, proceed
- If `tracker` is absent, proceed only if a `github.issues` section exists and no `jira` section exists
- Skip projects where `tracker` is explicitly set to something other than `"github-issues"`

Extract `projects.<slug>.github.owner`, `projects.<slug>.github.repos`, and `projects.<slug>.github.issues` (assignee, labels).

### 4. Phase 1 — Collect (Deduplicated Repo Queries)

Build a **deduplicated map** of repos across all engineer-agent projects, so a repo watched by
several projects is fetched once rather than once per project:

```
repo_query_map = {}
For each engineer-agent project (slug, config) selected in Step 3:
  For each repo in config.github.repos:
    key = "{config.github.owner}/{repo}"
    If key not in repo_query_map:
      repo_query_map[key] = { assignees: set(), watchers: [] }
    repo_query_map[key].assignees.add(config.github.issues.assignee)
    repo_query_map[key].watchers.append({ slug, config })
```

For each unique `owner/repo` key in the map:

1. Look up `github_repos.<owner>/<repo>.last_checked` from state (default: `"1970-01-01T00:00:00Z"`
   if missing, or fall back to the earliest `projects.<slug>.github_issues.last_checked` among that
   repo's watchers, for backward compat)
2. Run **one query per distinct assignee** — `gh issue list --assignee` takes a single value, so
   several watchers with different assignees need one call each. Merge the results and deduplicate
   by issue number:

   ```bash
   gh issue list --assignee {assignee} --repo {owner}/{repo} --state open --json number,title,body,labels,url,assignees,milestone,createdAt,updatedAt
   ```

3. **Do not pass `--label`.** Label filters belong to individual watchers, and `gh issue list --label a --label b` means AND, not OR — so several watchers' filters cannot be unioned into one query. Fetch the repo's issues unfiltered and apply each watcher's `github.issues.labels` during routing (ladder Tier 2). Filtering at query time is also what previously let the global dedup in Step 5a hand a shared repo's issue to whichever project the loop reached first.

### 5. Phase 2 — Route Each Issue

For each issue returned from Phase 1:

#### 5a. Check Global Dedup

- Exclude issues whose `source_id` (e.g. `"myorg/my-app#45"`) already exists in any queue file (check all queue directories via Glob)
- Exclude issues whose `source_id` is already in **every** watching project's `projects.<slug>.github_issues.seen_issues`
- Include issues that were previously seen but have `updatedAt` newer than the repo's `last_checked` (re-queue for updated context)

#### 5b. Route

Read the routing ladder and apply it. Resolve its path from `${CLAUDE_PLUGIN_ROOT}` (set by the
harness when this skill runs) — `${CLAUDE_PLUGIN_ROOT}/references/routing-ladder.md` — falling back
to the directory containing this skill if the env var is unset
(`{this-skill-dir}/../../references/routing-ladder.md`). **Do not use a bare relative path:** the
cron runs from `$HOME`, where `references/…` does not exist.

Apply it with:
- `ticket.title` = issue title, `ticket.body` = issue body
- `ticket.labels` = the issue's label names, `ticket.components` = empty
- `ticket.owner` / `ticket.repo` = the repo key from Phase 1
- the Tier 0 candidate set = this repo's `watchers` from `repo_query_map`

The ladder returns either a routed slug with a `routing_method` (and `routing_rationale` when the
method is `inferred`), or `_unrouted` with `matched_projects`.

#### 5c. Create Queue Items Based on the Ladder's Result

**Routed** — create a file in `~/.local/share/engineer-agent/queue/incoming/` with `project: "{slug}"` and the `routing_method` the ladder returned, then proceed to generate a draft (see Step 6).

**Unrouted** — create a file in `~/.local/share/engineer-agent/queue/incoming/` with:
```yaml
project: "_unrouted"
matched_projects: ["slug-a", "slug-b"]   # [] if nothing watches this repo
```

Do NOT generate a draft. The item stays in `incoming/` until the user assigns a project via `/engineer-agent review-queue`.

#### Queue Item Format

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
project: "{slug_or__unrouted}"
ticket_key: "#{number}"
github_labels: ["{label1}", "{label2}"]
routing_method: "{single-candidate|prefix|filters|keyword|inferred}"
routing_rationale: "{one line}"            # only when routing_method is "inferred"
matched_projects: ["{slug1}", "{slug2}"]   # only for _unrouted items
---

## Context

**Ticket:** #{number} — {issue_title}
**Status:** Open
**Priority:** {mapped_priority}
**Project:** {slug or "_unrouted"}
**Labels:** {comma-separated list or "none"}
**Routing:** {routing_method}{" — " + routing_rationale if inferred}
**URL:** {issue_url}

### Description
{issue_body}

### Acceptance Criteria
{extract from body if present, otherwise note "No explicit acceptance criteria"}
```

**Priority mapping:** GitHub Issues don't have built-in priority. Default to `normal`. If the issue has a label matching `priority:high` or `urgent` → `urgent`. If label matches `priority:low` → `low`.

### 6. Process Routed Items (Draft Generation)

For items with a resolved project (not `_unrouted`):

1. Read the issue details
2. Identify which repo this issue applies to from `projects.<project>.github.owner` and `repos`
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
