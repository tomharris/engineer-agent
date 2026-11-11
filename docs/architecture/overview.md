# Overview and plugin structure

## Project

engineer-agent — A Claude Code plugin that automates senior software engineer tasks with an approval-gated workflow. The agent drafts PR reviews, Slack answers, ticket implementations, doc reviews, and standup updates. The human reviews and approves via `/engineer-agent review-queue` before anything is posted externally — or, with ntfy configured, approves remotely from a phone (see "Notifications & Remote Approval").

A few commands sit outside the approval queue because they produce read-only planning artifacts rather than external posts. `/engineer-agent uat-plan <refs...>` is one: it turns a list of GitHub issues / Jira tickets (expanding any Jira parent into its descendants) into a User Acceptance Testing checklist — a markdown table of user-facing tests with expected results, grouped by feature area — then prints it and saves a copy under `~/.local/share/engineer-agent/uat-plans/`. It works from ticket text only (no repo or queue involvement).

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
references/                    — Shared procedural docs skills Read at runtime (routing-ladder.md,
                                 ticket-kind.md, queue-reconciliation.md). These are the SPEC;
                                 scripts/lib-routing.sh and scripts/lib-ticket-kind.sh are the
                                 executable implementation of their deterministic tiers.
hooks/hooks.json               — Claude Code hook registrations (turn-completion pushes)
scripts/                       — Cron polling, ntfy notify/listener, setup scripts, credential
                                 storage, and the deterministic collector stack (see
                                 "Deterministic polling")
tests/                         — Shell test suites; `bash tests/run-all.sh` runs every one
config/engineer.example.yaml   — Config template
```

`references/` holds logic that several skills must apply *identically* — today `routing-ladder.md`
(which project), `ticket-kind.md` (what the ticket delivers), and `queue-reconciliation.md` (whether
an item enters the queue). It is plain markdown read
with `Read`, deliberately not a skill or subagent: `scripts/cron-poll.sh` allowlists `Read` but not
`Skill`/`Agent`, so anything shaped that way is unreachable from the cron — the one path with no
human fallback.

> **Reference these files via `${CLAUDE_PLUGIN_ROOT}`, never a bare relative path.** Cron runs from
> `$HOME`, so `references/routing-ladder.md` resolves to `~/references/…` and the `Read` fails —
> interactively it works fine (cwd is usually the project), so this breaks *only* the unattended
> path, silently. Same convention `skills/audit-code/SKILL.md` uses for `scripts/notify.sh`: prefer
> `${CLAUDE_PLUGIN_ROOT}`, fall back to a path relative to the skill's own directory.

Runtime data lives at the user level in `~/.local/share/engineer-agent/` (override with the
`EA_AGENT_DIR` env var; honors `XDG_DATA_HOME`). `scripts/lib-paths.sh` is the single source
of truth for this location — source it rather than hardcoding the path.

> **Do not move runtime data back under `~/.claude/`.** Claude Code guards everything inside a
> `.claude/` directory as sensitive and refuses the Edit/Write tools there — an explicit
> `--allowedTools "Edit(...)"` rule does **not** override it. The guard is invisible
> interactively (a human just approves the prompt), but silently fatal headlessly: it left both
> `cron-poll.sh` and `approval-listener.sh` unable to record state or move queue files, so the
> cron polled every 15 minutes for a month and never queued a single item. Installs predating
> the move are migrated with `scripts/migrate-storage.sh`.

```
~/.local/share/engineer-agent/
├── engineer.yaml              — User config (one file for all projects)
├── queue/
│   ├── incoming/              — Newly detected items
│   ├── drafts/                — Items with drafted responses
│   ├── completed/             — Approved and posted
│   └── rejected/              — Rejected with reason
├── uat-plans/                 — Saved UAT checklists from /engineer-agent uat-plan (not part of the queue)
├── investigations/            — Archived findings docs from ticket-investigation items (not part of the queue)
└── state/
    ├── last-poll.yaml         — Dedup timestamps and seen IDs (per project, per Jira project key, per GitHub repo)
    ├── last-poll-receipt.yaml — Liveness receipt from the last cron poll (run_id, status, item count, skipped, errors)
    ├── claude-bin.path        — Resolved `claude` executable the last unattended poll ran (macOS TCC preflight)
    ├── ntfy-seen.yaml         — Processed ntfy command message IDs (remote-approval dedup)
    ├── jobs/                  — Per scheduled job (<project>.<id>.*): last-run, receipt, lock, failures, paused, invalid, state.yaml (its own cutoffs), picks (implement-next daily_cap)
    ├── autopilot-items.tsv    — Queue items the implement-next job wrote (the only provenance the listener trusts for a Jira claim)
    ├── implement-inflight/    — One marker per running confined ticket implementation (<pid>\t<project>)
    ├── jira-account-id        — Cached Jira accountId per agent.jira.email
    ├── github-login           — Cached gh login (github-issues implement-next)
    ├── watched-threads.tsv    — Slack threads answered via engineer-agent (channel, thread_ts, last_seen_ts, added_at, project) for the my-threads watch
    ├── slack-events.log       — Outcomes of scripts/slack-event.sh (status reactions, thread watches)
    ├── jobs.log               — Scheduled-jobs dispatcher log
    ├── config-dump.cache      — `ea-config.sh dump` output, keyed by a checksum of the config, the rendering scripts, paused jobs and EA_JOBS_IGNORE_EXCLUSIVE (safe to delete)
    ├── turn-notify/           — One marker per session armed for turn-completion pushes (<session_id>)
    └── turn-notify.log        — Turn-completion hook diagnostics (only when EA_TURN_NOTIFY_DEBUG=1)
```

