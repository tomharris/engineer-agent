---
description: "Show engineer-agent status: queue counts, discovery coverage, job health"
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

### 2. Queue counts, discovery coverage, and job health

Run:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/queue-status.sh
```

Print its output. **Do not recompute any of it.** The script counts the queue directories and
reports both stranding shapes — items in `incoming/` **without** a draft (invisible until drafted;
the owning watch job re-emits them) and items in `incoming/` **with a finished draft** (done, but
unreachable by every approval path; queue hygiene moves these to `drafts/`, so a non-zero count
means the move was declined) — and any duplicate `(type, source_id)` groups that auto-healing
declined to resolve. Hygiene pushes about each of those exactly once, so `status` is where a
standing duplicate stays visible.

It then prints a "Discovery" section (per project / source: when a watch job last checked it, and
which job), a "Job health" line, and a "Scheduled jobs" table (from `scripts/jobs-ctl.sh list`).
Call out every **UNCOVERED** source — configured, but no valid, unpaused watch job, so nothing
discovers new work there — and every job listed under "Job health" (paused, invalid, partial or
error); the dispatcher skips or fails those silently every minute. With no jobs at all it says so:
nothing discovers new work.

`--json` is available if you need the numbers rather than the table: it includes `jobs` counts and
`uncovered`, not the per-job detail.

### 3. Check Integrations

For each configured integration, verify the CLI is reachable:

- **GitHub**: `gh auth status`
- **Slack**: the effective Slack binary's `auth` verb (`spy auth`, or `scripts/slack-mcp.sh auth`).
  Exit code **75** means the token is expired and the source will be skipped cleanly — that is
  informational, not a failure.
- **Jira / Slite**: report whether the MCP tools are available in this session.

### 4. Summary

One line: how many items await review, across how many projects, and whether anything in step 2 or
3 needs attention.
