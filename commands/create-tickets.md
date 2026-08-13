---
description: "Break a design doc (Slite or local file) into phased implementation tickets"
model: sonnet
argument-hint: "<slite-url-or-id|path> [--project <slug>]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion",
  "mcp__slite__get-note", "mcp__slite__get-note-children",
  "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__getJiraIssue"]
---

# Engineer Agent: Create Tickets

Break a design doc into phased implementation tickets with dependencies.

## Arguments

- `$ARGUMENTS` should contain the design doc source: a Slite document URL, a bare Slite document
  ID, or a path to a local file
- `$ARGUMENTS` may contain `--project <slug>` to associate with a specific project

```
/engineer-agent create-tickets https://example.slite.com/p/note/abc123
/engineer-agent create-tickets docs/design/checkout-v2.md
/engineer-agent create-tickets ~/Documents/design.pdf --project my-api
```

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

### 2. Determine Project

If `--project <slug>` is specified, use that slug. Otherwise, try to infer the project from the current working directory by matching against `projects.<slug>.path` values in config. If no match, ask the user which project this ticket plan belongs to (list available slugs).

### 3. Classify the Source

Classify the positional argument in `$ARGUMENTS` (ignoring `--project <slug>`). Check in this
order — the first match wins:

- **Slite URL** — `https://…/api/s/note/…` or `https://…/p/note/…` → extract the note ID from the
  path. Source type is `slite`.
- **Local path** — a `file://` URI, an absolute path (`/…`), a `~/`-relative path, or a
  cwd-relative path. Treat the argument as a local path when it is not an `http(s)://` URL **and**
  it either contains a `/` or ends in a file extension. Source type is `file`.
- **Bare Slite ID** — any other non-empty argument. Source type is `slite`.
- **Nothing** — ask the user for a Slite doc URL/ID or a local file path.

### 4. Fetch the Design Doc

**For a Slite source:** call `mcp__slite__get-note` with the extracted document ID to retrieve the
design doc content and title.

**For a local file source:** resolve the argument to an absolute path — strip a leading `file://`,
expand a leading `~`, and resolve a relative path against the current working directory. Verify the
file exists; if it does not, report the resolved path and stop.

Read the file with the `Read` tool. Any file `Read` can open is acceptable — markdown, plain text,
or PDF. For a PDF longer than 10 pages, page through it with the `pages` parameter until the whole
document has been read.

Derive the title from the first `# ` heading in the content. If the file has no `# ` heading, fall
back to the filename stem with `-` and `_` replaced by spaces.

If the fetch or read fails, report the error and stop.

### 4a. Resolve Source Identifiers

Derive these values from the source type; every later step and the frontmatter template below refer
to them by name:

| Value | Slite source | Local file source |
|---|---|---|
| `{source}` | `slite` | `file` |
| `{doc_id}` | the Slite note ID | the absolute file path |
| `{source_url}` | the Slite doc URL | `file://{absolute path}` |
| `{source_id}` | `slite:{doc_id}` | `file:{doc_id}` |
| `{doc_id_short}` | first 8 chars of the note ID | filename stem, lowercased, each run of non-alphanumeric characters replaced by `-`, first 8 chars |

### 5. Check for Prior Design Doc

Search `~/.local/share/engineer-agent/queue/completed/` for files matching `*-design-doc-*.md`. Read each file's frontmatter and check if its `source_id` matches the `{source_id}` resolved in step 4a.

If found, read the completed design doc's `## Draft Response` section to include as enriched context (this may contain additional detail beyond what's in the source doc).

### 6. Check Jira for Existing Tickets

If `projects.<slug>.jira.project` is set, search Jira for existing tickets related to this feature area using `mcp__atlassian__searchJiraIssuesUsingJql`. Use keywords from the design doc title to find potential duplicates or related work.

### 7. Create Queue Item

Generate a timestamp and write a new file to `~/.local/share/engineer-agent/queue/incoming/`:

Filename: `{YYYYMMDD-HHmmss}-ticket-plan-{doc_id_short}.md`

All `{source*}` and `{doc_id*}` placeholders below are the values resolved in step 4a.

```yaml
---
type: ticket-plan
source: {source}
source_url: "{source_url}"
source_id: "{source_id}"
title: "Tickets: {design_doc_title}"
priority: normal
created_at: "{ISO 8601 timestamp}"
status: incoming
project: "{slug}"
doc_id: "{doc_id}"
design_doc_id: "{source_id}"
jira_project: "{projects.<slug>.jira.project}"
---

## Context

**Design Doc Title:** {title}
**Source:** {source_url}
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
