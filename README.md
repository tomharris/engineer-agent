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
- **QA Test Plans** — Generates hybrid test plans (runnable scripts + manual checklists) from ticket acceptance criteria and branch code changes, then runs the scripts and self-fixes failing tests (surfacing genuine code bugs) when the app is reachable
- **Code Audit** — Proactive bug/security scan: Sonnet finds candidates across OWASP-style security, correctness, secrets, and dependency CVEs; Opus verifies each one before it enters the queue
- **Pipeline Gap Audit** — Bidirectional comparison of spec ↔ design doc ↔ tickets to detect mismatches
- **Standup Generation** — Creates daily standup updates from activity history
- **Daily Digest** — Summarizes all agent activity with approval metrics
- **Push Notifications & Remote Approval** — Optional [ntfy](https://ntfy.sh) integration pushes an alert when work is queued and lets you approve/reject from your phone without opening Claude Code

Everything goes through an approval queue — nothing is posted until you say so. One unified queue across all your projects. With ntfy configured, that approval can happen remotely from your phone, and safe actions (draft-PR creation) can be allowed to run hands-free.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- **GitHub CLI (`gh`)** — for PR reviews, code operations, and GitHub API access. Install from [cli.github.com](https://cli.github.com) and run `gh auth login`
- **Spy Slack CLI (`spy`)** — for channel polling and message posting. Spy reuses your local Slack desktop session, so there's no OAuth or app install. Build it from [github.com/tomharris/spy](https://github.com/tomharris/spy) (`go install ./cmd/spy`), sign in to the Slack desktop app, then run `spy auth` to confirm. Set the workspace via `agent.slack.workspace` in config (required when multiple workspaces are signed in)
- **Jira MCP integration** (optional) — for ticket polling and implementation when using Jira as tracker (`mcp__atlassian__*`). Either Jira or GitHub Issues per project — GitHub Issues uses the `gh` CLI (already a prerequisite)
- **Slite MCP integration** (optional) — for document reviews (`mcp__slite__*`)
- **ntfy** (optional) — for push notifications and remote approval. No install needed to publish (uses `curl` against [ntfy.sh](https://ntfy.sh) or your self-hosted server); install the [ntfy mobile app](https://ntfy.sh/app) to receive alerts and tap Approve/Reject. The approval listener also needs **`jq`** on the host running it.

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

This creates the user-level config, queue directories, and installs automated polling in one step. It also registers the current project. After setup, edit `~/.local/share/engineer-agent/engineer.yaml` to configure your sources.

To register additional projects:

```
cd /path/to/another-project
/engineer-agent add-project
```

## Configuration

Edit `~/.local/share/engineer-agent/engineer.yaml`:

```yaml
agent:
  branch_prefix: "engineer-agent"
  max_pr_files: 50
  standup_channel: "C98765432"
  digest_channel: "C98765432"
  cron_interval_minutes: 15
  slack:                                  # Spy CLI settings (optional)
    bin: "spy"                            # path to the spy binary (default: "spy" on PATH)
    workspace: "myco"                     # default Slack workspace (team domain or team_id)
  autonomy:
    auto_execute: ["draft-pr"]            # action tiers allowed to run without approval
  notify:                                 # optional — omit to disable push notifications
    ntfy:
      server: "https://ntfy.sh"
      topic: "ea-alert-CHANGE-ME-RANDOM"        # outbound alerts (keep name secret)
      command_topic: "ea-cmd-CHANGE-ME-RANDOM"  # approve/reject taps (TREAT AS A PASSWORD)
      auth_token: ""                            # optional ntfy access token (recommended)

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
      workspace: "myco"                  # optional: overrides agent.slack.workspace
    jira:
      sources:                              # watch multiple Jira projects per repo
        - project: "ENG"
          components: ["api", "backend"]    # optional: filter by Jira component
        # - project: "PLAT"                 # add more Jira projects as needed
        #   labels: ["infra"]              # optional: filter by Jira label
      assignee: "me@example.com"
      statuses: ["To Do", "In Progress"]
    slite:
      doc_labels: ["needs-review"]
    qa:
      base_url: "http://localhost:3000"  # base URL for curl commands in QA test scripts
      console_command: ""                # e.g. "rails console", "python manage.py shell", "node" (optional)
      document_to: ""                    # where to document completed QA plans: "slite" | "" (empty/absent disables)
      document_parent: ""                # Slite channel/note id for the QA doc; empty → user's private (personal) channel

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

### Ticket Routing

One Jira project key or one GitHub repo often spans several engineer-agent projects (a shared team
board, a monorepo). Routing decides which project a ticket belongs to. It works the same way for
Jira and GitHub Issues.

Each engineer-agent project can watch multiple Jira projects, and multiple engineer-agent projects can watch the same Jira project with different filters (N:M mapping):

```yaml
projects:
  my-api:
    tracker: jira
    jira:
      sources:
        - project: ENG
          components: ["api", "backend"]
        - project: PLAT
          labels: ["infra"]
      assignee: "me@example.com"
      statuses: ["To Do", "In Progress"]

  my-frontend:
    tracker: jira
    jira:
      sources:
        - project: ENG
          components: ["frontend", "ui"]
      assignee: "me@example.com"
      statuses: ["To Do", "In Progress"]
```

#### How a ticket finds its project

Tickets run through a ladder of tiers. Each tier needs **exactly one** match — anything ambiguous
falls through to the next, and the last tier is always you:

| Tier | Basis |
|---|---|
| **Single candidate** | Only one project watches this Jira key / repo → route. Nothing below runs. |
| **Title prefix** | A summary starting `[<token>]` (e.g. `[payroll-workflows] - …`) where `<token>` equals exactly one watcher's slug or `github.repos` entry, case-insensitively. |
| **Filters** | Jira `components`/`labels`; GitHub `github.issues.labels`. A source with no filters is a catch-all. |
| **Keywords** | `routing.keywords` / `routing.paths` hints (below). |
| **Inference** | Semantic match of the ticket against `routing.description` hints (below). |
| **Unrouted** | Nothing resolved to one project → marked **unrouted** and parked in the review queue for you to assign. |

#### Routing hints (optional)

When the rules above can't tell projects apart — a shared board with no distinguishing components,
a monorepo where labels aren't used consistently — describe what each project covers and let the
agent work it out:

```yaml
projects:
  payroll-workflows:
    routing:
      description: "Paycycle scheduling, voids, and approval workflows"
      keywords: ["paycycle", "void", "payroll"]   # whole-word match on title + body
      paths: ["app/payroll/**"]                   # matched against paths named in the ticket
```

- **Entirely opt-in.** Omit the block and those two tiers are skipped — routing behaves exactly as
  it did before hints existed. Only worth adding to projects that share a key or repo.
- **An inferred route is auto-routed and drafted, but never posted unattended.** `review-queue`
  shows you that it was inferred and why (`payroll-workflows (inferred — mentions void paycycle
  approval)`), so a wrong guess costs a rejected draft, not an external action.
- **The agent can abstain.** A genuine tie goes to *unrouted*, not a coin flip.
- `/engineer-agent add-ticket` is interactive, so it asks you at the last tier rather than parking
  the item.

**Backward compatibility:** The legacy `jira.project: "ENG"` format still works and is treated as a catch-all source.

**Note on `github.issues.labels`:** these labels now decide *which* watching project owns an issue,
not just which issues get fetched. If two projects share a repo and one has no labels set, it is a
catch-all — so issues both projects could claim will correctly show up as **unrouted** rather than
being silently assigned to whichever project happened to be polled first.

## Usage

### `/engineer-agent setup`

One-time user-level initialization. Creates config at `~/.local/share/engineer-agent/`, queue directories, installs cron polling, and registers the current project.

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

### `/engineer-agent add-ticket <ref> [--project <slug>] [--no-draft]`

Manually add a Jira ticket or GitHub issue to the implementation queue, bypassing poll filters. Useful for tickets outside your configured assignee/components/labels.

```
/engineer-agent add-ticket ENG-789                                  # Jira key
/engineer-agent add-ticket https://example.atlassian.net/browse/ENG-789
/engineer-agent add-ticket https://github.com/myorg/my-app/issues/45
/engineer-agent add-ticket myorg/my-app#45
/engineer-agent add-ticket ENG-789 --project my-api                 # Skip routing, force project
/engineer-agent add-ticket ENG-789 --no-draft                       # Queue without generating a draft
```

The command fetches the ticket, resolves a project using the same routing ladder as polling (see [Ticket Routing](#ticket-routing)), and writes a queue item identical in shape to a polled one. Because it's interactive, it prompts you to pick a project instead of marking the ticket unrouted — but only where the ladder genuinely can't tell, which should be rare. Active-queue dedup blocks adding a ticket already sitting in `incoming/` or `drafts/`, but completed/rejected tickets and `seen_tickets`/`seen_issues` state are bypassed so you can re-queue manually.

### `/engineer-agent review-queue [filter] [--project <slug>]`

Review pending drafts and approve, edit, or reject them.

```
/engineer-agent review-queue                    # Show all pending drafts
/engineer-agent review-queue pr                 # Show only PR reviews
/engineer-agent review-queue qa                 # Show only QA test plans
/engineer-agent review-queue codify             # Show only codify candidates
/engineer-agent review-queue --project my-api   # Show only my-api items
/engineer-agent review-queue --all              # Include completed/rejected items
```

For each item you can:
- **Approve** — post the response (PR review, Slack message, draft PR, doc comments)
- **Edit** — modify the draft inline, then approve
- **Reject** — discard with a reason
- **Skip** — leave for later

Approve and Reject both run through the shared `execute-item` skill, so the result is identical whether you act here or remotely from your phone.

### `/engineer-agent execute <item-id> <approve|reject> [reason...]`

Headlessly approve or reject a single queue item. This is primarily the entry point the ntfy approval listener calls when you tap a button on your phone — it does the same work as `review-queue` for one item, with the decision already made, and never prompts.

```
/engineer-agent execute 20260525-120000-pr-review-142.md approve
/engineer-agent execute 20260525-130000-slack-question-abc.md reject "not relevant"
```

It resolves the item against `queue/drafts/` (a no-op if already handled) and runs `execute-item`. On the remote-approval path the approval listener wraps this call and pushes receipt and outcome confirmations back to your phone. See [Push Notifications & Remote Approval](#push-notifications--remote-approval).

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

### `/engineer-agent qa [ticket-url-or-key] [--project <slug>] [--base <branch>]`

Generate a QA test plan for a feature branch.

```
/engineer-agent qa                                          # Infer ticket from branch name
/engineer-agent qa ENG-123                                  # Specify Jira ticket
/engineer-agent qa https://github.com/org/repo/issues/45    # Specify GitHub issue
/engineer-agent qa ENG-123 --base develop                   # Custom base branch for diff
```

Cross-references ticket acceptance criteria, PR testing notes, and branch code changes to produce a hybrid test plan: a runnable shell script (curl commands, REPL snippets) plus a manual checklist for items requiring human judgment. When the app is reachable at `qa.base_url`, it also **runs the generated script and fixes failing scripted tests in place** — correcting test defects (wrong path, bad expected status, malformed request) while leaving genuine code-bug failures intact and surfacing them as findings (it never rewrites an expectation just to go green). If the app is unreachable, it keeps the generated script and reports that tests weren't executed. Approve via `/engineer-agent review-queue qa`. On completion, if `qa.document_to: slite` is configured, the full plan — manual checklist, the inlined `qa-test.sh` script, and the execution results — is published to Slite as a single note (under `qa.document_parent`, or your private personal channel when unset). Leave `document_to` empty to disable.

### `/engineer-agent uat-plan <ticket-or-issue> [more refs...] [--project <slug>]`

Generate a User Acceptance Testing checklist from a list of issues/tickets.

```
/engineer-agent uat-plan ENG-123                          # single Jira ticket
/engineer-agent uat-plan ENG-100 ENG-205 PLAT-7           # mixed Jira keys
/engineer-agent uat-plan https://github.com/org/repo/issues/42
/engineer-agent uat-plan org/repo#42 #43 ENG-9            # mixed GitHub + Jira
/engineer-agent uat-plan EPIC-1                           # Jira epic → expands to all descendants
```

Accepts a list of GitHub issues and/or Jira tickets (mixing trackers is allowed). A Jira parent (epic/story) is expanded to all its descendants, which replace the parent as the testable units. Working purely from ticket text — title, description, acceptance criteria — it derives concrete user-facing tests, clusters them into inferred feature areas, and emits a single markdown checklist table (`☐ | Feature Area | Test | Expected Result | Source`). Unlike `qa`, this is multi-ticket, code-agnostic, and bypasses the review queue: the table is printed to the terminal and saved under `~/.local/share/engineer-agent/uat-plans/`.

### `/engineer-agent audit-code [subdir] [--project <slug>]`

Proactively scan a registered project (or a subdirectory) for bugs and security issues. Uses a Sonnet subagent to surface candidate findings across four scopes — OWASP-style security, correctness bugs, hardcoded secrets, and known dependency vulnerabilities — then an Opus subagent to verify each one before it reaches the queue.

```
/engineer-agent audit-code                       # full scan of the current project
/engineer-agent audit-code src/auth              # scan only src/auth
/engineer-agent audit-code --project my-api      # scan another configured project
```

Each verified finding becomes its own `code-audit-finding` queue item and triggers an ntfy push (if configured) with Approve/Reject buttons. Approving creates a tracker ticket (Jira or GitHub Issue) in the project's configured tracker, labelled `audit` + `audit:{category}`. Review via `/engineer-agent review-queue audit`.

### `/engineer-agent codify [--since <date>|last-week] [--project <slug>]`

Capture recurring in-session learnings back into your tooling. Scans recently completed and
rejected queue items (default: last 7 days) for recurring friction and discoveries — repeated
environment workarounds, debugging techniques, rejection reasons that reveal a missing
convention — and drafts each as a `codify-candidate` queue item.

```
/engineer-agent codify                       # last 7 days, all projects
/engineer-agent codify --since last-week
/engineer-agent codify --project my-api
```

Each candidate is classified as a **memory-file**, a **skill-note**, or a **CLAUDE.md**
addition, with the exact proposed content. Approving one via `/engineer-agent review-queue`
performs the local file write (no external post); rejecting writes nothing. This is how one-off
discoveries become compounding, reusable assets. Review via `/engineer-agent review-queue codify`.

## Golden Path

The end-to-end loop these commands are designed to chain into, per ticket:

```
/engineer-agent:implement-ticket <ticket>   # branch, implement (Ralph Loop), draft PR
        │  (in parallel)
        └─ /security-review                  # security pass on the diff
/engineer-agent:qa <ticket>                  # generate + run QA test plan
/engineer-agent:review-queue                 # approve/triage everything above
/engineer-agent:codify --since last-week     # (weekly) fold learnings back into tooling
```

Each stage carries an **Intent block** (Goal / Key constraints / Definition of done /
Non-goals) and a **Findings & Disposition** ledger forward into the PR and the completed queue
item, so the work is self-documenting for intent and closes the loop on every review finding.

## How It Works

### Queue Lifecycle

```
Source detected → ~/.local/share/engineer-agent/queue/incoming/ → skill drafts → queue/drafts/
                                                                              ↓
                                                       (ntfy push: Approve/Reject/Open)
                                                                              ↓
                          human reviews via /engineer-agent review-queue  OR  taps phone → /engineer-agent execute
                                                                  ↓                    ↓
                                                        queue/completed/       queue/rejected/
                                                        (action posted)        (with reason)
```

Both the terminal (`review-queue`) and remote (`execute`) paths funnel through one shared `execute-item` skill, so an action behaves identically no matter how it was approved.

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
| `generate-qa` | `/engineer-agent qa` | Generates hybrid QA test plan (script + manual checklist) from ticket AC and code changes, then runs and self-fixes the scripted tests when the app is reachable |
| `audit-code` | `/engineer-agent audit-code` | Scans a project for bugs and security issues; Sonnet finds, Opus verifies, verified findings become queue items |
| `codify-learnings` | `/engineer-agent codify` | Scans recent completed/rejected work for recurring learnings, drafts memory-file / skill-note / CLAUDE.md candidates |
| `execute-item` | Approve/reject from `review-queue` or `execute` | Performs the external action for one item; the single source of truth shared by terminal and remote approval |

## Automated Polling

`/engineer-agent setup` installs cron polling automatically with the interval from your config (default: 15 minutes). One cron job polls all projects.

To customize the interval or reinstall manually:

```bash
# Install with a custom interval (in minutes)
/path/to/engineer-agent/scripts/install-cron.sh 30
```

This installs a crontab entry that runs `scripts/cron-poll.sh`, which invokes Claude headlessly to poll all sources for all projects. Logs are written to `~/.local/share/engineer-agent/state/cron-poll.log`.

**The poll is read-only by construction.** It runs with an allowlist limited to read verbs (`gh pr list/view/diff`, `gh issue list/view`, `spy read/thread`), so it can find work and draft responses but cannot post anything. Every outbound action stays behind the approval gate.

**Headless auth (macOS): set up an OAuth token, or the poll fails with "Not logged in."** On macOS the Claude credential lives in the login keychain, and cron (and a supervised listener) run *outside* your GUI login session, so they can't read it — even when everything else is configured. The fix is a keychain-independent token: run `claude setup-token` once (requires a paid plan — Free is refused), then store it in a mode-600 file:

```bash
claude setup-token   # interactive; copy the printed token
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' '<token>' > ~/.local/share/engineer-agent/auth.env
chmod 600 ~/.local/share/engineer-agent/auth.env
```

`scripts/lib-paths.sh` loads `auth.env` for every headless run (cron and ntfy listener alike), so no crontab/service reinstall is needed and the secret never appears in `crontab -l`. An already-set `CLAUDE_CODE_OAUTH_TOKEN` env var wins, and when no file exists interactive keychain auth is untouched. The token lives ~1 year — note the expiry. `install-cron.sh`/`install-listener.sh` print a NOTE when no token is configured.

Because `claude -p` exits 0 whenever the CLI ran — regardless of whether the poll actually happened — the cron doesn't trust the exit code. It mints a per-run id and requires the poll to write it back into `state/last-poll-receipt.yaml` as its final step; if that receipt is missing or stale the run failed silently, and the cron logs a `WARN` and — when ntfy is configured — sends you an urgent push. A poll that legitimately finds **zero items** writes a normal receipt (`status: ok`, `items_queued: 0`) and stays silent, and a **partial** failure (one source errored while others succeeded) is now surfaced too — something the previous state-fingerprint check could never detect.

**Upgrading from a version before runtime data moved?** Data used to live in `~/.claude/engineer-agent/`, which Claude Code guards as sensitive — headless runs (cron, ntfy listener) couldn't write there, so they silently did nothing. Migrate with:

```bash
/path/to/engineer-agent/scripts/migrate-storage.sh
```

It copies everything to `~/.local/share/engineer-agent/`, never overwrites, and leaves the old tree intact for you to delete. Set `EA_AGENT_DIR` to choose a different location (`XDG_DATA_HOME` is honored).

By default the scripts resolve the `claude` binary from `PATH`. To use a specific Claude Code binary (a version shim, wrapper, or non-standard install path), set the `CLAUDE_BIN` env var — e.g. `CLAUDE_BIN=/opt/claude/bin/claude scripts/install-cron.sh 30`. Because cron does not inherit your interactive shell environment, the installer bakes the value set at install time into the crontab entry so the scheduled run uses the same binary.

```bash
# Verify cron is running
crontab -l | grep engineer-agent

# Remove automated polling
crontab -l | grep -v engineer-agent | crontab -
```

## Push Notifications & Remote Approval

With an `agent.notify.ntfy` block configured, the agent pushes work to your phone and lets you approve it remotely. The whole loop runs over [ntfy](https://ntfy.sh) — no custom server.

**How it works:**

```
cron-poll → drafts item → notify.sh ──ntfy push (Approve / Reject / Open)──▶ 📱
                                                                              │ tap
            approval-listener.sh ◀── ntfy command_topic ◀── button POSTs ─────┘
                     │
                     └─▶ claude -p "/engineer-agent execute <item> <decision>" → posts the action
```

1. After each poll, every new draft is pushed to your `topic` with **Approve**, **Reject**, and **Open** buttons.
2. Tapping Approve/Reject POSTs a command (`approve|<item>` / `reject|<item>`) to your `command_topic`.
3. `scripts/approval-listener.sh` — a long-running service on your machine — reads the command topic and runs `/engineer-agent execute` headlessly to perform the action. It confirms each tap on your phone: a **receipt** notification ("📨 Received…") the instant the tap lands, then an **outcome** notification once the run finishes — "✅ Done…" on success or "⚠️ Failed…" if the item still needs a re-run. (Malformed or duplicate taps are ignored silently.)

**Install the listener** (after configuring `agent.notify.ntfy` and installing `jq`):

```bash
/path/to/engineer-agent/scripts/install-listener.sh
```

This registers a supervised service (`engineer-agent-listener`) that restarts on failure and survives reboots: a **systemd user service** on Linux (run `loginctl enable-linger $USER` so it keeps running while you're logged out) or a **launchd LaunchAgent** on macOS (starts at login, restarts on crash — no extra steps). On hosts with neither it falls back to a `nohup` background process. Logs go to `~/.local/share/engineer-agent/state/approval-listener.log`.

As with cron, set `CLAUDE_BIN` to pick a specific Claude Code binary — e.g. `CLAUDE_BIN=/opt/claude/bin/claude scripts/install-listener.sh`. Since the supervised service does not inherit your shell environment, the installer bakes the install-time value into the systemd unit (`Environment=`) or launchd plist (`EnvironmentVariables`).

**Hands-free draft PRs:** with `agent.autonomy.auto_execute: ["draft-pr"]`, draft-PR creation after a ticket is implemented runs without an approval gate — a draft PR merges nothing and requests no review, and you still review it on GitHub. Every other action (Slack posts, PR approve/request-changes, issue creation, non-draft PRs) always requires explicit approval.

> **Security:** on public `ntfy.sh`, a topic name is effectively a password — anyone who knows your `command_topic` could trigger Slack posts or PR creation. Use long, random topic names, set an `auth_token`, and/or self-host ntfy via `server`. As defense in depth, the listener only accepts `approve`/`reject` decisions, only item ids matching a strict filename pattern, and only acts on items still sitting in `queue/drafts/`.

## Project Structure

### Plugin (this repo)
```
.claude-plugin/plugin.json     Plugin manifest
commands/
  setup.md                     /engineer-agent setup command
  add-project.md               /engineer-agent add-project command
  poll.md                      /engineer-agent poll command
  add-ticket.md                /engineer-agent add-ticket command
  review-queue.md              /engineer-agent review-queue command
  execute.md                   /engineer-agent execute command (headless approve/reject)
  status.md                    /engineer-agent status command
  digest.md                    /engineer-agent digest command
  refine-spec.md               /engineer-agent refine-spec command
  refine-ticket.md             /engineer-agent refine-ticket command
  create-design-doc.md         /engineer-agent create-design-doc command
  create-tickets.md            /engineer-agent create-tickets command
  audit-gaps.md                /engineer-agent audit-gaps command
  qa.md                        /engineer-agent qa command
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
  generate-qa/SKILL.md         QA test plan generation
  execute-item/SKILL.md        Shared approve/reject action logic (terminal + remote)
references/
  routing-ladder.md            Shared ticket→project routing logic (poll-jira, poll-github-issues, add-ticket)
scripts/
  cron-poll.sh                 Cron polling script
  install-cron.sh              Cron setup script
  notify.sh                    Publish a push notification to ntfy
  approval-listener.sh         Long-running ntfy command-topic subscriber (remote approval)
  install-listener.sh          Installs the approval listener as a service
  lib-ntfy.sh                  Shared ntfy config resolution (sourced by the above)
  lib-paths.sh                 Runtime data location — single source of truth (EA_AGENT_DIR)
  migrate-storage.sh           One-time move off the legacy ~/.claude/engineer-agent/ path
config/
  engineer.example.yaml        Configuration template
```

### User-level data
```
~/.local/share/engineer-agent/
  engineer.yaml                User config (all projects in one file)
  auth.env                     (optional, mode 600) CLAUDE_CODE_OAUTH_TOKEN for headless runs
  queue/
    incoming/                  Newly detected items (all projects)
    drafts/                    Items with drafted responses
    completed/                 Approved and posted
    rejected/                  Rejected with reason
  state/
    last-poll.yaml             Dedup timestamps and seen IDs (per project + per Jira project key)
    last-poll-receipt.yaml     Liveness receipt from the last cron poll (run_id, status, item count, errors)
    ntfy-seen.yaml             Processed ntfy command message IDs (remote-approval dedup)
    ntfy-listener.since        Last-seen ntfy command timestamp (listener stream resume point)
    approval-listener.log      Listener activity log
```

## Maintenance

When adding, changing, or removing commands, skills, config options, or integrations, check both `CLAUDE.md` and `README.md` for needed updates. Keep both files in sync with each other and with actual plugin behavior.
