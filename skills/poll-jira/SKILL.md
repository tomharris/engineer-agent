---
name: poll-jira
description: "Poll Jira for new or updated tickets assigned to the user. Use this skill when checking Jira for work, or during an engineer-agent poll cycle."
version: 3.0.0
model: haiku
---

# Poll Jira for Assigned Tickets

Check Jira for tickets assigned to configured users that need implementation. Supports multiple Jira projects per engineer-agent project, with routing via `references/routing-ladder.md`.

## Tools Needed

- `mcp__atlassian__searchJiraIssuesUsingJql` — search for tickets by JQL
- `mcp__atlassian__getJiraIssue` — fetch individual ticket details
- `Read` — read config, state, and the routing ladder
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract the `projects` map and `agent.branch_prefix` (required — read the literal string from the yaml; do not assume a default. If missing or empty, stop and tell the user to set `agent.branch_prefix`).

### 2. Load Dedup State

Read `~/.local/share/engineer-agent/state/last-poll.yaml`. This contains:
- `jira_projects.<key>.last_checked` — per-Jira-project-key timestamps
- `projects.<slug>.jira.seen_tickets` — per-engineer-agent-project seen ticket lists

### 3. Normalize Jira Sources (Backward Compat)

For each project slug in the `projects` config map:

- Skip projects where `tracker` is explicitly set to something other than `"jira"` (e.g., `"github-issues"` or `"none"`)
- For projects without a `tracker` field, proceed only if a `jira` section exists
- Skip projects that have no `jira` section configured

Normalize the jira config for each project:
- If `jira.sources` (array) exists, use it as-is
- If `jira.project` (string) exists instead (legacy format), convert to: `sources: [{project: "<value>"}]` (catch-all, no component/label filters)
- Extract `jira.assignee` and `jira.statuses` (shared across all sources for that project)

### 4. Phase 1 — Collect (Deduplicated Jira Queries)

Build a **deduplicated map** of Jira project keys across all engineer-agent projects:

```
jira_query_map = {}
For each engineer-agent project (slug, config):
  For each source in config.jira.sources:
    jira_key = source.project
    If jira_key not in jira_query_map:
      jira_query_map[jira_key] = { assignees: set(), statuses: set(), watchers: [] }
    jira_query_map[jira_key].assignees.add(config.jira.assignee)
    jira_query_map[jira_key].statuses.update(config.jira.statuses)
    jira_query_map[jira_key].watchers.append({ slug, source })
```

For each unique Jira project key in the map:

1. Look up `jira_projects.<key>.last_checked` from state (default: `"1970-01-01T00:00:00Z"` if missing, or fall back to the earliest `projects.<slug>.jira.last_checked` for backward compat)
2. Build ONE JQL query using the union of all assignees and statuses:
   ```
   project = {jira_key} AND assignee IN ({all_assignees}) AND status IN ({all_statuses}) AND updated > "{last_checked}"
   ```
3. Call `mcp__atlassian__searchJiraIssuesUsingJql` with the JQL query
4. For each ticket returned, call `mcp__atlassian__getJiraIssue` to fetch full details:
   - summary, description, status, priority
   - **components** (list of component names)
   - **labels** (list of label strings)
   - recent comments

### 5. Phase 2 — Route Each Ticket

For each ticket returned from Phase 1:

#### 5a. Check Global Dedup

- Exclude tickets whose `source_id` already exists in any queue file (check all queue directories via Glob)

Also skip tickets already in `projects.<slug>.jira.seen_tickets` for **every** watcher of this Jira project key (unless the ticket has new comments or status changes since the last poll).

#### 5b. Route

Read the routing ladder and apply it. Resolve its path from `${CLAUDE_PLUGIN_ROOT}` (set by the
harness when this skill runs) — `${CLAUDE_PLUGIN_ROOT}/references/routing-ladder.md` — falling back
to the directory containing this skill if the env var is unset
(`{this-skill-dir}/../../references/routing-ladder.md`). **Do not use a bare relative path:** the
cron runs from `$HOME`, where `references/…` does not exist.

Apply it with:
- `ticket.title` = ticket summary, `ticket.body` = ticket description
- `ticket.labels` = the ticket's labels, `ticket.components` = the ticket's components
- `ticket.jira_key` = the ticket's Jira project key
- the Tier 0 candidate set = this Jira project key's `watchers` from the query map

The ladder returns either a routed slug with a `routing_method` (and `routing_rationale` when the
method is `inferred`), or `_unrouted` with `matched_projects`.

#### 5c. Create Queue Items Based on the Ladder's Result

**Routed** — create a file in `~/.local/share/engineer-agent/queue/incoming/` with `project: "{slug}"` and the `routing_method` the ladder returned, then proceed to generate a draft (see Step 6).

**Unrouted** — create a file in `~/.local/share/engineer-agent/queue/incoming/` with:
```yaml
project: "_unrouted"
matched_projects: ["slug-a", "slug-b"]   # [] if no rules matched
```

Do NOT generate a draft. The item stays in `incoming/` until the user assigns a project via `/engineer-agent review-queue`.

#### Queue Item Format

**Filename:** `{YYYYMMDD-HHmmss}-ticket-{ticket_key}.md`

**Content:**
```yaml
---
type: ticket
source: jira
source_url: "{ticket_url_from_mcp_response}"
source_id: "{ticket_key}"
title: "{ticket_summary}"
priority: "{map_jira_priority}"
created_at: "{current_iso_timestamp}"
status: incoming
project: "{slug_or__unrouted}"
ticket_key: "{ticket_key}"
jira_status: "{ticket_status}"
jira_components: ["{component1}", "{component2}"]
jira_labels: ["{label1}", "{label2}"]
routing_method: "{single-candidate|prefix|filters|keyword|inferred}"
routing_rationale: "{one line}"            # only when routing_method is "inferred"
matched_projects: ["{slug1}", "{slug2}"]   # only for _unrouted items
---

## Context

**Ticket:** {ticket_key} — {ticket_summary}
**Status:** {ticket_status}
**Priority:** {ticket_priority}
**Components:** {comma-separated list or "none"}
**Labels:** {comma-separated list or "none"}
**Project:** {slug or "_unrouted"}
**Routing:** {routing_method}{" — " + routing_rationale if inferred}

### Description
{ticket_description}

### Acceptance Criteria
{extract from description if present, otherwise note "No explicit acceptance criteria"}

### Recent Comments
{last 3-5 comments if any}
```

Map Jira priorities: Highest/High -> `urgent`, Medium -> `normal`, Low/Lowest -> `low`.

### 6. Process Routed Items (Draft Generation)

For items with a resolved project (not `_unrouted`):

1. Read the ticket details
2. Identify which repo this ticket applies to from `projects.<project>.github.owner` and `repos`
3. Draft a brief implementation plan (which files to change, approach)
4. Move to `drafts/` with status `drafted`

The `## Draft Response` section for tickets:

```markdown
## Draft Response

### Implementation Plan

**Target repo:** {repo}
**Branch:** {branch_prefix}/{ticket_key}
**Approach:** {2-3 sentence summary}

### Files to Modify
- {file_path} — {what changes}

### Implementation Method
This ticket will be implemented iteratively in-session (plan → edit → test → fix), up to ~10 passes, done when all acceptance criteria are met and tests pass.

### Action on Approval
Approving this item implements the changes on a feature branch, then opens a draft PR.
```

### 7. Update State (always, even for zero items)

Run this for **every Jira project key queried**, regardless of how many tickets were found — a key
with no new tickets was still polled successfully and its cutoff must advance so the next poll
doesn't rescan the same window. This source *filters* on `last_checked` (the JQL uses
`updated > "{last_checked}"`), so a stale cutoff silently re-surfaces the same backlog every cycle.

Update `~/.local/share/engineer-agent/state/last-poll.yaml`:

1. For each Jira project key queried, update `jira_projects.<key>.last_checked` to the poll timestamp
   — use the caller-supplied timestamp verbatim if one was given (the cron passes one), otherwise the
   current ISO time
2. For each routed ticket, append the ticket key to `projects.<slug>.jira.seen_tickets`
3. For unrouted tickets, do NOT add to any project's `seen_tickets` (they'll be checked again on next poll until assigned)

### 8. Report

Report: "Found N new Jira tickets across M Jira projects. R routed, U unrouted."

If there are unrouted items: "Run `/engineer-agent review-queue` to assign unrouted tickets to projects."
