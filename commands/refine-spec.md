---
description: "Analyze a PM feature spec from Slite and draft clarifying questions"
argument-hint: "<slite-url-or-id>"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion",
  "mcp__slite__get-note", "mcp__slite__get-note-children",
  "mcp__plugin_github_github__get_file_contents", "mcp__plugin_github_github__search_code",
  "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__getJiraIssue"]
---

# Engineer Agent: Refine Spec

Analyze a PM's feature spec from Slite and draft structured clarifying questions.

## Arguments

- `$ARGUMENTS` should contain a Slite document URL or bare document ID

## Steps

### 1. Load Config

Read `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. If missing, tell the user to copy `engineer.example.yaml` and stop.

### 2. Parse Arguments

Extract the Slite document ID from `$ARGUMENTS`:
- If a full URL (e.g. `https://futuresinc.slite.com/api/s/note/...` or `https://futuresinc.slite.com/p/note/...`), extract the note ID from the path
- If a bare ID, use it directly
- If no argument provided, ask the user for the Slite doc URL or ID

### 3. Fetch the Spec

Call `mcp__slite__get-note` with the extracted document ID to retrieve the spec content and title.

If the fetch fails, report the error and stop.

### 4. Create Queue Item

Generate a timestamp and write a new file to `${CLAUDE_PLUGIN_ROOT}/queue/incoming/`:

Filename: `{YYYYMMDD-HHmmss}-spec-refinement-{doc_id_short}.md` (use first 8 chars of doc ID)

```yaml
---
type: spec-refinement
source: slite
source_url: "{slite_doc_url}"
source_id: "slite:{doc_id}"
title: "Refine: {spec_title}"
priority: normal
created_at: "{ISO 8601 timestamp}"
status: incoming
doc_id: "{doc_id}"
---

## Context

**Spec Title:** {title}
**Source:** {url}
**Fetched:** {timestamp}

{full spec content}

## Draft Response

_(to be filled by refine-spec skill)_
```

### 5. Process with Skill

Follow the `refine-spec` skill behavior to analyze the spec and fill in the `## Draft Response` section with clarifying questions, suggested changes, feasibility notes, and related tickets.

### 6. Report

Report: "Spec refinement drafted. Run `/engineer review-queue` to review."
