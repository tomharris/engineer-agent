---
description: "Show engineer-agent status: queue counts, last poll times, config health"
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
---

# Engineer Agent Status

Show the current status of the engineer-agent system.

## Steps

### 1. Check Config

Read the config file at `.claude/engineer-agent/engineer.yaml`.

If it does not exist, report:
> Config not found. Copy `config/engineer.example.yaml` from the plugin to `.claude/engineer-agent/engineer.yaml` in your project and fill in your values.

If it exists, confirm: "Config loaded."

### 2. Queue Counts

Count files (excluding .gitkeep) in each queue directory under `.claude/engineer-agent/queue/`:

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

Read `.claude/engineer-agent/state/last-poll.yaml` if it exists. Display the last poll time for each source (github, slack, jira, slite). If the file doesn't exist, report "No polls have run yet."

### 4. Summary

Give a one-line summary: "N items awaiting review. Run `/engineer review-queue` to review drafts."
