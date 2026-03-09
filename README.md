# engineer-agent

A Claude Code plugin that automates senior software engineer tasks with an approval-gated workflow. The agent polls GitHub, Slack, Jira, and Slite for work, drafts responses, and queues everything for human review before posting externally.

## Features

- **PR Reviews** — Structured code reviews with severity levels (critical/important/suggestion)
- **Slack Q&A** — Drafts answers to questions in configured channels
- **Ticket Implementation** — Implements Jira tickets on feature branches, opens draft PRs
- **Doc Reviews** — Reviews Slite design documents with inline comments
- **Standup Generation** — Creates daily standup updates from activity history
- **Daily Digest** — Summarizes all agent activity with approval metrics

Everything goes through an approval queue — nothing is posted until you say so.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- **GitHub MCP integration** — for PR reviews and code search (`mcp__plugin_github_github__*`)
- **Slack MCP integration** — for channel polling and message posting (`mcp__claude_ai_Slack__*`)
- **Jira MCP integration** (optional) — for ticket polling and implementation (`mcp__atlassian__*`)
- **Slite MCP integration** (optional) — for document reviews (`mcp__slite__*`)

## Installation

```bash
# For development (loads plugin for this session only)
claude --plugin-dir /path/to/engineer-agent

# For permanent installation
# Inside a Claude Code session, run:
#   /plugin marketplace add /path/to/engineer-agent
#   /plugin install engineer-agent

# In your project directory, create the config:
mkdir -p .claude/engineer-agent
cp /path/to/engineer-agent/config/engineer.example.yaml .claude/engineer-agent/engineer.yaml

# Create queue and state directories (run from your project root)
/path/to/engineer-agent/scripts/install-cron.sh .
```

## Configuration

Edit `.claude/engineer-agent/engineer.yaml` in your project to match your setup:

```yaml
github:
  owner: "myorg"
  repos: ["repo-a", "repo-b"]
  review_requested_for: "my-username"
  ignore_labels: ["wip", "draft"]

slack:
  channels: ["C12345678"]        # Channel IDs to monitor
  keywords: ["@myname"]          # Trigger keywords
  ignore_bots: true

jira:
  project: "ENG"
  assignee: "me@example.com"
  statuses: ["To Do", "In Progress"]

slite:
  doc_labels: ["needs-review"]

agent:
  max_pr_files: 50               # Skip PRs with more files than this
  standup_channel: "C98765432"   # Slack channel for standups
  digest_channel: "C98765432"   # Slack channel for daily digests
  cron_interval_minutes: 15
```

Only configure the sources you use — the agent skips unconfigured integrations.

## Usage

### `/engineer poll [source]`

Fetch new work items from configured sources.

```
/engineer poll           # Poll all sources
/engineer poll github    # Poll GitHub only
/engineer poll slack     # Poll Slack only
/engineer poll jira      # Poll Jira only
/engineer poll slite     # Poll Slite only
```

New items are detected, drafted, and placed in the review queue.

### `/engineer review-queue [filter]`

Review pending drafts and approve, edit, or reject them.

```
/engineer review-queue          # Show all pending drafts
/engineer review-queue pr       # Show only PR reviews
/engineer review-queue slack    # Show only Slack answers
/engineer review-queue --all    # Include completed/rejected items
```

For each item you can:
- **Approve** — post the response (PR review, Slack message, draft PR, doc comments)
- **Edit** — modify the draft inline, then approve
- **Reject** — discard with a reason
- **Skip** — leave for later

### `/engineer status`

Check system health: config status, queue counts, and last poll times.

```
/engineer status
```

### `/engineer digest [--days N]`

Generate a daily summary of all agent activity.

```
/engineer digest           # Today's activity
/engineer digest --days 3  # Last 3 days
```

The digest includes items processed, approval rates, and breakdowns by type. Approve to post it to your configured digest channel.

## How It Works

### Queue Lifecycle

```
Source detected → .claude/engineer-agent/queue/incoming/ → skill drafts → queue/drafts/
                                                                              ↓
                                                        human reviews via /engineer review-queue
                                                                  ↓                    ↓
                                                        queue/completed/       queue/rejected/
                                                        (action posted)        (with reason)
```

Queue items are markdown files with YAML frontmatter. Filenames follow the pattern `{YYYYMMDD-HHmmss}-{type}-{short-id}.md`.

### Skills

Skills are auto-invoked during polling and processing:

| Skill | Trigger | What it does |
|-------|---------|-------------|
| `poll-github` | `/engineer poll` | Finds PRs requesting your review |
| `poll-slack` | `/engineer poll` | Finds unanswered questions matching keywords |
| `poll-jira` | `/engineer poll` | Finds assigned tickets in target statuses |
| `poll-slite` | `/engineer poll` | Finds docs tagged for review |
| `review-pr` | New PR detected | Generates structured review with severity levels |
| `answer-slack` | New question detected | Drafts answer with confidence level |
| `implement-ticket` | Ticket approved | Implements on feature branch, runs tests |
| `review-doc` | New doc detected | Reviews for accuracy, completeness, clarity |
| `generate-standup` | On demand | Creates standup from yesterday's activity |
| `generate-digest` | `/engineer digest` | Summarizes daily activity with metrics |

## Automated Polling

Set up cron to poll automatically:

```bash
# Install with default 15-minute interval (run from your project root)
/path/to/engineer-agent/scripts/install-cron.sh .

# Or specify a custom interval (in minutes)
/path/to/engineer-agent/scripts/install-cron.sh . 30
```

This installs a crontab entry that runs `scripts/cron-poll.sh`, which invokes Claude headlessly to poll all sources. Logs are written to `.claude/engineer-agent/state/cron-poll.log`.

```bash
# Verify cron is running
crontab -l | grep engineer-agent

# Remove automated polling
crontab -l | grep -v engineer-agent | crontab -
```

## Project Structure

### Plugin (this repo)
```
.claude-plugin/plugin.json     Plugin manifest
commands/
  poll.md                      /engineer poll command
  review-queue.md              /engineer review-queue command
  status.md                    /engineer status command
  digest.md                    /engineer digest command
skills/
  poll-github/SKILL.md         GitHub polling
  poll-slack/SKILL.md          Slack polling
  poll-jira/SKILL.md           Jira polling
  poll-slite/SKILL.md          Slite polling
  review-pr/SKILL.md           PR review generation
  answer-slack/SKILL.md        Slack answer drafting
  implement-ticket/SKILL.md    Ticket implementation
  review-doc/SKILL.md          Document review
  generate-standup/SKILL.md    Standup generation
  generate-digest/SKILL.md     Digest generation
scripts/
  cron-poll.sh                 Cron polling script
  install-cron.sh              Cron setup script
config/
  engineer.example.yaml        Configuration template
```

### Project-local data (in your project)
```
<project>/.claude/engineer-agent/
  engineer.yaml                User config (copied from template)
  queue/
    incoming/                  Newly detected items
    drafts/                    Items with drafted responses
    completed/                 Approved and posted
    rejected/                  Rejected with reason
  state/
    last-poll.yaml             Dedup timestamps and seen IDs
```
