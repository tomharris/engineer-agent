---
description: "Generate and review a daily activity digest"
argument-hint: "[--days N]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion", "mcp__claude_ai_Slack__slack_send_message"]
---

# Engineer Agent: Daily Digest

Generate a digest of all engineer-agent activity.

## Arguments

- `$ARGUMENTS` may contain `--days N` to cover the last N days instead of just today (default: 1)

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

### 2. Generate Digest

Follow the `generate-digest` skill behavior to scan queue directories and create a digest draft. The digest covers all projects.

If `--days N` was specified, scan items from the last N days instead of just today.

### 3. Present for Review

Display the generated digest to the user and ask:
- **Approve** — Post to the configured digest Slack channel via `mcp__claude_ai_Slack__slack_send_message`
- **Edit** — Modify the digest content inline, then re-present
- **Skip** — Don't post, leave the draft in the queue

### 4. Post if Approved

If approved, post the digest message to the channel specified in `agent.digest_channel` config, then move the queue item to `completed/`.
