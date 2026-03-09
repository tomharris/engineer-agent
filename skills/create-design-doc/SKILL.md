---
name: create-design-doc
description: "Generate a structured engineering design doc from a refined PM feature spec. Use this skill when processing a design-doc queue item."
version: 1.0.0
---

# Create a Design Doc

Generate a comprehensive engineering design doc from a PM's feature spec, incorporating any prior spec refinement Q&A.

## Tools Needed

- `mcp__slite__get-note` — fetch spec and optional template from Slite
- `mcp__slite__create-note` — create the design doc on approval
- `Read`, `Write` — read/write queue items
- `Grep`, `Glob` — explore codebase architecture
- `mcp__plugin_github_github__get_file_contents` — read relevant source code
- `mcp__plugin_github_github__search_code` — find implementations and patterns
- `mcp__atlassian__searchJiraIssuesUsingJql` — find dependency tickets
- `mcp__atlassian__getJiraIssue` — read ticket details

## Input

A queue item file in `.claude/engineer-agent/queue/incoming/` with type `design-doc`, containing the spec content in `## Context`. The frontmatter may include `spec_refinement_id` linking to a completed spec-refinement for additional Q&A context.

## Steps

### 1. Gather Context

Read the queue item's `## Context` section for the spec content.

If `spec_refinement_id` is present in the frontmatter, search `.claude/engineer-agent/queue/completed/` for a matching spec-refinement item (by `source_id`). Extract the Q&A from its `## Draft Response` — the filled-in `_Answer:_` fields provide critical context from PM conversations.

### 2. Determine Template

Check the queue item frontmatter or config for a template:

- If a `design_doc_template` Slite doc ID is available, fetch it via `mcp__slite__get-note` and use its heading structure as the template
- If empty, use the built-in default template (see below)

### 3. Research the Codebase

Before writing, understand the current architecture:
- Search for code related to the systems mentioned in the spec
- Identify existing patterns, abstractions, and conventions
- Note relevant data models and API contracts
- Find potential integration points

### 4. Write the Design Doc

Using either the fetched template structure or the built-in default, generate the full design doc content.

**Built-in Default Template:**

```markdown
## Draft Response

### Overview
{Problem framing — what exists today and what's wrong. Solution summary — what we're building and why.}

### Goals
- {Measurable success criterion}

### Non-Goals
- {Explicit scope boundary — what we're NOT doing and why}

### Architecture

#### High-Level Approach
{System design narrative}

#### Components
{New or modified components with responsibilities}

#### Data Model Changes
{Schema changes, new tables/fields, migrations}

#### API Changes
{New or modified endpoints/interfaces}

### Design Decisions

| Decision | Options Considered | Choice | Rationale |
|----------|-------------------|--------|-----------|
| {decision} | {options} | {choice} | {why} |

### Dependencies
- **Internal teams:** {teams and what's needed from them}
- **External services:** {third-party dependencies}
- **Sequencing:** {what must happen first}

### Cross-Cutting Concerns

#### Observability
{Metrics, logging, alerting}

#### Security
{Auth, data protection, threat model considerations}

#### Performance
{Latency, throughput, resource requirements}

#### Migration
{Data migration, feature flags, rollback strategy}

### Open Questions
- {Unresolved item needing further discussion}

### Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| {risk} | {low/medium/high} | {low/medium/high} | {mitigation} |

### Implementation Phases

#### Phase 1: {name}
- {work item}
- {work item}

#### Phase 2: {name}
- {work item}
```

Fill in every section based on the spec, refinement Q&A, and codebase research. If a section genuinely doesn't apply, include it with "N/A — {brief reason}".

Update frontmatter `status` to `drafted` and move to `.claude/engineer-agent/queue/drafts/`.

### 5. Report

Report: "Design doc drafted for '{spec_title}'. Review with `/engineer review-queue` before publishing to Slite."
