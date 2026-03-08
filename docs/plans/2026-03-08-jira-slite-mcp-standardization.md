# Jira & Slite MCP Standardization — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace all curl-based REST API calls in Jira and Slite skills with MCP tool calls, matching the pattern used by GitHub and Slack skills.

**Architecture:** Each poll/processing skill currently calls external APIs via `Bash` + `curl`. We rewrite the "Tools Needed" and "Steps" sections to reference MCP tools directly. Config files are simplified to remove auth-related fields that MCP now handles.

**Tech Stack:** Claude Code plugin skill files (markdown), YAML config

---

### Task 1: Update poll-jira/SKILL.md to MCP-only

**Files:**
- Modify: `.worktrees/implement-plugin/skills/poll-jira/SKILL.md`
- Reference: `.worktrees/implement-plugin/skills/poll-github/SKILL.md` (pattern to follow)

**Step 1: Update the Tools Needed section**

Replace:
```markdown
## Tools Needed

- `Bash` — curl to Jira REST API (or Atlassian MCP if available)
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items
```

With:
```markdown
## Tools Needed

- `mcp__atlassian__searchJiraIssuesUsingJql` — search for tickets by JQL
- `mcp__atlassian__getJiraIssue` — fetch individual ticket details
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items
```

**Step 2: Update Step 1 (Load Config)**

Remove the reference to `jira.base_url` from the config extraction. The line should read:

```markdown
Read `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. Extract `jira.project`, `jira.assignee`, and `jira.statuses`.
```

**Step 3: Rewrite Step 3 (Query Jira)**

Replace the entire "### 3. Query Jira" section. Remove the "Try Atlassian MCP first / Fallback to REST API" dual-path approach and the curl command block. Replace with:

```markdown
### 3. Query Jira

Build a JQL query:
```
project = {project} AND assignee = "{assignee}" AND status IN ({statuses}) AND updated > "{last_checked}"
```

Call `mcp__atlassian__searchJiraIssuesUsingJql` with the JQL query to get matching tickets.

For each ticket that needs detailed information (description, comments), call `mcp__atlassian__getJiraIssue` with the ticket key to fetch full details including:
- summary, description, status, priority, labels
- recent comments
```

Remove the paragraph about `JIRA_EMAIL` and `JIRA_API_TOKEN` environment variables.

**Step 4: Verify the rest of the file**

Confirm steps 4-8 (Filter Results, Create Queue Items, Process Incoming Items, Update State, Report) have no remaining references to curl, Bash, REST API, base_url, or env vars. These steps should be unchanged since they operate on the returned data, not the transport.

**Step 5: Commit**

```bash
git add skills/poll-jira/SKILL.md
git commit -m "refactor(poll-jira): replace curl/REST with Atlassian MCP tools"
```

---

### Task 2: Update poll-slite/SKILL.md to MCP-only

**Files:**
- Modify: `.worktrees/implement-plugin/skills/poll-slite/SKILL.md`
- Reference: `.worktrees/implement-plugin/skills/poll-slack/SKILL.md` (pattern to follow)

**Step 1: Update the Tools Needed section**

Replace:
```markdown
## Tools Needed

- `Bash` — curl to Slite API
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items
```

With:
```markdown
## Tools Needed

- `mcp__slite__search-notes` — search for documents
- `mcp__slite__get-note` — fetch full document content
- `mcp__slite__get-note-children` — navigate document tree
- `Read` — read config and state
- `Write` — create queue items
- `Glob` — check for existing queue items
```

**Step 2: Update Step 1 (Load Config)**

Remove the reference to `slite.api_token_env` and the paragraph about getting the API token from the environment variable. The line should read:

```markdown
Read `${CLAUDE_PLUGIN_ROOT}/config/engineer.yaml`. Extract `slite.doc_labels`.
```

**Step 3: Rewrite Step 3 (Query Slite API)**

Replace the entire "### 3. Query Slite API" section. Remove the curl command block. Replace with:

```markdown
### 3. Query Slite

Call `mcp__slite__search-notes` to search for documents.

Filter results for documents that:
- Have labels matching `slite.doc_labels` (e.g., "needs-review")
- Were updated after `slite.last_checked`
- Are not already in `slite.seen_docs`
- Don't already exist in any queue directory

For each matching document, call `mcp__slite__get-note` with the document ID to fetch the full content.
```

Rename the section header from "Query Slite API" to "Query Slite" (removing "API" since we're no longer calling a REST API directly).

**Step 4: Verify the rest of the file**

Confirm steps 4-7 have no remaining references to curl, Bash, REST API, api_token, or env vars.

**Step 5: Commit**

```bash
git add skills/poll-slite/SKILL.md
git commit -m "refactor(poll-slite): replace curl/REST with Slite MCP tools"
```

---

### Task 3: Update review-doc/SKILL.md to use Slite MCP

**Files:**
- Modify: `.worktrees/implement-plugin/skills/review-doc/SKILL.md`

**Step 1: Update the Tools Needed section**

Replace:
```markdown
- `Bash` — curl to Slite API for fetching/commenting
```

With:
```markdown
- `mcp__slite__get-note` — fetch document content from Slite
- `mcp__slite__append-blocks` — post review comments to Slite documents
```

Remove `Bash` from the tools list entirely (it's only used for curl in this skill).

**Step 2: Verify no curl references remain**

Scan the full file for any references to curl, Bash, REST API, or API tokens. The skill's review logic (steps 1-6) should not reference transport — it operates on document content already in the queue item.

**Step 3: Commit**

```bash
git add skills/review-doc/SKILL.md
git commit -m "refactor(review-doc): replace curl with Slite MCP tools"
```

---

### Task 4: Update commands/poll.md allowed-tools

**Files:**
- Modify: `.worktrees/implement-plugin/commands/poll.md`

**Step 1: Add Jira and Slite MCP tools to allowed-tools**

In the YAML frontmatter, update the `allowed-tools` array. Add these tools after the existing Slack entries:

```yaml
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Agent",
  "mcp__plugin_github_github__list_pull_requests",
  "mcp__plugin_github_github__pull_request_read",
  "mcp__plugin_github_github__get_file_contents",
  "mcp__plugin_github_github__list_commits",
  "mcp__claude_ai_Slack__slack_read_channel",
  "mcp__claude_ai_Slack__slack_read_thread",
  "mcp__claude_ai_Slack__slack_search_public_and_private",
  "mcp__atlassian__searchJiraIssuesUsingJql",
  "mcp__atlassian__getJiraIssue",
  "mcp__slite__search-notes",
  "mcp__slite__get-note",
  "mcp__slite__get-note-children",
  "mcp__slite__append-blocks"]
```

**Step 2: Commit**

```bash
git add commands/poll.md
git commit -m "feat(poll): add Jira and Slite MCP tools to allowed-tools"
```

---

### Task 5: Simplify config/engineer.example.yaml

**Files:**
- Modify: `.worktrees/implement-plugin/config/engineer.example.yaml`

**Step 1: Remove jira.base_url**

Remove the `base_url` line from the jira section. Result:

```yaml
jira:
  project: "ENG"
  assignee: "me@example.com"
  statuses: ["To Do", "In Progress"]
```

**Step 2: Remove slite.api_token_env**

Remove the `api_token_env` line from the slite section. Result:

```yaml
slite:
  doc_labels: ["needs-review"]
```

**Step 3: Commit**

```bash
git add config/engineer.example.yaml
git commit -m "refactor(config): remove auth fields now handled by MCP servers"
```

---

### Task 6: Update CLAUDE.md MCP integrations section

**Files:**
- Modify: `.worktrees/implement-plugin/CLAUDE.md`
- Modify: `CLAUDE.md` (root — if it mirrors the worktree version)

**Step 1: Update the Available MCP Integrations section**

Replace:
```markdown
## Available MCP Integrations

- GitHub: `mcp__plugin_github_github__*` tools
- Slack: `mcp__claude_ai_Slack__*` tools
- Jira: Atlassian MCP if available, fallback to REST API via curl
- Slite: REST API via curl (no MCP available)
```

With:
```markdown
## Available MCP Integrations

- GitHub: `mcp__plugin_github_github__*` tools
- Slack: `mcp__claude_ai_Slack__*` tools
- Jira: `mcp__atlassian__*` tools
- Slite: `mcp__slite__*` tools
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update MCP integrations to reflect all-MCP architecture"
```
