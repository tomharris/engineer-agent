---
name: review-doc
description: "Review a design document for technical accuracy, clarity, and completeness. Use this skill when processing a doc-review queue item or when asked to review a design doc."
version: 1.0.0
---

# Review a Design Document

Generate a thorough review of a design document with brief inline comments.

## Tools Needed

- `Bash` — curl to Slite API for fetching/commenting
- `Read` — read queue items
- `Write` — write draft review
- `Grep`, `Glob` — search codebase for referenced code
- `mcp__plugin_github_github__get_file_contents` — read code referenced in the doc
- `mcp__plugin_github_github__search_code` — find relevant implementations

## Input

A queue item file in `queue/incoming/` with type `doc-review`, containing the document content.

## Steps

### 1. Read the Document

Read the queue item to get the full document content from the `## Context` section.

### 2. Understand the Scope

Identify:
- What system/feature is this document about?
- Is this a new design or a modification to existing architecture?
- What repos/code does it reference?

### 3. Cross-Reference with Code

For any code or systems referenced in the document:
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

Update frontmatter `status` to `drafted` and move to `queue/drafts/`.

### 6. Report

Report: "Design doc review drafted for '{doc_title}'. {N} inline comments, {N} questions."
