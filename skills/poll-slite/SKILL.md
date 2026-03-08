---
name: poll-slite
description: "Poll Slite for design documents tagged for review. Use this skill when checking Slite for docs to review, or during an engineer-agent poll cycle."
version: 1.0.0
---

# Poll Slite for Docs Needing Review

Check Slite for documents tagged with review labels.

## Tools Needed

- `Bash` — curl to Slite API
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. Extract `slite.api_token_env` and `slite.doc_labels`.

Get the API token from the environment variable named in `slite.api_token_env`.

### 2. Load Dedup State

Read `${CLAUDE_PLUGIN_ROOT}/state/last-poll.yaml`. Note `slite.last_checked` and `slite.seen_docs`.

### 3. Query Slite API

Use Bash with curl to search for documents:

```bash
curl -s -H "Authorization: Bearer $SLITE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.slite.com/v1/notes?limit=20"
```

Filter results for documents that:
- Have labels matching `slite.doc_labels` (e.g., "needs-review")
- Were updated after `slite.last_checked`
- Are not already in `slite.seen_docs`
- Don't already exist in any queue directory

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
{full document text fetched via API}
```

### 5. Process Incoming Items

For each new item, invoke the **review-doc** skill behavior to generate review comments and move to `drafts/`.

### 6. Update State

Update `slite.last_checked` and append new doc IDs to `slite.seen_docs` in `state/last-poll.yaml`.

### 7. Report

Report: "Found N new Slite docs for review."
