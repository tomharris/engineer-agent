# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

engineer-agent — A Claude Code plugin that automates senior software engineer tasks with an approval-gated workflow. The agent drafts PR reviews, Slack answers, ticket implementations, doc reviews, and standup updates. The human reviews and approves via `/engineer-agent review-queue` before anything is posted externally — or, with ntfy configured, approves remotely from a phone (see "Notifications & Remote Approval").

A few commands sit outside the approval queue because they produce read-only planning artifacts rather than external posts. `/engineer-agent uat-plan <refs...>` is one: it turns a list of GitHub issues / Jira tickets (expanding any Jira parent into its descendants) into a User Acceptance Testing checklist — a markdown table of user-facing tests with expected results, grouped by feature area — then prints it and saves a copy under `~/.claude/engineer-agent/uat-plans/`. It works from ticket text only (no repo or queue involvement).

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
scripts/                       — Cron polling, ntfy notify/listener, and setup scripts
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
├── uat-plans/                 — Saved UAT checklists from /engineer-agent uat-plan (not part of the queue)
└── state/
    ├── last-poll.yaml         — Dedup timestamps and seen IDs (per project + per Jira project key)
    └── ntfy-seen.yaml         — Processed ntfy command message IDs (remote-approval dedup)
```

## Config Loading Pattern

Every skill and command that needs config should start by reading `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

The config has two top-level sections:
- `agent` — global settings (branch_prefix, max_pr_files, channels, cron interval, `autonomy`, `notify`)
- `projects` — a map of project slugs to per-project integration config

Two `agent` subsections drive autonomy (both optional):
- `agent.autonomy.auto_execute` — a list of action tiers allowed to run **without** an approval gate. Only `draft-pr` is supported (draft PRs merge nothing / request no review). Absent ⇒ empty ⇒ everything is gated.
- `agent.notify.ntfy` — push-notification + remote-approval settings (`server`, `topic`, `command_topic`, `auth_token`). Absent ⇒ no notifications; the workflow is otherwise unchanged.

Slack access uses the Spy CLI (`agent.slack`, optional):
- `agent.slack.bin` — path to the `spy` binary. Effective binary = `agent.slack.bin` ?? `spy` (on PATH).
- `agent.slack.workspace` — default Slack workspace. Effective workspace = `projects.<slug>.slack.workspace` ?? `agent.slack.workspace` ?? Spy's own default. Pass it as `-w <workspace>` on every `spy` call (Spy errors when multiple workspaces are signed in and no default is set).

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
- **Summary-prefix routing (takes precedence):** if a ticket summary starts with `[<token>]` (e.g. `[payroll-workflows] - …`) and exactly one watching project's slug or `github.repos` entry equals `<token>` (case-insensitive), the ticket routes to that project regardless of components/labels. This disambiguates teams that share one Jira project key with no distinguishing components/labels. A prefix matching zero or multiple watchers is ignored and falls through to component/label matching.
- Tickets matching zero or multiple projects are created as `_unrouted` for manual assignment

### QA Documentation Config

The `qa` subsection drives QA test plans: `base_url` and `console_command` (used during generation), plus optional documentation keys `document_to` (`"slite"` | empty — empty/absent disables) and `document_parent` (Slite channel/note id; empty ⇒ the user's private personal channel). When `document_to: slite`, a completed QA plan (review-queue Phase 3) is published to Slite as one note containing the full plan, the inlined `qa-test.sh` script, and the execution results — best-effort, never blocking completion.

## Queue File Format

Items enter the queue either via polling (`/engineer-agent poll` or the cron) or manually (`/engineer-agent add-ticket <ref>`). Both paths produce identically-shaped queue files.

Files move through: `~/.claude/engineer-agent/queue/incoming/` → `queue/drafts/` → `queue/completed/` or `queue/rejected/`

Filename: `{YYYYMMDD-HHmmss}-{type}-{short-id}.md`

YAML frontmatter fields:
- `type`: pr-review | slack-question | ticket | doc-review | spec-refinement | design-doc | ticket-plan | ticket-refinement | gap-audit | qa-test-plan | code-audit-finding | codify-candidate
- `source`: github | slack | jira | slite | audit | internal
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
- `audit_category`: (code-audit-finding only) `security` | `correctness` | `secret` | `dependency`
- `audit_severity`: (code-audit-finding only) `critical` | `high` | `medium` | `low`
- `audit_confidence`: (code-audit-finding only) `medium` | `high` (low is filtered out)
- `audit_file`: (code-audit-finding only) repo-relative path to the offending file
- `audit_line_range`: (code-audit-finding only) e.g. `"42-58"`
- `codify_target`: (codify-candidate only) `memory-file` | `skill-note` | `claude-md`
- `codify_path`: (codify-candidate only) absolute path of the file the learning will be written to on approval

Body sections:
- `## Context` — metadata about the work item. For ticket/implementation items this leads with
  an `### Intent` block (Goal / Key constraints / Definition of done / Non-goals) synthesized
  from the ticket so the session and PR are self-contained intent artifacts.
- `## Draft Response` — filled by the processing skill. Review/QA/implementation items carry a
  `### Findings & Disposition` ledger (Source | Finding | Disposition | Note) that records how
  each surfaced finding was resolved (`fixed` / `accepted-risk` / `deferred` / `real-bug-filed`
  / `not-executed` / `n/a`), closing the verify→integrate loop; `execute-item` ensures it is
  filled before an item moves to `completed/`.

## Notifications & Remote Approval

ntfy turns the approval gate into a remote, async one without a custom server. Both directions are ntfy topics:

- **Outbound** (`topic`): after a poll, `cron-poll.sh` calls `scripts/notify.sh` to push each new draft with **Approve / Reject / Open** action buttons.
- **Inbound** (`command_topic`): the Approve/Reject buttons are ntfy `http` actions that POST `approve|<item-id>` / `reject|<item-id>` back to the command topic. `scripts/approval-listener.sh` (a long-running service installed by `scripts/install-listener.sh`) streams that topic and runs `/engineer-agent execute <item-id> <decision>` headlessly.

Both `cron-poll.sh` and `approval-listener.sh` resolve the Claude Code binary from `PATH` by default, but honor a `CLAUDE_BIN` env var override (a specific shim/wrapper/install path). Because cron, systemd, and launchd do not inherit the interactive shell environment, `install-cron.sh` and `install-listener.sh` capture `CLAUDE_BIN` when set at install time and bake it into the crontab entry / systemd `Environment=` / launchd `EnvironmentVariables` so the supervised runs use the same binary.

Key invariant: **`/engineer-agent review-queue` (terminal) and `/engineer-agent execute` (remote) both delegate to the shared `execute-item` skill** — the single source of truth for what approving an item does. `qa-test-plan` is interactive-only and is refused on the remote path. (The `generate-qa` skill, when the app is reachable at `qa.base_url`, also runs its generated script and fixes failing scripted tests in place — fixing test defects but leaving genuine code-bug failures as reported findings, never demoting them to the manual checklist; best-effort, it skips execution and reports when the app is unreachable.) `scripts/lib-ntfy.sh` is the shared config reader sourced by `notify.sh` and `approval-listener.sh`.

**Security:** on public `ntfy.sh` a topic name is effectively a password (the `command_topic` can trigger Slack posts / PR creation). Use high-entropy names, set `auth_token`, and/or self-host via `server`. The listener also defends in depth: it only accepts `approve`/`reject`, only item ids matching `^[A-Za-z0-9._-]+$`, and only acts on items still in `queue/drafts/` (idempotent via `state/ntfy-seen.yaml`).

## Available Integrations

- GitHub (PRs and Issues): `gh` CLI via Bash (requires `gh auth login`)
- Slack: the [Spy](https://github.com/tomharris/spy) CLI (`spy`) via Bash — reuses the local
  Slack desktop session (no OAuth/app install). Reads with `spy read`/`spy thread`, posts
  with `spy send` (`--thread <ts>` for threaded replies). Same binary works in interactive
  skills and the headless cron/ntfy scripts.
- Jira: `mcp__atlassian__*` tools (optional — either Jira or GitHub Issues per project)
- Slite: `mcp__slite__*` tools
- ntfy (optional): push notifications + remote approval via `curl` (publish) and `scripts/approval-listener.sh` (subscribe). Listener requires `jq`.

## Documentation Maintenance

When any command, skill, config option, queue format, or integration is added, changed, or removed, check both `CLAUDE.md` and `README.md` for needed updates. These two files must stay in sync with each other and with the actual plugin behavior.
