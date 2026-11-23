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

**Routing hints — ask only when this registration creates ambiguity.**

After the tracker is configured, check whether the Jira project key(s) or the `owner/repo` being
registered are **already watched by another project** in the config:

- Jira: any existing project with a `jira.sources` entry whose `project` equals one of the new keys.
- GitHub Issues: any existing project whose `github.owner` matches and whose `github.repos` contains
  one of the new repos.

**If nothing else watches them, skip this — do not ask.** A sole watcher gets every ticket for that
key/repo unambiguously, and hints would never be consulted.

**If something does**, say which project it collides with and explain that tickets will now have to
be told apart, then ask (both optional, Enter to skip):

- **Description** — one line on what this project covers, e.g. "Paycycle scheduling, voids, and approvals"
- **Keywords** — comma-separated terms that signal this project, e.g. "paycycle, void, payroll"

Write them as a `routing` block on the new entry. Also point out that the colliding project probably
wants hints too — without them, the ladder has nothing to compare against and ambiguous tickets will
land in `_unrouted` for manual assignment. That is a safe outcome, just a manual one.

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
    # Include routing only if hints were collected (i.e. this repo/Jira key is shared)
    routing:
      description: "{description}"
      keywords: ["{keyword1}", "{keyword2}"]
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

### 6. Offer Default Watch Jobs

Do **not** write anything under `state/`. Each watch job keeps its own cutoff file and starts from
the collector's default; queue reconciliation dedups.

Run:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/jobs-default-watch.sh {slug}
```

It prints one `watch` job entry per source this project configures (PR reviews, the tracker,
Slack, Slite), or nothing. If it printed nothing, skip to step 7. Otherwise show the output and ask:

> Add these watch jobs? They discover new work for this project every 15 minutes
> (dispatched by `scripts/jobs-tick.sh`; install with `scripts/install-jobs.sh` if you haven't).

On yes, Edit the new project entry in `engineer.yaml`: add a `    jobs:` line at the end of the entry
followed by the script's output **verbatim** (it is already indented for that position). Do not
hand-write or alter job entries. Then run `${CLAUDE_PLUGIN_ROOT}/scripts/jobs-ctl.sh list` and
report any job it marks `invalid`.

On no, say that `/engineer-agent status` will list its sources as UNCOVERED: nothing discovers
work for it until it has watch jobs (re-run `scripts/jobs-default-watch.sh {slug}` later).

### 7. Print Summary

```
Project "{slug}" registered!

  Path:    {absolute_path}
  GitHub:  {owner}/{repo}
  Tracker: {GitHub Issues | Jira | not configured}
  Slack:   {configured | not configured}
  Slite:   {configured | not configured}
  Jobs:    {ids of the watch jobs added | none}

{If jobs were added:} Run `/engineer-agent jobs` to see when each runs next.
{Otherwise:} Nothing will discover work for this project until it has watch jobs.
```
