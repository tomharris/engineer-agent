# Design: Standardize Jira & Slite on MCP

**Date:** 2026-03-08
**Status:** Approved

## Problem

The engineer-agent plugin uses two different integration patterns:
- **MCP-native** (GitHub, Slack): Skills call MCP tools directly, auth handled by MCP server config
- **Curl-based** (Jira, Slite): Skills use `Bash` with `curl`, requiring env vars for auth

This inconsistency means Jira and Slite skills are harder to maintain, require separate auth management, and don't benefit from MCP's built-in error handling and type safety.

## Goal

Convert all Jira and Slite integrations to use their respective MCP servers, matching the pattern already established by GitHub and Slack skills.

## MCP Tool Mapping

### poll-jira/SKILL.md

| Current (curl) | Replacement (MCP) |
|---|---|
| `curl ... /rest/api/3/search?jql=...` | `mcp__atlassian__searchJiraIssuesUsingJql` |
| Fetching individual ticket details | `mcp__atlassian__getJiraIssue` |

### poll-slite/SKILL.md

| Current (curl) | Replacement (MCP) |
|---|---|
| `curl ... /v1/notes` | `mcp__slite__search-notes` |
| Fetching full document content | `mcp__slite__get-note` |
| Navigating document tree | `mcp__slite__get-note-children` |

### review-doc/SKILL.md

| Current (curl) | Replacement (MCP) |
|---|---|
| `Bash — curl to Slite API for fetching` | `mcp__slite__get-note` |
| `Bash — curl to Slite API for commenting` | `mcp__slite__append-blocks` |

## Config Simplification

### jira section (engineer.example.yaml)

Remove `base_url` — the Atlassian MCP server already knows the instance. Remove need for `JIRA_EMAIL` and `JIRA_API_TOKEN` env vars.

```yaml
# Before
jira:
  base_url: "https://myorg.atlassian.net"
  project: "ENG"
  assignee: "me@example.com"
  statuses: ["To Do", "In Progress"]

# After
jira:
  project: "ENG"
  assignee: "me@example.com"
  statuses: ["To Do", "In Progress"]
```

### slite section (engineer.example.yaml)

Remove `api_token_env` — the Slite MCP server handles authentication.

```yaml
# Before
slite:
  api_token_env: "SLITE_API_TOKEN"
  doc_labels: ["needs-review"]

# After
slite:
  doc_labels: ["needs-review"]
```

## Structural Changes

### commands/poll.md — allowed-tools

Add Jira and Slite MCP tools to the allowed-tools list:

```
mcp__atlassian__searchJiraIssuesUsingJql
mcp__atlassian__getJiraIssue
mcp__slite__search-notes
mcp__slite__get-note
mcp__slite__get-note-children
mcp__slite__append-blocks
```

### CLAUDE.md — Available MCP Integrations

Update the Jira entry from "Atlassian MCP if available, fallback to REST API via curl" to MCP-native.
Update the Slite entry from "REST API via curl (no MCP available)" to MCP-native.

## Files to Modify

| File | Change |
|---|---|
| `skills/poll-jira/SKILL.md` | Replace curl + MCP fallback with MCP-only |
| `skills/poll-slite/SKILL.md` | Replace curl with Slite MCP tools |
| `skills/review-doc/SKILL.md` | Replace curl tools with Slite MCP tools |
| `commands/poll.md` | Add Jira/Slite MCP tools to allowed-tools |
| `config/engineer.example.yaml` | Remove base_url (jira), api_token_env (slite) |
| `CLAUDE.md` | Update Available MCP Integrations section |

## What Stays the Same

- Queue file format — unchanged
- Dedup state logic — unchanged
- Priority mapping for Jira — unchanged
- `implement-ticket` skill — already uses GitHub MCP, no Jira curl calls
- All downstream processing skills — unaffected
