---
name: review-doc
description: "Review a design document for technical accuracy, clarity, and completeness. Use this skill when processing a doc-review queue item or when asked to review a design doc."
version: 1.0.0
model: sonnet
---

# Review a Design Document

Generate a thorough review of a design document with brief inline comments.

## Tools Needed

- `mcp__slite__get-note` — fetch document content from Slite
- `mcp__slite__append-blocks` — post review comments to Slite documents
- `Read` — read queue items and source code referenced in the doc
- `Write` — write draft review
- `Grep`, `Glob` — search codebase for referenced code and find relevant implementations

## Input

A queue item file in `~/.local/share/engineer-agent/queue/incoming/` with type `doc-review`, containing the document content.

## Steps

### 1. Read the Document

Read the queue item to get the full document content from the `## Context` section. Extract the `project` field from frontmatter.

Read `~/.local/share/engineer-agent/engineer.yaml` to find the project's path at `projects.<project>.path` for codebase cross-referencing.

### 2. Understand the Scope

Identify:
- What system/feature is this document about?
- Is this a new design or a modification to existing architecture?
- What repos/code does it reference?

### 3. Cross-Reference with Code

For any code or systems referenced in the document, use the project path from config to:
- Check if the described current state matches actual code
- Verify claimed behaviors by reading relevant implementations
- Note any discrepancies between the doc and reality

### 4. Review the Document

Evaluate on these dimensions:

**Technical Accuracy**
- Are technical claims correct?
- Do the described interfaces match reality?
- Are performance assumptions reasonable?

**Completeness**
- Are failure modes addressed?
- Is rollback/migration covered?
- Are edge cases considered?
- Is observability/monitoring mentioned?

**Clarity**
- Is the problem statement clear?
- Are alternatives considered and trade-offs explained?
- Would a new team member understand the design?

**Feasibility**
- Is the proposed timeline realistic?
- Are dependencies identified?
- Are there hidden complexities?

### 5. Write the Draft

Keep comments **very brief** — this is a design doc review, not an essay.

Update the queue item:

```markdown
## Draft Response

### Overall Assessment

{1-2 sentences: is this design sound?}

### Inline Comments

1. **Section: {section_name}** — {brief comment, 1-2 sentences max}
2. **Section: {section_name}** — {brief comment}
3. ...

### Questions

- {open question that needs answering before implementation}

### Missing Sections

- {anything important that's not covered}
```

Update frontmatter `status` to `drafted` and move to `~/.local/share/engineer-agent/queue/drafts/`.

### 6. Report

Report: "Design doc review drafted for '{doc_title}'. {N} inline comments, {N} questions."
