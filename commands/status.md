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

### 2. Queue counts, poll times, and receipt health

Run:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/queue-status.sh
```

Print its output. **Do not recompute any of it.** The script counts the queue directories, renders
each source's last-poll time as a relative age, and applies the receipt-reading rules — including
the two that are easy to get wrong: `status: ok` with `items_queued: 0` is **healthy**, and a
non-empty `skipped:` list is **normal** and is never a problem. It also reports items stranded in
`incoming/` without a draft, which are invisible to every approval path until drafted.

`--json` is available if you need the numbers rather than the table.

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
