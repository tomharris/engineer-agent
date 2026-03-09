# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

engineer-agent — A Claude Code plugin that automates senior software engineer tasks with an approval-gated workflow. The agent drafts PR reviews, Slack answers, ticket implementations, doc reviews, and standup updates. The human reviews and approves via `/engineer review-queue` before anything is posted externally.

## Plugin Structure

This repo IS the plugin.

- **Development**: `claude --plugin-dir /path/to/engineer-agent`
- **Permanent install**:
  1. `/plugin marketplace add tomharris/engineer-agent`
  2. `/plugin install engineer-agent`

```
.claude-plugin/plugin.json    — Plugin manifest
commands/                      — Slash commands (/engineer <command>)
skills/                        — Auto-invoked skills by task type
scripts/                       — Cron and setup scripts
config/engineer.example.yaml   — Config template (copy to project)
```

Runtime data lives in each project at `.claude/engineer-agent/`:
```
<project>/.claude/engineer-agent/
├── engineer.yaml              — User config (copied from config/engineer.example.yaml)
├── queue/
│   ├── incoming/              — Newly detected items
│   ├── drafts/                — Items with drafted responses
│   ├── completed/             — Approved and posted
│   └── rejected/              — Rejected with reason
└── state/
    └── last-poll.yaml         — Dedup timestamps and seen IDs
```

## Config Loading Pattern

Every skill and command that needs config should start by reading `.claude/engineer-agent/engineer.yaml`. If missing, tell the user to copy `engineer.example.yaml` from the plugin and stop.

## Queue File Format

Files move through: `.claude/engineer-agent/queue/incoming/` → `queue/drafts/` → `queue/completed/` or `queue/rejected/`

Filename: `{YYYYMMDD-HHmmss}-{type}-{short-id}.md`

YAML frontmatter fields:
- `type`: pr-review | slack-question | ticket | doc-review | spec-refinement | design-doc | ticket-plan
- `source`: github | slack | jira | slite
- `source_url`: URL to the original item
- `source_id`: Unique identifier (e.g. "org/repo#142")
- `title`: Short description
- `priority`: urgent | normal | low
- `created_at`: ISO 8601 timestamp
- `status`: incoming | drafted | completed | rejected

Body sections:
- `## Context` — metadata about the work item
- `## Draft Response` — filled by the processing skill

## Available Integrations

- GitHub: `gh` CLI via Bash (requires `gh auth login`)
- Slack: `mcp__claude_ai_Slack__*` tools
- Jira: `mcp__atlassian__*` tools
- Slite: `mcp__slite__*` tools
