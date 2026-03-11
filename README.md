# engineer-agent

A Claude Code plugin that automates senior software engineer tasks with an approval-gated workflow. The agent polls GitHub, Slack, Jira, and Slite for work, drafts responses, and queues everything for human review before posting externally.

## Features

- **PR Reviews** — Structured code reviews with severity levels (critical/important/suggestion)
- **Slack Q&A** — Drafts answers to questions in configured channels
- **Ticket Implementation** — Implements Jira tickets on feature branches, opens draft PRs
- **Doc Reviews** — Reviews Slite design documents with inline comments
- **Spec Refinement** — Analyzes PM feature specs and drafts clarifying questions
- **Design Doc Generation** — Creates engineering design docs from refined specs
- **Ticket Breakdown** — Breaks design docs into phased implementation tickets with dependencies
- **Standup Generation** — Creates daily standup updates from activity history
- **Daily Digest** — Summarizes all agent activity with approval metrics

Everything goes through an approval queue — nothing is posted until you say so. One unified queue across all your projects.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- **GitHub CLI (`gh`)** — for PR reviews, code operations, and GitHub API access. Install from [cli.github.com](https://cli.github.com) and run `gh auth login`
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
```

Then initialize from any project directory:

```
/engineer setup
```

This creates the user-level config, queue directories, and installs automated polling in one step. It also registers the current project. After setup, edit `~/.claude/engineer-agent/engineer.yaml` to configure your sources.

To register additional projects:

```
cd /path/to/another-project
/engineer add-project
```

## Configuration

Edit `~/.claude/engineer-agent/engineer.yaml`:

```yaml
agent:
  branch_prefix: "engineer-agent"
  max_pr_files: 50
  standup_channel: "C98765432"
  digest_channel: "C98765432"
  cron_interval_minutes: 15

projects:
  my-api:
    path: "/home/you/Projects/my-api"
    github:
      owner: "myorg"
      repos: ["my-api"]
      review_requested_for: "my-username"
      ignore_labels: ["wip", "draft"]
    slack:
      channels: ["C12345678"]
      keywords: ["@myname"]
      ignore_bots: true
    jira:
      project: "ENG"
      assignee: "me@example.com"
      statuses: ["To Do", "In Progress"]
    slite:
      doc_labels: ["needs-review"]

  my-frontend:
    path: "/home/you/Projects/my-frontend"
    github:
      owner: "myorg"
      repos: ["my-frontend"]
      review_requested_for: "my-username"
      ignore_labels: ["wip"]
```

Only configure the integrations you use per project — the agent skips unconfigured integrations.

## Usage

### `/engineer setup`

One-time user-level initialization. Creates config at `~/.claude/engineer-agent/`, queue directories, installs cron polling, and registers the current project.

```
/engineer setup
```

### `/engineer add-project`

Register the current project directory with engineer-agent. Auto-detects GitHub remote and prompts for integration details.

```
cd /path/to/my-project
/engineer add-project
```

### `/engineer poll [source] [--project <slug>]`

Fetch new work items from configured sources.

```
/engineer poll                     # Poll all sources, all projects
/engineer poll github              # Poll GitHub only, all projects
/engineer poll --project my-api    # Poll all sources, one project
/engineer poll slack --project my-api  # Poll Slack, one project
```

New items are detected, drafted, and placed in the review queue.

### `/engineer review-queue [filter] [--project <slug>]`

Review pending drafts and approve, edit, or reject them.

```
/engineer review-queue                    # Show all pending drafts
/engineer review-queue pr                 # Show only PR reviews
/engineer review-queue --project my-api   # Show only my-api items
/engineer review-queue --all              # Include completed/rejected items
```

For each item you can:
- **Approve** — post the response (PR review, Slack message, draft PR, doc comments)
- **Edit** — modify the draft inline, then approve
- **Reject** — discard with a reason
- **Skip** — leave for later

### `/engineer status`

Check system health: config status, queue counts, and per-project last poll times.

```
/engineer status
```

### `/engineer digest [--days N]`

Generate a daily summary of all agent activity across all projects.

```
/engineer digest           # Today's activity
/engineer digest --days 3  # Last 3 days
```

The digest includes items processed, approval rates, and breakdowns by project and type. Approve to post it to your configured digest channel.

### `/engineer refine-spec <slite-url-or-id> [--project <slug>]`

Analyze a PM feature spec and generate clarifying questions.

```
/engineer refine-spec https://futuresinc.slite.com/p/note/abc123
```

Generates structured questions across scope, feasibility, missing details, ambiguities, and constraints. After approval, fill in the answer fields to provide context for design doc generation.

### `/engineer create-design-doc <slite-url-or-id> [--project <slug>]`

Generate an engineering design doc from a PM spec.

```
/engineer create-design-doc https://futuresinc.slite.com/p/note/abc123
```

Researches the codebase and produces a full design doc (architecture, components, data model, API changes, risks, implementation phases). If a prior spec refinement exists for this doc, its Q&A is included as context. On approval, the design doc is created in Slite.

### `/engineer create-tickets <slite-url-or-id> [--project <slug>]`

Break a design doc into phased implementation tickets.

```
/engineer create-tickets https://futuresinc.slite.com/p/note/abc123
```

Takes a Slite design doc and generates detailed tickets grouped by implementation phase. Each ticket includes purpose, implementation approach (with real file paths), testing strategy, acceptance criteria, and dependencies on other tickets. On approval, the ticket plan moves to completed for reference when creating tickets in your project tracker.

## How It Works

### Queue Lifecycle

```
Source detected → ~/.claude/engineer-agent/queue/incoming/ → skill drafts → queue/drafts/
                                                                              ↓
                                                        human reviews via /engineer review-queue
                                                                  ↓                    ↓
                                                        queue/completed/       queue/rejected/
                                                        (action posted)        (with reason)
```

Queue items are markdown files with YAML frontmatter. Each item carries a `project` field linking it to a project in the config. Filenames follow the pattern `{YYYYMMDD-HHmmss}-{type}-{short-id}.md`.

### Skills

Skills are auto-invoked during polling and processing:

| Skill | Trigger | What it does |
|-------|---------|-------------|
| `poll-github` | `/engineer poll` | Finds PRs requesting your review (all projects) |
| `poll-slack` | `/engineer poll` | Finds unanswered questions matching keywords (all projects) |
| `poll-jira` | `/engineer poll` | Finds assigned tickets in target statuses (all projects) |
| `poll-slite` | `/engineer poll` | Finds docs tagged for review (all projects) |
| `review-pr` | New PR detected | Generates structured review with severity levels |
| `answer-slack` | New question detected | Drafts answer with confidence level |
| `implement-ticket` | Ticket approved | Implements on feature branch, runs tests |
| `review-doc` | New doc detected | Reviews for accuracy, completeness, clarity |
| `generate-standup` | On demand | Creates standup from yesterday's activity (all projects) |
| `generate-digest` | `/engineer digest` | Summarizes daily activity with metrics (all projects) |
| `refine-spec` | `/engineer refine-spec` | Analyzes spec, generates clarifying questions |
| `create-design-doc` | `/engineer create-design-doc` | Generates engineering design doc from spec |
| `create-tickets` | `/engineer create-tickets` | Breaks design doc into phased tickets |

## Automated Polling

`/engineer setup` installs cron polling automatically with the interval from your config (default: 15 minutes). One cron job polls all projects.

To customize the interval or reinstall manually:

```bash
# Install with a custom interval (in minutes)
/path/to/engineer-agent/scripts/install-cron.sh 30
```

This installs a crontab entry that runs `scripts/cron-poll.sh`, which invokes Claude headlessly to poll all sources for all projects. Logs are written to `~/.claude/engineer-agent/state/cron-poll.log`.

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
  setup.md                     /engineer setup command
  add-project.md               /engineer add-project command
  poll.md                      /engineer poll command
  review-queue.md              /engineer review-queue command
  status.md                    /engineer status command
  digest.md                    /engineer digest command
  refine-spec.md               /engineer refine-spec command
  create-design-doc.md         /engineer create-design-doc command
  create-tickets.md            /engineer create-tickets command
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
  refine-spec/SKILL.md         Spec analysis and questions
  create-design-doc/SKILL.md   Design doc generation
  create-tickets/SKILL.md      Ticket breakdown from design doc
scripts/
  cron-poll.sh                 Cron polling script
  install-cron.sh              Cron setup script
config/
  engineer.example.yaml        Configuration template
```

### User-level data
```
~/.claude/engineer-agent/
  engineer.yaml                User config (all projects in one file)
  queue/
    incoming/                  Newly detected items (all projects)
    drafts/                    Items with drafted responses
    completed/                 Approved and posted
    rejected/                  Rejected with reason
  state/
    last-poll.yaml             Dedup timestamps and seen IDs (per project)
```
