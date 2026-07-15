---
name: poll-slack
description: "Poll Slack channels for unanswered questions directed at the user. Use this skill when checking Slack for new questions to answer, or during an engineer-agent poll cycle."
version: 1.0.0
model: haiku
---

# Poll Slack for Questions

Check configured Slack channels for messages matching keywords that may need a response. Iterates over all projects that have Slack configured.

## Tools Needed

- `Bash` — run the [Spy](https://github.com/tomharris/spy) Slack CLI:
  - `spy read <channel> <count> --json -w <workspace>` — read recent messages in a channel
  - `spy thread <channel> <ts> --json -w <workspace>` — read thread context
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract the `projects` map and the optional
`agent.slack` block.

Resolve the Spy invocation settings:
- **Binary:** `agent.slack.bin` if set, otherwise `spy` (assumed on `PATH`).
- **Workspace** (resolved per project below): `projects.<slug>.slack.workspace` if set,
  otherwise `agent.slack.workspace`. Pass it as `-w <workspace>` on every `spy` call. If
  neither is set, omit `-w` and rely on Spy's own default — but note `spy` errors when
  multiple workspaces are signed in and no default is set.

### 2. Load Dedup State

Read `~/.local/share/engineer-agent/state/last-poll.yaml`. This contains per-project state under `projects.<slug>`.

### 3. Iterate Over Projects

For each project slug in the `projects` config map that has a `slack` section configured:

Extract `projects.<slug>.slack.channels`, `projects.<slug>.slack.keywords`, and `projects.<slug>.slack.ignore_bots`.

Load dedup state from `projects.<slug>.slack` in last-poll.yaml (use "0" as default timestamp if missing).

#### 3a. Search for Matching Messages

For each channel in the project's `slack.channels`:

1. Run `spy read <channel_id> 50 --json -w <workspace>` to get recent messages. Each
   message in the JSON has `ts`, `user_id`, `user_name`, `text`, `reply_count`, and
   `thread_ts`.

2. Filter messages:
   - Only messages containing at least one keyword from `slack.keywords`
   - Only messages with a Slack timestamp newer than `projects.<slug>.slack.last_checked_ts`
   - Exclude bot messages if `slack.ignore_bots` is true
   - Exclude messages that already have a reply from the configured user (check thread replies)
   - Exclude messages whose `source_id` (channel + timestamp) already exists in any queue file

3. For each matching message, read the thread context via
   `spy thread <channel_id> <ts> --json -w <workspace>` (use the message's `ts`, or its
   `thread_ts` if it is itself a reply) to understand the full conversation.

#### 3b. Assess Relevance

For each candidate message, use judgment to determine if it's actually a question directed at the user:
- Direct mentions or name references → likely relevant
- Keyword matches in general discussion → may be false positive
- Messages that are clearly rhetorical or already answered → skip

Only create queue items for messages that genuinely need a response.

#### 3c. Create Queue Items

For each relevant message, create a file in `~/.local/share/engineer-agent/queue/incoming/`:

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
project: "{slug}"
channel_id: "{channel_id}"
channel_name: "{channel_name}"
message_ts: "{msg_ts}"
author: "{sender_name}"
---

## Context

**Channel:** #{channel_name}
**From:** @{sender_name}
**Project:** {slug}
**Time:** {human_readable_time}

### Message
{full_message_text}

### Thread Context
{any preceding thread messages for context, if this is a thread reply}
```

#### 3d. Process Incoming Items

For each new item, invoke the **answer-slack** skill behavior to generate a draft answer and move to `drafts/`.

#### 3e. Update State

Update `projects.<slug>.slack.last_checked_ts` in `~/.local/share/engineer-agent/state/last-poll.yaml` to the highest message timestamp seen.

### 4. Report

Report: "Found N new Slack questions to answer across M projects."
