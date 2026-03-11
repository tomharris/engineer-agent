---
description: "Register the current project with engineer-agent"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "AskUserQuestion"]
---

# Engineer Agent: Add Project

Register the current project directory in the user-level engineer-agent config.

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer setup` first and stop.

### 2. Check for Duplicate

Get the absolute path of the current directory via `pwd`.

Check if any existing project entry in `projects` already has a `path` matching this directory. If so, report:
> This project is already registered as "{slug}". Run `/engineer status` to check health.

Stop here.

### 3. Auto-Detect Project Details

1. Run `basename $(pwd)` to derive a default slug
2. Run `git remote get-url origin 2>/dev/null` to detect the GitHub remote
3. Parse the remote URL to extract `owner` and `repo` name

### 4. Prompt for Details

Ask the user to confirm or customize:
- **Slug** (default: derived from directory name) — must be a simple identifier (letters, numbers, hyphens)
- **GitHub owner/repos** (default: auto-detected from git remote)
- Whether they want to configure Slack, Jira, and/or Slite integrations for this project

For each integration the user wants to configure, ask for the required fields. For integrations they skip, omit that section from the project entry.

### 5. Update Config

Use Edit to append the new project entry to the `projects` map in `~/.claude/engineer-agent/engineer.yaml`.

The new entry should follow this structure:

```yaml
  {slug}:
    path: "{absolute_path}"
    github:
      owner: "{owner}"
      repos: ["{repo}"]
      review_requested_for: "{username}"
      ignore_labels: ["wip", "draft"]
    # Include slack/jira/slite sections only if the user configured them
```

### 6. Initialize State Entry

Read `~/.claude/engineer-agent/state/last-poll.yaml`. Add an entry under `projects` for the new slug with initial timestamps:

```yaml
projects:
  {slug}:
    github:
      last_checked: "1970-01-01T00:00:00Z"
      seen_prs: []
    slack:
      last_checked_ts: "0"
    jira:
      last_checked: "1970-01-01T00:00:00Z"
      seen_tickets: []
    slite:
      last_checked: "1970-01-01T00:00:00Z"
      seen_docs: []
```

Only include sections for integrations the user configured.

### 7. Print Summary

```
Project "{slug}" registered!

  Path:    {absolute_path}
  GitHub:  {owner}/{repo}
  Slack:   {configured | not configured}
  Jira:    {configured | not configured}
  Slite:   {configured | not configured}

Run /engineer poll to start polling this project's sources.
```
