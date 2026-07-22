---
description: "Show engineer-agent status: queue counts, last poll times, config health"
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
---

# Engineer Agent Status

Show the current status of the engineer-agent system.

## Steps

### 1. Check Config

Read the config file at `~/.local/share/engineer-agent/engineer.yaml`.

If it does not exist, report:
> Config not found. Run `/engineer-agent setup` to initialize engineer-agent.

If it exists, confirm: "Config loaded." List the registered project slugs from the `projects` map.

### 2. Queue Counts

Count files (excluding .gitkeep) in each queue directory under `~/.local/share/engineer-agent/queue/`:

- `incoming/` — items detected but not yet processed
- `drafts/` — items processed, awaiting human approval
- `completed/` — approved and posted
- `rejected/` — human rejected

Display as a summary table:

```
| Queue     | Count |
|-----------|-------|
| Incoming  | N     |
| Drafts    | N     |
| Completed | N     |
| Rejected  | N     |
```

### 3. Last Poll Times

Read `~/.local/share/engineer-agent/state/last-poll.yaml` if it exists. Display the last poll time for each project and each source within that project:

```
| Project  | GitHub             | Slack              | Jira               | Slite              |
|----------|--------------------|--------------------|--------------------|--------------------|
| my-api   | 2h ago             | 2h ago             | 2h ago             | 2h ago             |
| my-app   | 45m ago            | not configured     | 45m ago            | not configured     |
```

If the file doesn't exist, report "No polls have run yet."

### 3b. Last Poll Health

Read `~/.local/share/engineer-agent/state/last-poll-receipt.yaml` if it exists — the liveness
receipt the cron writes as the final step of each run. Report `finished_at`, `status`,
`items_queued`, any `errors`, and the `skipped` count:

```
Last poll: 2026-07-15T20:31:45Z — status: ok, 0 items queued — 12 sources skipped (not configured)
```

`status: ok` with `items_queued: 0` is **healthy** — it means the poll ran and legitimately found
nothing. `skipped` entries are sources that aren't configured/enabled for a project (e.g. Jira on a
github-issues project, Slack with no channels); they are **normal** and never a problem — report the
count for transparency but do not flag them. Flag only `status: partial` / `status: error` and any
`errors` entries (a *configured* source that failed). If the
file is missing, report "No poll has completed since the liveness receipt was introduced." (Note:
this is distinct from §3's per-source `last_checked` timestamps — those are dedup cutoffs, this is
whether the last run actually finished.)

### 4. Slack Health

If any project has a `slack` section configured, verify the effective Slack backend is usable.
Resolve the method from `agent.slack.method` (default `spy`):

**method: spy**
1. Resolve the binary (`agent.slack.bin`, default `spy`) and check it is on `PATH`
   (`command -v <bin>`). If missing, report: "Spy CLI not found — install from
   https://github.com/tomharris/spy and ensure it's on PATH."
2. Run `<bin> auth --json -w <agent.slack.workspace>` (omit `-w` if unset). Report the
   signed-in user/team on success, or the error (e.g. "multiple workspaces signed in; set
   agent.slack.workspace") on failure.

**method: mcp-proxy**
1. The binary is the bundled `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh`; check `curl` and
   `jq` are on `PATH`.
2. Run `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh auth --json`. On success (`{"ok": true}`)
   report "Slack MCP proxy reachable". If it exits `75` (`{"skipped": true}`), report "Slack
   MCP token expired — will resume when Claude Code re-auths" as an **informational** state,
   not a failure. Any other non-zero exit is a real error — surface its message.

### 5. Summary

Give a one-line summary: "N items awaiting review across M projects. Run `/engineer-agent review-queue` to review drafts."
