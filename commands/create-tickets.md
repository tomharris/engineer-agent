---
description: "Break a Slite design doc into phased implementation tickets"
model: sonnet
argument-hint: "<slite-url-or-id> [--project <slug>]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion",
  "mcp__slite__get-note", "mcp__slite__get-note-children",
  "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__getJiraIssue"]
---

# Engineer Agent: Create Tickets

Break a design doc into phased implementation tickets with dependencies.

## Arguments

- `$ARGUMENTS` should contain a Slite document URL or bare document ID
- `$ARGUMENTS` may contain `--project <slug>` to associate with a specific project

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

### 2. Determine Project

If `--project <slug>` is specified, use that slug. Otherwise, try to infer the project from the current working directory by matching against `projects.<slug>.path` values in config. If no match, ask the user which project this ticket plan belongs to (list available slugs).

### 3. Parse Arguments

Extract the Slite document ID from `$ARGUMENTS`:
- If a full URL (e.g. `https://example.slite.com/api/s/note/...` or `https://example.slite.com/p/note/...`), extract the note ID from the path
- If a bare ID, use it directly
- If no argument provided, ask the user for the Slite doc URL or ID

### 4. Fetch the Design Doc

Call `mcp__slite__get-note` with the extracted document ID to retrieve the design doc content and title.

If the fetch fails, report the error and stop.

### 5. Check for Prior Design Doc

Search `~/.claude/engineer-agent/queue/completed/` for files matching `*-design-doc-*.md`. Read each file's frontmatter and check if `source_id` matches `slite:{doc_id}`.

If found, read the completed design doc's `## Draft Response` section to include as enriched context (this may contain additional detail beyond what's in Slite).

### 6. Check Jira for Existing Tickets

If `projects.<slug>.jira.project` is set, search Jira for existing tickets related to this feature area using `mcp__atlassian__searchJiraIssuesUsingJql`. Use keywords from the design doc title to find potential duplicates or related work.

### 7. Create Queue Item

Generate a timestamp and write a new file to `~/.claude/engineer-agent/queue/incoming/`:

Filename: `{YYYYMMDD-HHmmss}-ticket-plan-{doc_id_short}.md` (use first 8 chars of doc ID)

```yaml
---
type: ticket-plan
source: slite
source_url: "{slite_doc_url}"
source_id: "slite:{doc_id}"
title: "Tickets: {design_doc_title}"
priority: normal
created_at: "{ISO 8601 timestamp}"
status: incoming
project: "{slug}"
doc_id: "{doc_id}"
design_doc_id: "slite:{doc_id}"
jira_project: "{projects.<slug>.jira.project}"
---

## Context

**Design Doc Title:** {title}
**Source:** {url}
**Project:** {slug}
**Fetched:** {timestamp}
**Prior Design Doc in Queue:** {link to completed design-doc or "None"}
**Jira Project:** {jira_project or "Not configured"}

{full design doc content}

{if completed design-doc queue item exists, include:}
### Queue Design Doc Context
{Draft Response content from completed design-doc}

{if existing Jira tickets found, include:}
### Existing Related Tickets
{list of related Jira tickets with keys and titles}

## Draft Response

_(to be filled by create-tickets skill)_
```

### 8. Process with Skill

Follow the `create-tickets` skill behavior to research the codebase and generate the phased ticket breakdown in the `## Draft Response` section.

### 9. Report

Count the number of tickets and phases generated in the draft response.

Report: "Ticket plan drafted for project '{slug}': {N} tickets across {M} phases. Run `/engineer-agent review-queue` to review."
