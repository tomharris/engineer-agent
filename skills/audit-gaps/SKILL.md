---
name: audit-gaps
description: "Compare pipeline artifacts across a boundary (spec↔design or design↔tickets) and produce a checklist of gaps. Use this skill when processing a gap-audit queue item."
version: 1.0.0
---

# Audit Gaps Between Pipeline Artifacts

Compare two pipeline artifacts and produce a checklist of gaps, mismatches, and ambiguities.

## Tools Needed

- `Read`, `Write` — read/write queue items
- `Grep`, `Glob` — search completed queue items for cross-references
- `mcp__slite__get-note` — re-fetch Slite content if needed
- `mcp__atlassian__getJiraIssue` — re-fetch Jira ticket details if needed
- `Bash` — run `gh` CLI commands for GitHub Issues

## Input

A queue item file in `~/.claude/engineer-agent/queue/incoming/` with `type: gap-audit`. The frontmatter includes a `boundary` field (`spec-design` or `design-tickets`). The `## Context` section contains the full content of both artifacts being compared, structured as `### Left Artifact` and `### Right Artifact`.

## Steps

### 1. Read Queue Item

Read the queue item file. Extract:
- `boundary` from frontmatter (`spec-design` or `design-tickets`)
- Left artifact content from `### Left Artifact` under `## Context`
- Right artifact content from `### Right Artifact` under `## Context`

### 2. Extract Features from Each Side

**For `spec-design` boundary:**

From the **spec** (left), extract:
- Requirements (explicit or implicit)
- User stories or feature descriptions
- Goals and non-goals
- Scope boundaries
- Edge cases and error scenarios
- Performance or quality requirements
- Security or compliance requirements

From the **design doc** (right), extract:
- Architectural components and their responsibilities
- Design decisions and their rationale
- API changes and data model changes
- Implementation phases and work items
- Goals and non-goals
- Cross-cutting concerns (observability, security, performance, migration)
- Open questions and risks

**For `design-tickets` boundary:**

From the **design doc** (left), extract:
- Implementation phases and their components
- Architectural components requiring implementation
- Design decisions that need implementation
- Cross-cutting concerns (observability, security, migration)
- Integration points
- Testing requirements

From the **tickets** (right), extract:
- Each ticket's title, description, and acceptance criteria
- Dependencies between tickets
- Phase/ordering information
- Sizing estimates
- Testing strategies mentioned

### 3. Compare Across Boundary

Perform bidirectional comparison:

**For `spec-design` boundary:**
- Every spec requirement should have a corresponding design section addressing it
- Every design component should trace back to a spec requirement (detect unbounded scope creep)
- Goals and non-goals should be consistent between spec and design
- Scope boundaries should match
- Edge cases mentioned in the spec should be handled in the design
- Quality/performance requirements from the spec should appear in cross-cutting concerns

**For `design-tickets` boundary:**
- Every design component/phase should have corresponding ticket(s)
- No orphan tickets that don't trace back to the design
- Ticket acceptance criteria should cover the design's requirements for that component
- Phase ordering in tickets should match the design's implementation phases
- Sizing should feel proportional to the design complexity of each component
- Cross-cutting concerns (observability, security, migration) should have dedicated tickets or be covered in relevant tickets
- Testing strategy in tickets should align with the design's testing requirements

### 4. Classify Each Gap

For every mismatch found, classify it as one of:

- **`missing-right`** — present in left artifact only, missing from right. E.g., a spec requirement with no design section, or a design component with no ticket.
- **`missing-left`** — present in right artifact only, missing from left. E.g., a design section that doesn't trace to any spec requirement, or a ticket with no design component.
- **`diverged`** — both sides address it but they disagree on scope, approach, or details.
- **`ambiguous`** — unclear mapping between the two sides, needs human judgment to determine if there's a real gap.

### 5. Generate Drafts Where Straightforward

For each gap, generate a suggested fix where possible:

- **Missing ticket** → draft a ticket body (title, description, acceptance criteria) following the project's ticket format
- **Missing design section** → suggest a heading and brief outline for what the section should cover
- **Missing spec requirement** → suggest requirement text based on what the design/ticket implies
- **Diverged items** → show both sides clearly, suggest a reconciled version
- **Ambiguous items** → describe the mismatch and what to look for, leave resolution to the reviewer

### 6. Write Draft Response

Write the `## Draft Response` section in this format:

```markdown
## Draft Response

### Gap Audit: {Spec vs Design Doc | Design Doc vs Tickets}

**Left:** {artifact title} ({url})
**Right:** {artifact title} ({url or "tickets"})
**Gaps Found:** {N}

### Checklist

#### 1. {Gap title}
- **Type:** missing-right | missing-left | diverged | ambiguous
- **Left side:** {what the left artifact says, or "Not present"}
- **Right side:** {what the right artifact says, or "Not present"}
- **Suggested action:** {neutral description of what to do}
- **Draft:** _(if applicable)_
  {draft content — ticket body, section outline, requirement text, or reconciled version}

#### 2. {Gap title}
- **Type:** missing-right | missing-left | diverged | ambiguous
- **Left side:** {what the left artifact says, or "Not present"}
- **Right side:** {what the right artifact says, or "Not present"}
- **Suggested action:** {neutral description of what to do}
- **Draft:** _(if applicable)_
  {draft content}

{repeat for each gap found}

### Summary
- {N} items only in {left artifact type} (missing from {right artifact type})
- {N} items only in {right artifact type} (missing from {left artifact type})
- {N} items present in both but diverged
- {N} ambiguous mappings needing human judgment
```

If no gaps are found for a boundary, write:

```markdown
## Draft Response

### Gap Audit: {boundary description}

**Left:** {artifact title} ({url})
**Right:** {artifact title} ({url})
**Gaps Found:** 0

No gaps detected. The artifacts appear well-aligned across this boundary.
```

### 7. Finalize

Update the queue item's frontmatter `status` to `drafted` and move it from `~/.claude/engineer-agent/queue/incoming/` to `~/.claude/engineer-agent/queue/drafts/` (write to new location, delete from old).

### 8. Report

Report: "Gap audit drafted for {boundary} boundary: {N} gaps found. Review with `/engineer-agent review-queue gap`."
