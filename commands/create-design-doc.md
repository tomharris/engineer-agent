---
description: "Create a design doc from a refined PM feature spec in Slite"
argument-hint: "<slite-url-or-id>"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion",
  "mcp__slite__get-note", "mcp__slite__get-note-children", "mcp__slite__create-note",
  "mcp__plugin_github_github__get_file_contents", "mcp__plugin_github_github__search_code",
  "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__getJiraIssue"]
---

# Engineer Agent: Create Design Doc

Generate a structured engineering design doc from a PM's feature spec in Slite.

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

### 4. Check for Prior Refinement

Search `${CLAUDE_PLUGIN_ROOT}/queue/completed/` for files matching `*-spec-refinement-*.md`. Read each file's frontmatter and check if `source_id` matches `slite:{doc_id}`.

If found, read the completed refinement's `## Draft Response` section to pull in the Q&A context (especially the filled-in `_Answer:_` fields).

### 5. Check for Template

If `config.slite.design_doc_template` is set (non-empty), fetch that Slite doc via `mcp__slite__get-note` and use its heading structure as the design doc template.

### 6. Create Queue Item

Generate a timestamp and write a new file to `${CLAUDE_PLUGIN_ROOT}/queue/incoming/`:

Filename: `{YYYYMMDD-HHmmss}-design-doc-{doc_id_short}.md` (use first 8 chars of doc ID)

```yaml
---
type: design-doc
source: slite
source_url: "{slite_doc_url}"
source_id: "slite:{doc_id}"
title: "Design: {spec_title}"
priority: normal
created_at: "{ISO 8601 timestamp}"
status: incoming
doc_id: "{doc_id}"
spec_refinement_id: "{source_id of completed spec-refinement, if found}"
---

## Context

**Spec Title:** {title}
**Source:** {url}
**Fetched:** {timestamp}
**Prior Refinement:** {link to completed refinement or "None"}

{full spec content}

{if refinement exists, include:}
### Refinement Q&A
{Q&A content from completed spec-refinement}

## Draft Response

_(to be filled by create-design-doc skill)_
```

### 7. Process with Skill

Follow the `create-design-doc` skill behavior to research the codebase and generate the full design doc content in the `## Draft Response` section.

### 8. Report

Report: "Design doc drafted. Run `/engineer review-queue` to review."
