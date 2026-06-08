---
description: "Show engineer-agent status: queue counts, last poll times, config health"
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
---

# Engineer Agent Status

Show the current status of the engineer-agent system.

## Steps

### 1. Check Config

Read the config file at `~/.claude/engineer-agent/engineer.yaml`.

If it does not exist, report:
> Config not found. Run `/engineer-agent setup` to initialize engineer-agent.

If it exists, confirm: "Config loaded." List the registered project slugs from the `projects` map.

### 2. Queue Counts

Count files (excluding .gitkeep) in each queue directory under `~/.claude/engineer-agent/queue/`:

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

Read `~/.claude/engineer-agent/state/last-poll.yaml` if it exists. Display the last poll time for each project and each source within that project:

```
| Project  | GitHub             | Slack              | Jira               | Slite              |
|----------|--------------------|--------------------|--------------------|--------------------|
| my-api   | 2h ago             | 2h ago             | 2h ago             | 2h ago             |
| my-app   | 45m ago            | not configured     | 45m ago            | not configured     |
```

If the file doesn't exist, report "No polls have run yet."

### 4. Slack (Spy) Health

If any project has a `slack` section configured, verify the Spy CLI is usable:

1. Resolve the binary (`agent.slack.bin`, default `spy`) and check it is on `PATH`
   (`command -v <bin>`). If missing, report: "Spy CLI not found — install from
   https://github.com/tomharris/spy and ensure it's on PATH."
2. Run `<bin> auth --json -w <agent.slack.workspace>` (omit `-w` if unset). Report the
   signed-in user/team on success, or the error (e.g. "multiple workspaces signed in; set
   agent.slack.workspace") on failure.

### 5. Summary

Give a one-line summary: "N items awaiting review across M projects. Run `/engineer-agent review-queue` to review drafts."
