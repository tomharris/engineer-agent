---
description: "Detect gaps between spec, design doc, and tickets in the pipeline"
argument-hint: "<url-or-key> [--project <slug>] [--boundary <spec-design|design-tickets|all>]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion", "Agent",
  "mcp__slite__get-note", "mcp__slite__search-notes",
  "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__getJiraIssue"]
---

# Engineer Agent: Audit Gaps

Detect mismatches between pipeline artifacts (spec ↔ design doc ↔ tickets) and produce checklist-style queue items for each boundary checked.

## Arguments

- `$ARGUMENTS` should contain a Slite URL/ID, Jira key (e.g. `ENG-123`), or GitHub issue URL
- `$ARGUMENTS` may contain `--project <slug>` to associate with a specific project
- `$ARGUMENTS` may contain `--boundary <spec-design|design-tickets|all>` to limit which boundaries to check (default: `all`)

## Steps

### 1. Load Config

Read `~/.claude/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer setup` and stop.

### 2. Determine Project

If `--project <slug>` is specified, use that slug. Otherwise, try to infer the project from the current working directory by matching against `projects.<slug>.path` values in config. If no match, ask the user which project this belongs to (list available slugs).

### 3. Parse Input

Extract the artifact identifier from `$ARGUMENTS`:
- **Slite URL** (e.g. `https://futuresinc.slite.com/api/s/note/...` or `https://futuresinc.slite.com/p/note/...`): extract the note ID from the path, fetch via `mcp__slite__get-note`
- **Bare Slite ID**: fetch via `mcp__slite__get-note`
- **Jira key** (e.g. `ENG-123`): fetch via `mcp__atlassian__getJiraIssue`
- **GitHub issue URL** (e.g. `https://github.com/org/repo/issues/42`): fetch via `gh issue view {number} --repo {owner}/{repo} --json title,body,labels`
- If no argument provided, ask the user for a URL or key

Parse `--boundary` if present (default: `all`).

### 4. Identify Artifact Type

Determine whether the input is a spec, design doc, or ticket:

1. **Check completed queue items first** — search `~/.claude/engineer-agent/queue/completed/` for files whose `source_id` or `source_url` matches the input. The `type` field tells us what it is:
   - `spec-refinement` → input is a spec
   - `design-doc` → input is a design doc
   - `ticket-plan` → input is related to tickets

2. **If no queue trail**, ask the user: "Is this a spec, design doc, or ticket?" using AskUserQuestion.

### 5. Discover Related Artifacts

Find related artifacts in both directions based on what we're starting from:

**Starting from a spec:**
- **Spec**: already have it
- **Design doc**: search `~/.claude/engineer-agent/queue/completed/` for `*-design-doc-*.md` files. Read each file's frontmatter and check if `source_id` matches `slite:{doc_id}`, or if the `## Context` references the spec URL. Also try `mcp__slite__search-notes` with the spec title as a fallback.
- **Tickets**: search `~/.claude/engineer-agent/queue/completed/` for `*-ticket-plan-*.md` files. Check if they link to the discovered design doc. Also search the tracker (Jira JQL or `gh issue list --search`) using keywords from the spec title.

**Starting from a design doc:**
- **Spec**: search `~/.claude/engineer-agent/queue/completed/` for `*-spec-refinement-*.md` or `*-design-doc-*.md` files that reference this doc ID. The `design-doc` queue item may contain a `spec_refinement_id` that links back to the spec. Also try `mcp__slite__search-notes` with keywords.
- **Design doc**: already have it
- **Tickets**: search `~/.claude/engineer-agent/queue/completed/` for `*-ticket-plan-*.md` files whose `design_doc_id` matches `slite:{doc_id}`. Also search the tracker using keywords.

**Starting from a ticket:**
- Trace backward through `~/.claude/engineer-agent/queue/completed/`:
  - Find `*-ticket-plan-*.md` items related to this ticket (by tracker keyword search or `source_id` pattern)
  - From ticket-plan, extract `design_doc_id` to find the design doc
  - From design-doc queue item, extract `spec_refinement_id` to find the spec
- **Tickets**: fetch all related tickets from the tracker (Jira JQL or `gh issue list --search`)

**Primary discovery**: search `~/.claude/engineer-agent/queue/completed/` by filename pattern and `source_id` matching.
**Fallback**: Slite search (`mcp__slite__search-notes`), tracker search.

### 6. Confirm with User

Display what was found:

```
Found artifacts:
- Spec: "{title}" ({url})
- Design doc: "{title}" ({url})
- Tickets: {N} tickets in {tracker}

Boundaries to check: spec ↔ design, design ↔ tickets
Proceed?
```

If some artifacts weren't found, note which boundaries can't be checked. Ask the user if they want to provide a URL manually for any missing artifacts, or proceed with only the boundaries that are possible.

Use AskUserQuestion for confirmation.

### 7. Create Queue Items

For each applicable boundary, create a queue item in `~/.claude/engineer-agent/queue/incoming/`.

Generate a timestamp. Use a short ID derived from the starting artifact (first 8 chars of doc ID, or ticket key).

**For `spec-design` boundary:**

Filename: `{YYYYMMDD-HHmmss}-gap-audit-sd-{short-id}.md`

```yaml
---
type: gap-audit
source: slite
source_url: "{starting artifact url}"
source_id: "gap:spec-design:{short-id}"
title: "Gap Audit: Spec vs Design — {feature name}"
boundary: "spec-design"
priority: normal
created_at: "{ISO 8601}"
status: incoming
project: "{slug}"
left_url: "{spec url}"
right_url: "{design doc url}"
---

## Context

### Left Artifact: Spec
**Title:** {spec title}
**URL:** {spec url}

{full spec content}

### Right Artifact: Design Doc
**Title:** {design doc title}
**URL:** {design doc url}

{full design doc content}

## Draft Response

_(to be filled by audit-gaps skill)_
```

**For `design-tickets` boundary:**

Filename: `{YYYYMMDD-HHmmss}-gap-audit-dt-{short-id}.md`

```yaml
---
type: gap-audit
source: slite
source_url: "{starting artifact url}"
source_id: "gap:design-tickets:{short-id}"
title: "Gap Audit: Design vs Tickets — {feature name}"
boundary: "design-tickets"
priority: normal
created_at: "{ISO 8601}"
status: incoming
project: "{slug}"
left_url: "{design doc url}"
right_url: "tickets"
---

## Context

### Left Artifact: Design Doc
**Title:** {design doc title}
**URL:** {design doc url}

{full design doc content}

### Right Artifact: Tickets
**Tracker:** {tracker type}
**Source:** {repo or jira project}

{for each ticket:}
#### {ticket key/number}: {title}
**Status:** {status}
**Description:**
{description}
**Acceptance Criteria:**
{acceptance criteria if present}

---

## Draft Response

_(to be filled by audit-gaps skill)_
```

If `--boundary` is specified and is not `all`, only create that one queue item.

### 8. Process with Skill

Invoke the `audit-gaps` skill to process each queue item and fill in the `## Draft Response`.

If both boundaries need processing, use the Agent tool to process them in parallel.

### 9. Report

Report: "Gap audit drafted: {N} boundaries checked. Run `/engineer review-queue gap` to review."
