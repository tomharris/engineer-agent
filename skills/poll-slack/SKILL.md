---
name: poll-slack
description: "Poll Slack channels for unanswered questions directed at the user. Use this skill when checking Slack for new questions to answer, or during an engineer-agent poll cycle."
version: 1.0.0
model: haiku
---

# Poll Slack for Questions

Check configured Slack channels for messages matching keywords that may need a response. Iterates over all projects that have Slack configured.

## Tools Needed

- `Bash` — run the effective Slack CLI (`spy`, or `scripts/slack-mcp.sh` when
  `agent.slack.method: mcp-proxy` — see §1 for resolution; both share this interface):
  - `<slack> read <channel> <count> --json -w <workspace>` — read recent messages in a channel
  - `<slack> thread <channel> <ts> --json -w <workspace>` — read thread context
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract the `projects` map and the optional
`agent.slack` block.

Resolve the Slack invocation settings:
- **Binary (the effective Slack CLI):** if `agent.slack.method` is `mcp-proxy`, use the
  bundled MCP-proxy client `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh` (fall back to a path
  relative to this skill's directory if the env var is unset). Otherwise (method `spy` or
  unset) use `agent.slack.bin` if set, else `spy` (assumed on `PATH`). The MCP-proxy client is
  subcommand-compatible with `spy` (`read`/`thread`/`send`/`auth`, `--json`, `-w`), so every
  invocation below is written the same way regardless of method.
- **Workspace** (resolved per project below): `projects.<slug>.slack.workspace` if set,
  otherwise `agent.slack.workspace`. Pass it as `-w <workspace>` on every call. If neither is
  set, omit `-w` and rely on the backend's own default — note `spy` errors when multiple
  workspaces are signed in and no default is set (the MCP-proxy client ignores `-w`, since the
  connector is bound to its authorized workspace).
- **Clean skip on expiry (mcp-proxy only):** the client exits `75` and prints
  `{"skipped": true, ...}` when Claude Code's Keychain token is missing or expired. Treat that
  as a *skipped* Slack source for this poll (not an error) — the token re-auths on its own and
  the next poll picks up. Leave `last_checked_ts` unchanged, exactly as for a zero-message poll.

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

**Zero-message polls are the exception to the "always advance the cutoff" rule.** Unlike the other
sources, `last_checked_ts` is a Slack message timestamp, not a wall clock — when no messages were
read there is no higher timestamp to advance to, so **leave it unchanged**. This is a *successful*
poll that happened to find nothing, not a failure; do not stamp the current time here (a wall-clock
value would skip every message posted before it).

### 4. Report

Report: "Found N new Slack questions to answer across M projects."
