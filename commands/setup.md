---
description: "Set up engineer-agent at the user level"
model: haiku
allowed-tools: ["Bash", "Read", "Write", "Glob"]
---

# Engineer Agent Setup

Initialize engineer-agent at the user level: create config, directories, install cron, and register the current project.

## Steps

### 1. Check for Existing Setup

Read `~/.local/share/engineer-agent/engineer.yaml`.

If it exists, report:
> Engineer-agent is already set up. Run `/engineer-agent add-project` to register another project, or `/engineer-agent status` to check health.

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

### 3. Auto-Detect Current Project

Detect the current project's details for the first project entry:

1. Run `pwd` to get the absolute project path
2. Run `basename $(pwd)` to derive a default slug
3. Run `git remote get-url origin 2>/dev/null` to detect the GitHub remote
4. Parse the remote URL to extract `owner` and `repo` name
5. Ask the user to confirm or customize the project slug

### 4. Copy and Customize Config Template

Read `{PLUGIN_ROOT}/config/engineer.example.yaml`.

Create `~/.local/share/engineer-agent/` if it doesn't exist (use `mkdir -p` via Bash).

Write the template contents to `~/.local/share/engineer-agent/engineer.yaml`, replacing the example project entry with the auto-detected project details:
- Replace the example slug key with the detected slug
- Replace `path` with the current directory
- Replace `owner` and `repos` with detected GitHub values
- Leave other integration fields as placeholder values for the user to fill in

### 5. Run install-cron.sh

Execute via Bash:

```bash
bash {PLUGIN_ROOT}/scripts/install-cron.sh
```

This script handles:
- Creating `queue/{incoming,drafts,completed,rejected}` directories
- Creating `state/` directory
- Initializing `state/last-poll.yaml` with empty projects map
- Installing crontab entry (default 15-minute interval)

`install-cron.sh` also prints a NOTE when no headless auth token is configured — see the next step.

### 5b. Headless auth caveat (macOS)

The cron poll (and the ntfy approval listener) run **outside the GUI login session** and cannot
read the macOS login keychain, so a supervised run may fail with `Not logged in · Please run /login`.
There is **no environment-credential workaround on a machine with a `forceLoginOrgUUID` managed
policy** — such a policy rejects `ANTHROPIC_API_KEY`, `apiKeyHelper`, *and* a `claude setup-token`
OAuth token, because org membership can't be verified for an environment credential (this was tried
and removed). If the poll fails with a "Not logged in" or "Unable to verify organization" error,
see the headless-auth section of `CLAUDE.md`; the only surviving paths (cloud-provider inference, or
a machine/service-account exemption) require your org's IT.

### 6. Print Summary

Display this summary:

```
Engineer-agent setup complete!

  Config:  ~/.local/share/engineer-agent/engineer.yaml
  Queue:   ~/.local/share/engineer-agent/queue/{incoming,drafts,completed,rejected}
  State:   ~/.local/share/engineer-agent/state/last-poll.yaml
  Cron:    Polling every 15 minutes
  Project: {slug} ({path})

Next steps:
  1. Edit ~/.local/share/engineer-agent/engineer.yaml with your Slack channels, Jira project, etc.
  2. For Slack: install the Spy CLI (https://github.com/tomharris/spy), sign in to the Slack
     desktop app, run `spy auth` to confirm, and set agent.slack.workspace in config.
  3. macOS headless auth: cron cannot read the login keychain. On a forceLoginOrgUUID-managed
     machine there is no environment-credential fix — see CLAUDE.md and work with your org's IT.
  4. Run /engineer-agent add-project from other project directories to register them.
  5. Run /engineer-agent status to verify everything is working.
```
