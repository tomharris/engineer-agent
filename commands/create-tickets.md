---
description: "Break a Slite design doc into phased implementation tickets"
argument-hint: "<slite-url-or-id>"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion",
  "mcp__slite__get-note", "mcp__slite__get-note-children",
  "mcp__plugin_github_github__get_file_contents", "mcp__plugin_github_github__search_code",
  "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__getJiraIssue"]
---

# Engineer Agent: Create Tickets

Break a design doc into phased implementation tickets with dependencies.

## Arguments

- `$ARGUMENTS` should contain a Slite document URL or bare document ID

## Steps

### 1. Load Config

Read `.claude/engineer-agent/engineer.yaml`. If missing, tell the user to copy `engineer.example.yaml` and stop.

### 2. Parse Arguments

Extract the Slite document ID from `$ARGUMENTS`:
- If a full URL (e.g. `https://futuresinc.slite.com/api/s/note/...` or `https://futuresinc.slite.com/p/note/...`), extract the note ID from the path
- If a bare ID, use it directly
- If no argument provided, ask the user for the Slite doc URL or ID

### 3. Fetch the Design Doc

Call `mcp__slite__get-note` with the extracted document ID to retrieve the design doc content and title.

If the fetch fails, report the error and stop.

### 4. Check for Prior Design Doc

Search `.claude/engineer-agent/queue/completed/` for files matching `*-design-doc-*.md`. Read each file's frontmatter and check if `source_id` matches `slite:{doc_id}`.

If found, read the completed design doc's `## Draft Response` section to include as enriched context (this may contain additional detail beyond what's in Slite).

### 5. Check Jira for Existing Tickets

If `config.jira.project` is set, search Jira for existing tickets related to this feature area using `mcp__atlassian__searchJiraIssuesUsingJql`. Use keywords from the design doc title to find potential duplicates or related work.

### 6. Create Queue Item

Generate a timestamp and write a new file to `.claude/engineer-agent/queue/incoming/`:

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
doc_id: "{doc_id}"
design_doc_id: "slite:{doc_id}"
jira_project: "{config.jira.project}"
---

## Context

**Design Doc Title:** {title}
**Source:** {url}
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

### 7. Process with Skill

Follow the `create-tickets` skill behavior to research the codebase and generate the phased ticket breakdown in the `## Draft Response` section.

### 8. Report

Count the number of tickets and phases generated in the draft response.

Report: "Ticket plan drafted: {N} tickets across {M} phases. Run `/engineer review-queue` to review."
