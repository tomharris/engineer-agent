---
name: poll-slite
description: "Poll Slite for design documents tagged for review. Use this skill when checking Slite for docs to review, or during an engineer-agent poll cycle."
version: 1.0.0
---

# Poll Slite for Docs Needing Review

Check Slite for documents tagged with review labels.

## Tools Needed

- `mcp__slite__search-notes` — search for documents
- `mcp__slite__get-note` — fetch full document content
- `mcp__slite__get-note-children` — navigate document tree
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. Extract `slite.doc_labels`.

### 2. Load Dedup State

Read `${CLAUDE_PLUGIN_ROOT}/state/last-poll.yaml`. Note `slite.last_checked` and `slite.seen_docs`.

### 3. Query Slite

Call `mcp__slite__search-notes` to search for documents.

Filter results for documents that:
- Have labels matching `slite.doc_labels` (e.g., "needs-review")
- Were updated after `slite.last_checked`
- Are not already in `slite.seen_docs`
- Don't already exist in any queue directory

For each matching document, call `mcp__slite__get-note` with the document ID to fetch the full content.

### 4. Create Queue Items

For each new document, create a file in `${CLAUDE_PLUGIN_ROOT}/queue/incoming/`:

**Filename:** `{YYYYMMDD-HHmmss}-doc-review-{doc_id_short}.md`

**Content:**
```yaml
---
type: doc-review
source: slite
source_url: "{doc_url}"
source_id: "slite:{doc_id}"
title: "{doc_title}"
priority: normal
created_at: "{current_iso_timestamp}"
status: incoming
doc_id: "{doc_id}"
---

## Context

**Document:** {doc_title}
**URL:** {doc_url}
**Last updated:** {updated_at}
**Author:** {author_name}

### Document Content
{full document text from mcp__slite__get-note}
```

### 5. Process Incoming Items

For each new item, invoke the **review-doc** skill behavior to generate review comments and move to `drafts/`.

### 6. Update State

Update `slite.last_checked` and append new doc IDs to `slite.seen_docs` in `state/last-poll.yaml`.

### 7. Report

Report: "Found N new Slite docs for review."
