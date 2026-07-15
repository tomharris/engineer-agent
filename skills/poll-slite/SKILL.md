---
name: poll-slite
description: "Poll Slite for design documents tagged for review. Use this skill when checking Slite for docs to review, or during an engineer-agent poll cycle."
version: 1.0.0
model: haiku
---

# Poll Slite for Docs Needing Review

Check Slite for documents tagged with review labels. Iterates over all projects that have Slite configured.

## Tools Needed

- `mcp__slite__search-notes` — search for documents
- `mcp__slite__get-note` — fetch full document content
- `mcp__slite__get-note-children` — navigate document tree
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract the `projects` map.

### 2. Load Dedup State

Read `~/.local/share/engineer-agent/state/last-poll.yaml`. This contains per-project state under `projects.<slug>`.

### 3. Iterate Over Projects

For each project slug in the `projects` config map that has a `slite` section configured:

Extract `projects.<slug>.slite.doc_labels`.

Load dedup state from `projects.<slug>.slite` in last-poll.yaml (use epoch defaults if missing).

#### 3a. Query Slite

Call `mcp__slite__search-notes` to search for documents.

Filter results for documents that:
- Have labels matching `slite.doc_labels` (e.g., "needs-review")
- Were updated after `projects.<slug>.slite.last_checked`
- Are not already in `projects.<slug>.slite.seen_docs`
- Don't already exist in any queue directory

For each matching document, call `mcp__slite__get-note` with the document ID to fetch the full content.

#### 3b. Create Queue Items

For each new document, create a file in `~/.local/share/engineer-agent/queue/incoming/`:

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
project: "{slug}"
doc_id: "{doc_id}"
---

## Context

**Document:** {doc_title}
**URL:** {doc_url}
**Project:** {slug}
**Last updated:** {updated_at}
**Author:** {author_name}

### Document Content
{full document text from mcp__slite__get-note}
```

#### 3c. Process Incoming Items

For each new item, invoke the **review-doc** skill behavior to generate review comments and move to `drafts/`.

#### 3d. Update State

Update `projects.<slug>.slite.last_checked` and append new doc IDs to `projects.<slug>.slite.seen_docs` in `~/.local/share/engineer-agent/state/last-poll.yaml`.

### 4. Report

Report: "Found N new Slite docs for review across M projects."
