# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

engineer-agent — A Claude Code plugin that automates senior software engineer tasks with an approval-gated workflow. The agent drafts PR reviews, Slack answers, ticket implementations, doc reviews, and standup updates. The human reviews and approves via `/engineer-agent review-queue` before anything is posted externally.

## Plugin Structure

This repo IS the plugin.

- **Development**: `claude --plugin-dir /path/to/engineer-agent`
- **Permanent install**:
  1. `/plugin marketplace add tomharris/engineer-agent`
  2. `/plugin install engineer-agent`

```
.claude-plugin/plugin.json    — Plugin manifest
commands/                      — Slash commands (/engineer-agent <command>)
skills/                        — Auto-invoked skills by task type
scripts/                       — Cron and setup scripts
config/engineer.example.yaml   — Config template
```

Runtime data lives at the user level in `~/.claude/engineer-agent/`:
```
~/.claude/engineer-agent/
├── engineer.yaml              — User config (one file for all projects)
├── queue/
│   ├── incoming/              — Newly detected items
│   ├── drafts/                — Items with drafted responses
│   ├── completed/             — Approved and posted
│   └── rejected/              — Rejected with reason
└── state/
    └── last-poll.yaml         — Dedup timestamps and seen IDs (per project + per Jira project key)
```

## Config Loading Pattern

Every skill and command that needs config should start by reading `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

The config has two top-level sections:
- `agent` — global settings (branch_prefix, max_pr_files, channels, cron interval)
- `projects` — a map of project slugs to per-project integration config

To find config for a specific project, look up `projects.<slug>`. Each project entry has `path`, `tracker`, `github`, `slack`, `jira`, `slite`, and `qa` subsections. The `tracker` field (`"jira"` | `"github-issues"` | `"none"`) determines which ticket tracker a project uses. If absent, it's inferred: `jira` section present → `"jira"`, `github.issues` section present → `"github-issues"`, neither → `"none"`.

### Jira Multi-Source Config

The `jira` section supports watching multiple Jira projects per engineer-agent project via a `sources` array:

```yaml
jira:
  sources:
    - project: "ENG"
      components: ["api"]    # optional: filter by Jira component
      labels: ["backend"]    # optional: filter by Jira label
    - project: "PLAT"
  assignee: "me@example.com"
  statuses: ["To Do", "In Progress"]
```

- Each source has a required `project` key and optional `components`/`labels` filters
- A source with no filters is a catch-all for that Jira project
- `assignee` and `statuses` are shared across all sources
- **Backward compat:** `jira.project` (string) is treated as `sources: [{project: <value>}]`
- Multiple engineer-agent projects can watch the same Jira project with different component/label filters (N:M mapping)
- Tickets matching zero or multiple projects are created as `_unrouted` for manual assignment

## Queue File Format

Items enter the queue either via polling (`/engineer-agent poll` or the cron) or manually (`/engineer-agent add-ticket <ref>`). Both paths produce identically-shaped queue files.

Files move through: `~/.claude/engineer-agent/queue/incoming/` → `queue/drafts/` → `queue/completed/` or `queue/rejected/`

Filename: `{YYYYMMDD-HHmmss}-{type}-{short-id}.md`

YAML frontmatter fields:
- `type`: pr-review | slack-question | ticket | doc-review | spec-refinement | design-doc | ticket-plan | ticket-refinement | gap-audit | qa-test-plan
- `source`: github | slack | jira | slite
- `source_url`: URL to the original item
- `source_id`: Unique identifier (e.g. "org/repo#142")
- `title`: Short description
- `priority`: urgent | normal | low
- `created_at`: ISO 8601 timestamp
- `status`: incoming | drafted | completed | rejected
- `project`: Project slug matching a key in the `projects` config map, or `_unrouted` for tickets that could not be automatically routed
- `matched_projects`: (only for `_unrouted` items) array of project slugs that matched, or empty array if no rules matched
- `jira_components`: (Jira tickets only) array of Jira component names on the ticket
- `jira_labels`: (Jira tickets only) array of Jira labels on the ticket

Body sections:
- `## Context` — metadata about the work item
- `## Draft Response` — filled by the processing skill

## Available Integrations

- GitHub (PRs and Issues): `gh` CLI via Bash (requires `gh auth login`)
- Slack: `mcp__claude_ai_Slack__*` tools
- Jira: `mcp__atlassian__*` tools (optional — either Jira or GitHub Issues per project)
- Slite: `mcp__slite__*` tools

## Documentation Maintenance

When any command, skill, config option, queue format, or integration is added, changed, or removed, check both `CLAUDE.md` and `README.md` for needed updates. These two files must stay in sync with each other and with the actual plugin behavior.
