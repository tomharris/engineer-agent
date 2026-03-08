# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

engineer-agent — A Claude Code plugin that automates senior software engineer tasks with an approval-gated workflow. The agent drafts PR reviews, Slack answers, ticket implementations, doc reviews, and standup updates. The human reviews and approves via `/engineer review-queue` before anything is posted externally.

## Plugin Structure

This repo IS the plugin. For development, run `claude --plugin-dir /path/to/engineer-agent`. For permanent install, use `/plugin marketplace add /path/to/engineer-agent` then `/plugin install engineer-agent`.

```
.claude-plugin/plugin.json    — Plugin manifest
commands/                      — Slash commands (/engineer <command>)
skills/                        — Auto-invoked skills by task type
scripts/                       — Cron and setup scripts
config/engineer.yaml           — User config (gitignored, copy from .example)
queue/                         — File-based work queue (gitignored)
state/                         — Poll state and dedup tracking (gitignored)
```

## Config Loading Pattern

Every skill and command that needs config should start by reading `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. If missing, tell the user to copy `engineer.example.yaml` and stop.

## Queue File Format

Files move through: `queue/incoming/` → `queue/drafts/` → `queue/completed/` or `queue/rejected/`

Filename: `{YYYYMMDD-HHmmss}-{type}-{short-id}.md`

YAML frontmatter fields:
- `type`: pr-review | slack-question | ticket | doc-review | spec-refinement | design-doc
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

## Available MCP Integrations

- GitHub: `mcp__plugin_github_github__*` tools
- Slack: `mcp__claude_ai_Slack__*` tools
- Jira: `mcp__atlassian__*` tools
- Slite: `mcp__slite__*` tools
