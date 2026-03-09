---
description: "Set up engineer-agent in the current project"
allowed-tools: ["Bash", "Read", "Write", "Glob"]
---

# Engineer Agent Setup

Initialize engineer-agent in the current project: copy config, create directories, and install cron polling.

## Steps

### 1. Check for Existing Setup

Read `.claude/engineer-agent/engineer.yaml` in the current project.

If it exists, report:
> Engineer-agent is already set up in this project. Run `/engineer status` to check health.

Stop here — do not continue to further steps.

### 2. Resolve Plugin Root

Find the engineer-agent plugin installation path using two strategies:

**Strategy A — Installed plugins registry:**

Read `~/.claude/plugins/installed_plugins.json`. Parse the JSON and look for a key in the `plugins` object that starts with `engineer-agent`. Extract its `installPath` value.

**Strategy B — Fallback for dev mode:**

If `installed_plugins.json` doesn't exist or doesn't contain engineer-agent, use Glob to search for `.claude-plugin/plugin.json` files that are siblings to a `config/engineer.example.yaml`. Check these locations:
- The parent of the commands directory that contains this very command
- `~/.claude/plugins/engineer-agent/`
- Common development paths

If neither strategy works, ask the user: "Could not locate the engineer-agent plugin. Please provide the path to the plugin root directory."

Store the resolved path as `PLUGIN_ROOT` for subsequent steps.

### 3. Copy Config Template

Read `{PLUGIN_ROOT}/config/engineer.example.yaml`.

Create the directory `.claude/engineer-agent/` if it doesn't exist (use `mkdir -p` via Bash).

Write the template contents to `.claude/engineer-agent/engineer.yaml` in the current project.

### 4. Run install-cron.sh

Execute via Bash:

```bash
bash {PLUGIN_ROOT}/scripts/install-cron.sh {PROJECT_DIR}
```

Where `{PROJECT_DIR}` is the current working directory (use `pwd` to resolve it).

This script handles:
- Creating `queue/{incoming,drafts,completed,rejected}` directories
- Creating `state/` directory
- Initializing `state/last-poll.yaml`
- Installing crontab entry (default 15-minute interval)

### 5. Print Summary

Display this summary:

```
Engineer-agent setup complete!

  Config:  .claude/engineer-agent/engineer.yaml
  Queue:   .claude/engineer-agent/queue/{incoming,drafts,completed,rejected}
  State:   .claude/engineer-agent/state/last-poll.yaml
  Cron:    Polling every 15 minutes

Next steps:
  1. Edit .claude/engineer-agent/engineer.yaml with your GitHub org, repos, Slack channels, Jira project, etc.
  2. Run /engineer status to verify everything is working.
```
