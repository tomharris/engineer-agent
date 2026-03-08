---
name: poll-slack
description: "Poll Slack channels for unanswered questions directed at the user. Use this skill when checking Slack for new questions to answer, or during an engineer-agent poll cycle."
version: 1.0.0
---

# Poll Slack for Questions

Check configured Slack channels for messages matching keywords that may need a response.

## Tools Needed

- `mcp__claude_ai_Slack__slack_read_channel` — read recent messages in a channel
- `mcp__claude_ai_Slack__slack_read_thread` — read thread context
- `mcp__claude_ai_Slack__slack_search_public_and_private` — search for keyword matches
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. Extract `slack.channels`, `slack.keywords`, and `slack.ignore_bots`.

### 2. Load Dedup State

Read `${CLAUDE_PLUGIN_ROOT}/state/last-poll.yaml`. Note `slack.last_checked_ts` (a Slack message timestamp string).

### 3. Search for Matching Messages

For each channel in `slack.channels`:

1. Call `mcp__claude_ai_Slack__slack_read_channel` with the channel ID to get recent messages.

2. Filter messages:
   - Only messages containing at least one keyword from `slack.keywords`
   - Only messages with a Slack timestamp newer than `slack.last_checked_ts`
   - Exclude bot messages if `slack.ignore_bots` is true
   - Exclude messages that already have a reply from the configured user (check thread replies)
   - Exclude messages whose `source_id` (channel + timestamp) already exists in any queue file

3. For each matching message, read the thread context via `mcp__claude_ai_Slack__slack_read_thread` to understand the full conversation.

### 4. Assess Relevance

For each candidate message, use judgment to determine if it's actually a question directed at the user:
- Direct mentions or name references → likely relevant
- Keyword matches in general discussion → may be false positive
- Messages that are clearly rhetorical or already answered → skip

Only create queue items for messages that genuinely need a response.

### 5. Create Queue Items

For each relevant message, create a file in `${CLAUDE_PLUGIN_ROOT}/queue/incoming/`:

**Filename:** `{YYYYMMDD-HHmmss}-slack-question-{channel_id}-{msg_ts}.md`

Replace dots in `msg_ts` with dashes for the filename.

**Content:**
```yaml
---
type: slack-question
source: slack
source_url: "{link_to_message}"
source_id: "{channel_id}:{msg_ts}"
title: "{first 60 chars of message}"
priority: normal
created_at: "{current_iso_timestamp}"
status: incoming
channel_id: "{channel_id}"
channel_name: "{channel_name}"
message_ts: "{msg_ts}"
author: "{sender_name}"
---

## Context

**Channel:** #{channel_name}
**From:** @{sender_name}
**Time:** {human_readable_time}

### Message
{full_message_text}

### Thread Context
{any preceding thread messages for context, if this is a thread reply}
```

### 6. Process Incoming Items

For each new item, invoke the **answer-slack** skill behavior to generate a draft answer and move to `drafts/`.

### 7. Update State

Update `slack.last_checked_ts` in `${CLAUDE_PLUGIN_ROOT}/state/last-poll.yaml` to the highest message timestamp seen.

### 8. Report

Report: "Found N new Slack questions to answer."
