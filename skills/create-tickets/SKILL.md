---
name: create-tickets
description: "Break a design doc into phased implementation tickets with dependencies. Use this skill when processing a ticket-plan queue item."
version: 1.0.0
---

# Create Tickets from Design Doc

Generate a phased ticket breakdown from an engineering design doc, with real file paths from codebase research and explicit inter-ticket dependencies.

## Tools Needed

- `mcp__slite__get-note` — fetch design doc from Slite
- `Read`, `Write` — read/write queue items and source code
- `Grep`, `Glob` — explore codebase architecture, find implementations and patterns
- `mcp__atlassian__searchJiraIssuesUsingJql` — find existing related tickets
- `mcp__atlassian__getJiraIssue` — read ticket details

## Input

A queue item file in `.claude/engineer-agent/queue/incoming/` with type `ticket-plan`, containing the design doc content in `## Context`. The frontmatter includes `design_doc_id` linking to the source design doc and optionally `jira_project` for the target project.

## Steps

### 1. Gather Context

Read the queue item's `## Context` section for the design doc content.

If the context includes a "Queue Design Doc Context" subsection, use it as enriched context — it may contain additional design detail from the queue's design-doc draft.

If the context includes an "Existing Related Tickets" subsection, note these to avoid proposing duplicate work and to reference as dependencies where appropriate.

### 2. Research the Codebase

Before generating tickets, understand the current architecture:
- Use Glob to find relevant directories, file patterns, and project structure
- Use Grep to search for existing implementations, patterns, and conventions
- Identify test file locations and testing patterns in use
- Note data models, API routes, configuration patterns
- Find existing examples that new code should follow

This research is critical — every ticket must reference **actual file paths** from the codebase, not abstract names.

### 3. Check Jira for Related Tickets

If `jira_project` is set in the frontmatter, search Jira for existing tickets that overlap with the planned work. Note any that should be referenced as dependencies or that indicate work already in progress.

### 4. Generate Ticket Breakdown

Write the phased ticket plan in the `## Draft Response` section using the template below.

**Ticket guidelines:**
- Each ticket must be independently implementable once its dependencies are met
- Reference actual file paths from codebase research (not abstract names)
- Scope: S = less than 1 day, M = 1-2 days, L = 2-3 days — split anything larger
- Phase 1 = foundational work (data models, config, scaffolding)
- Final phase = integration testing, documentation, cleanup
- Within each phase, call out which tickets can be worked on in parallel
- Include testing strategy with real test file paths and patterns from the codebase

**Template:**

```markdown
## Draft Response

### Ticket Plan: {title}

**Design Doc:** {url}
**Project:** {jira_project}
**Total Tickets:** {N}
**Phases:** {M}

---

### Phase 1: {Name} — {purpose}

#### Ticket #1: {Title}

**Type:** Task | Story
**Priority:** High | Medium | Low
**Estimate:** S | M | L

**Description:**
{1-2 paragraphs: what this ticket delivers and why it's needed at this stage}

**Implementation Approach:**
- Modify `{actual/file/path}` to {specific change}
- Create `{new/file/path}` following pattern in `{existing/example}`
- {Steps with real file paths from codebase research}

**Testing Strategy:**
- Unit tests in `{test/path}` covering {specific scenarios}
- Integration test for {specific flow}

**Acceptance Criteria:**
- [ ] {Verifiable criterion}
- [ ] {Verifiable criterion}

**Dependencies:** None | Ticket #N ({reason})

---

{repeat for each ticket in the phase}

### Phase 2: {Name} — {purpose}

{repeat pattern for each phase}

---

### Summary

| # | Title | Phase | Type | Est. | Depends On |
|---|-------|-------|------|------|------------|
| 1 | {title} | 1 | Task | S | None |
| 2 | {title} | 1 | Story | M | #1 |

### Existing Related Tickets
- {KEY-123}: {title} — {relationship to this work}

### Notes
- {Parallelization opportunities: "Tickets #2 and #3 can be worked on simultaneously"}
- {Risks or caveats}
- {Migration or rollout considerations}
```

Fill in every section based on the design doc and codebase research. If no existing related tickets were found, include the section with "None found."

### 5. Finalize

Update the queue item's frontmatter `status` to `drafted` and move it to `.claude/engineer-agent/queue/drafts/`.

### 6. Report

Report: "Ticket plan drafted for '{design_doc_title}': {N} tickets across {M} phases. Review with `/engineer review-queue` before creating tickets in your project tracker."
