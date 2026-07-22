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
- Installing the scheduled poll: a **launchd LaunchAgent** (`engineer-agent-poll`) on macOS, or a
  **crontab entry** on Linux (default 15-minute interval)

If the user runs a non-default `claude` binary, pass `CLAUDE_BIN=/abs/path bash …/install-cron.sh`
so it's baked into the LaunchAgent/crontab. On macOS, to confine polling to business hours (caps
first-poll spend on a large backlog), pass `EA_POLL_HOURS=9,10,11,13,14,15,16 EA_POLL_MINUTE=3`.

### 5b. Headless auth (macOS): launchd, not cron

On macOS the Claude credential lives in the login keychain, which only unlocks *inside* the GUI
login session. A **crontab** poll runs outside that session and fails with `Not logged in`; a
**launchd LaunchAgent** in your GUI session reads the keychain fine — which is why `install-cron.sh`
uses a LaunchAgent on macOS. No token on disk; it only polls while you're logged in.

Separately, if this machine has a `forceLoginOrgUUID` managed policy
(`/Library/Application Support/ClaudeCode/managed-settings.json`), it blocks *all* headless auth —
`ANTHROPIC_API_KEY`, `apiKeyHelper`, and `claude setup-token` alike — and no scheduler choice helps;
the only paths (cloud-provider inference, or an IT exemption) require your org's IT. Do **not** re-add
an `auth.env`/`CLAUDE_CODE_OAUTH_TOKEN` loader. See the headless-auth section of `CLAUDE.md`.

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
  2. For Slack, pick a backend via agent.slack.method:
       • spy (default): install the Spy CLI (https://github.com/tomharris/spy), sign in to the
         Slack desktop app, run `spy auth` to confirm, and set agent.slack.workspace.
       • mcp-proxy (Slack Enterprise Grid, where spy is broken): set agent.slack.method:
         mcp-proxy and agent.slack.mcp.server_id to your Slack connector's mcpsrv id. It reuses
         Claude Code's Keychain OAuth token (needs curl + jq); no spy install. Verify with
         `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh auth`.
  3. macOS headless auth: cron cannot read the login keychain. On a forceLoginOrgUUID-managed
     machine there is no environment-credential fix — see CLAUDE.md and work with your org's IT.
  4. Run /engineer-agent add-project from other project directories to register them.
  5. Run /engineer-agent status to verify everything is working.
```
