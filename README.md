# engineer-agent

A Claude Code plugin that automates senior software engineer tasks with an approval-gated workflow. The agent polls GitHub, Slack, ticket trackers (Jira or GitHub Issues), and Slite for work, drafts responses, and queues everything for human review before posting externally.

## Features

- **PR Reviews** — Structured code reviews with severity levels (critical/important/suggestion)
- **Slack Q&A** — Drafts answers to questions in configured channels
- **Ticket Implementation** — Implements tickets (Jira or GitHub Issues) on feature branches, opens draft PRs
- **Doc Reviews** — Reviews Slite design documents with inline comments
- **Spec Refinement** — Analyzes PM feature specs and drafts clarifying questions
- **Ticket Refinement** — Analyzes existing tickets for scope clarity, feasibility, testability, and Fibonacci sizing
- **Design Doc Generation** — Creates engineering design docs from refined specs
- **Ticket Breakdown** — Breaks design docs into phased implementation tickets with dependencies
- **Pipeline Gap Audit** — Bidirectional comparison of spec ↔ design doc ↔ tickets to detect mismatches
- **Standup Generation** — Creates daily standup updates from activity history
- **Daily Digest** — Summarizes all agent activity with approval metrics

Everything goes through an approval queue — nothing is posted until you say so. One unified queue across all your projects.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- **GitHub CLI (`gh`)** — for PR reviews, code operations, and GitHub API access. Install from [cli.github.com](https://cli.github.com) and run `gh auth login`
- **Slack MCP integration** — for channel polling and message posting (`mcp__claude_ai_Slack__*`)
- **Jira MCP integration** (optional) — for ticket polling and implementation when using Jira as tracker (`mcp__atlassian__*`). Either Jira or GitHub Issues per project — GitHub Issues uses the `gh` CLI (already a prerequisite)
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
/engineer-agent setup
```

This creates the user-level config, queue directories, and installs automated polling in one step. It also registers the current project. After setup, edit `~/.claude/engineer-agent/engineer.yaml` to configure your sources.

To register additional projects:

```
cd /path/to/another-project
/engineer-agent add-project
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
  # Example: project using Jira
  my-api:
    path: "/home/you/Projects/my-api"
    tracker: "jira"                      # "jira" | "github-issues" | "none"
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

  # Example: project using GitHub Issues
  my-frontend:
    path: "/home/you/Projects/my-frontend"
    tracker: "github-issues"
    github:
      owner: "myorg"
      repos: ["my-frontend"]
      review_requested_for: "my-username"
      ignore_labels: ["wip"]
      issues:
        assignee: "my-username"
        labels: []                       # optional: filter to specific labels
```

Only configure the integrations you use per project — the agent skips unconfigured integrations.

## Usage

### `/engineer-agent setup`

One-time user-level initialization. Creates config at `~/.claude/engineer-agent/`, queue directories, installs cron polling, and registers the current project.

```
/engineer-agent setup
```

### `/engineer-agent add-project`

Register the current project directory with engineer-agent. Auto-detects GitHub remote and prompts for integration details.

```
cd /path/to/my-project
/engineer-agent add-project
```

### `/engineer-agent poll [source] [--project <slug>]`

Fetch new work items from configured sources.

```
/engineer-agent poll                     # Poll all sources, all projects
/engineer-agent poll github              # Poll GitHub PRs only, all projects
/engineer-agent poll github-issues       # Poll GitHub Issues only, all projects
/engineer-agent poll --project my-api    # Poll all sources, one project
/engineer-agent poll slack --project my-api  # Poll Slack, one project
```

New items are detected, drafted, and placed in the review queue.

### `/engineer-agent review-queue [filter] [--project <slug>]`

Review pending drafts and approve, edit, or reject them.

```
/engineer-agent review-queue                    # Show all pending drafts
/engineer-agent review-queue pr                 # Show only PR reviews
/engineer-agent review-queue --project my-api   # Show only my-api items
/engineer-agent review-queue --all              # Include completed/rejected items
```

For each item you can:
- **Approve** — post the response (PR review, Slack message, draft PR, doc comments)
- **Edit** — modify the draft inline, then approve
- **Reject** — discard with a reason
- **Skip** — leave for later

### `/engineer-agent status`

Check system health: config status, queue counts, and per-project last poll times.

```
/engineer-agent status
```

### `/engineer-agent digest [--days N]`

Generate a daily summary of all agent activity across all projects.

```
/engineer-agent digest           # Today's activity
/engineer-agent digest --days 3  # Last 3 days
```

The digest includes items processed, approval rates, and breakdowns by project and type. Approve to post it to your configured digest channel.

### `/engineer-agent refine-spec <slite-url-or-id> [--project <slug>]`

Analyze a PM feature spec and generate clarifying questions.

```
/engineer-agent refine-spec https://example.slite.com/p/note/abc123
```

Generates structured questions across scope, feasibility, missing details, ambiguities, and constraints. After approval, fill in the answer fields to provide context for design doc generation.

### `/engineer-agent refine-ticket <jira-key|github-url|--jql "..."|--text "..."> [--project <slug>]`

Analyze existing tickets for scope, feasibility, testability, and sizing.

```
/engineer-agent refine-ticket ENG-123
/engineer-agent refine-ticket ENG-123 ENG-124 ENG-125
/engineer-agent refine-ticket --jql "project = ENG AND status = 'To Do'"
/engineer-agent refine-ticket https://github.com/org/repo/issues/45
/engineer-agent refine-ticket --text "As a user, I want to..."
```

Assesses scope clarity, implementation feasibility (grounded in codebase analysis), testability, and assigns a Fibonacci sizing estimate. Multiple tickets are processed in parallel. Approve via `/engineer-agent review-queue refinement`.

### `/engineer-agent create-design-doc <slite-url-or-id> [--project <slug>]`

Generate an engineering design doc from a PM spec.

```
/engineer-agent create-design-doc https://example.slite.com/p/note/abc123
```

Researches the codebase and produces a full design doc (architecture, components, data model, API changes, risks, implementation phases). If a prior spec refinement exists for this doc, its Q&A is included as context. On approval, the design doc is created in Slite.

### `/engineer-agent create-tickets <slite-url-or-id> [--project <slug>]`

Break a design doc into phased implementation tickets.

```
/engineer-agent create-tickets https://example.slite.com/p/note/abc123
```

Takes a Slite design doc and generates detailed tickets grouped by implementation phase. Each ticket includes purpose, implementation approach (with real file paths), testing strategy, acceptance criteria, and dependencies on other tickets. On approval, the ticket plan moves to completed for reference when creating tickets in your project tracker.

### `/engineer-agent audit-gaps <url-or-key> [--project <slug>] [--boundary <spec-design|design-tickets|all>]`

Detect gaps between pipeline artifacts (spec, design doc, tickets).

```
/engineer-agent audit-gaps https://example.slite.com/p/note/abc123
/engineer-agent audit-gaps ENG-123 --boundary design-tickets
/engineer-agent audit-gaps https://github.com/org/repo/issues/42 --boundary all
```

Performs bidirectional comparison across boundaries. Each gap is classified as missing-right, missing-left, diverged, or ambiguous, with draft fixes where possible. Approve via `/engineer-agent review-queue gap`.

## How It Works

### Queue Lifecycle

```
Source detected → ~/.claude/engineer-agent/queue/incoming/ → skill drafts → queue/drafts/
                                                                              ↓
                                                        human reviews via /engineer-agent review-queue
                                                                  ↓                    ↓
                                                        queue/completed/       queue/rejected/
                                                        (action posted)        (with reason)
```

Queue items are markdown files with YAML frontmatter. Each item carries a `project` field linking it to a project in the config. Filenames follow the pattern `{YYYYMMDD-HHmmss}-{type}-{short-id}.md`.

### Skills

Skills are auto-invoked during polling and processing:

| Skill | Trigger | What it does |
|-------|---------|-------------|
| `poll-github` | `/engineer-agent poll` | Finds PRs requesting your review (all projects) |
| `poll-slack` | `/engineer-agent poll` | Finds unanswered questions matching keywords (all projects) |
| `poll-jira` | `/engineer-agent poll` | Finds assigned Jira tickets in target statuses (projects with tracker: jira) |
| `poll-github-issues` | `/engineer-agent poll` | Finds assigned GitHub issues (projects with tracker: github-issues) |
| `poll-slite` | `/engineer-agent poll` | Finds docs tagged for review (all projects) |
| `review-pr` | New PR detected | Generates structured review with severity levels |
| `answer-slack` | New question detected | Drafts answer with confidence level |
| `implement-ticket` | Ticket approved | Implements Jira or GitHub Issue on feature branch, runs tests |
| `review-doc` | New doc detected | Reviews for accuracy, completeness, clarity |
| `generate-standup` | On demand | Creates standup from yesterday's activity (all projects) |
| `generate-digest` | `/engineer-agent digest` | Summarizes daily activity with metrics (all projects) |
| `refine-spec` | `/engineer-agent refine-spec` | Analyzes spec, generates clarifying questions |
| `refine-ticket` | `/engineer-agent refine-ticket` | Analyzes ticket scope, feasibility, testability, and sizing |
| `create-design-doc` | `/engineer-agent create-design-doc` | Generates engineering design doc from spec |
| `create-tickets` | `/engineer-agent create-tickets` | Breaks design doc into phased tickets |
| `audit-gaps` | `/engineer-agent audit-gaps` | Compares pipeline artifacts across boundaries, produces gap checklist |

## Automated Polling

`/engineer-agent setup` installs cron polling automatically with the interval from your config (default: 15 minutes). One cron job polls all projects.

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
  setup.md                     /engineer-agent setup command
  add-project.md               /engineer-agent add-project command
  poll.md                      /engineer-agent poll command
  review-queue.md              /engineer-agent review-queue command
  status.md                    /engineer-agent status command
  digest.md                    /engineer-agent digest command
  refine-spec.md               /engineer-agent refine-spec command
  refine-ticket.md             /engineer-agent refine-ticket command
  create-design-doc.md         /engineer-agent create-design-doc command
  create-tickets.md            /engineer-agent create-tickets command
  audit-gaps.md                /engineer-agent audit-gaps command
skills/
  poll-github/SKILL.md         GitHub polling
  poll-slack/SKILL.md          Slack polling
  poll-jira/SKILL.md           Jira polling
  poll-github-issues/SKILL.md  GitHub Issues polling
  poll-slite/SKILL.md          Slite polling
  review-pr/SKILL.md           PR review generation
  answer-slack/SKILL.md        Slack answer drafting
  implement-ticket/SKILL.md    Ticket implementation
  review-doc/SKILL.md          Document review
  generate-standup/SKILL.md    Standup generation
  generate-digest/SKILL.md     Digest generation
  refine-spec/SKILL.md         Spec analysis and questions
  refine-ticket/SKILL.md       Ticket refinement and sizing
  create-design-doc/SKILL.md   Design doc generation
  create-tickets/SKILL.md      Ticket breakdown from design doc
  audit-gaps/SKILL.md          Pipeline gap auditing
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
