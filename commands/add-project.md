---
description: "Register the current project with engineer-agent"
model: haiku
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "AskUserQuestion"]
---

# Engineer Agent: Add Project

Register the current project directory in the user-level engineer-agent config.

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` first and stop.

### 2. Check for Duplicate

Get the absolute path of the current directory via `pwd`.

Check if any existing project entry in `projects` already has a `path` matching this directory. If so, report:
> This project is already registered as "{slug}". Run `/engineer-agent status` to check health.

Stop here.

### 3. Auto-Detect Project Details

1. Run `basename $(pwd)` to derive a default slug
2. Run `git remote get-url origin 2>/dev/null` to detect the GitHub remote
3. Parse the remote URL to extract `owner` and `repo` name

### 4. Prompt for Details

Ask the user to confirm or customize:
- **Slug** (default: derived from directory name) — must be a simple identifier (letters, numbers, hyphens)
- **GitHub owner/repos** (default: auto-detected from git remote)
- **Ticket tracker:** "What ticket tracker does this project use?" with options:
  - **GitHub Issues** — prompt for `assignee` (default: GitHub username from `gh api user --jq .login`), optional `labels` filter. Write `tracker: github-issues` and `github.issues` sub-config.
  - **Jira** — prompt for one or more Jira project sources (see Jira source loop below), then `assignee` and `statuses`. Write `tracker: jira` and `jira` section with `sources` array.
  - **None / skip** — write `tracker: none`, skip ticket tracker config.
- Whether they want to configure Slack and/or Slite integrations for this project

For each integration the user wants to configure, ask for the required fields. For integrations they skip, omit that section from the project entry.

**Jira source loop** (when user selects Jira as tracker):

1. Ask "Which Jira project(s) should this project watch?"
2. For the first source, prompt:
   - **Jira project key** (required, e.g., "ENG")
   - **Components** (optional, comma-separated) — only match tickets with these Jira components
   - **Labels** (optional, comma-separated) — only match tickets with these Jira labels
3. After each source, ask "Add another Jira project source?" — loop until the user says no
4. Then prompt for shared settings:
   - **Assignee** (default: email from `gh api user --jq .email` or ask)
   - **Statuses** (default: `["To Do", "In Progress"]`)

### 5. Update Config

Use Edit to append the new project entry to the `projects` map in `~/.local/share/engineer-agent/engineer.yaml`.

The new entry should follow this structure:

```yaml
  {slug}:
    path: "{absolute_path}"
    tracker: "{github-issues|jira|none}"
    github:
      owner: "{owner}"
      repos: ["{repo}"]
      review_requested_for: "{username}"
      ignore_labels: ["wip", "draft"]
      # Include issues section only if tracker is github-issues
      issues:
        assignee: "{username}"
        labels: []
    # Include jira section only if tracker is jira
    jira:
      sources:
        - project: "{JIRA_KEY}"
          components: ["{component}"]    # omit if empty
          labels: ["{label}"]            # omit if empty
        # additional sources if configured
      assignee: "{email}"
      statuses: ["{status1}", "{status2}"]
    # Include slack/slite sections only if the user configured them
```

### 6. Initialize State Entry

Read `~/.local/share/engineer-agent/state/last-poll.yaml`. Add entries for the new project:

1. Add a `projects.<slug>` entry with initial state:

```yaml
projects:
  {slug}:
    github:
      last_checked: "1970-01-01T00:00:00Z"
      seen_prs: []
    slack:
      last_checked_ts: "0"
    jira:
      seen_tickets: []
    github_issues:
      last_checked: "1970-01-01T00:00:00Z"
      seen_issues: []
    slite:
      last_checked: "1970-01-01T00:00:00Z"
      seen_docs: []
```

Only include sections for integrations the user configured. Include `github_issues` if tracker is `github-issues`, `jira` if tracker is `jira`.

2. If tracker is `jira`, also add entries to the top-level `jira_projects` section for each Jira project key in the sources (if not already present):

```yaml
jira_projects:
  {JIRA_KEY}:
    last_checked: "1970-01-01T00:00:00Z"
```

### 7. Print Summary

```
Project "{slug}" registered!

  Path:    {absolute_path}
  GitHub:  {owner}/{repo}
  Tracker: {GitHub Issues | Jira | not configured}
  Slack:   {configured | not configured}
  Slite:   {configured | not configured}

Run /engineer-agent poll to start polling this project's sources.
```
