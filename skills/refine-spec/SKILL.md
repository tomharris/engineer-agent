---
name: refine-spec
description: "Analyze a PM feature spec and draft clarifying questions, feasibility notes, and suggested changes. Use this skill when processing a spec-refinement queue item."
version: 1.0.0
---

# Refine a Feature Spec

Analyze a PM's feature spec from Slite and produce structured clarifying questions with rationale.

## Tools Needed

- `mcp__slite__get-note` — fetch spec content from Slite
- `Read`, `Write` — read/write queue items
- `Grep`, `Glob` — search codebase for referenced code
- `mcp__plugin_github_github__get_file_contents` — read code referenced in the spec
- `mcp__plugin_github_github__search_code` — find relevant implementations
- `mcp__atlassian__searchJiraIssuesUsingJql` — find related/overlapping tickets
- `mcp__atlassian__getJiraIssue` — read related ticket details

## Input

A queue item file in `.claude/engineer-agent/queue/incoming/` with type `spec-refinement`, containing the spec content in `## Context`.

## Steps

### 1. Read the Spec

Read the queue item to get the full spec content from the `## Context` section.

### 2. Analyze Across Five Dimensions

**Scope Clarity**
- Are boundaries well-defined?
- Are success criteria measurable?
- Is it clear what's in and out of scope?

**Feasibility**
- Can this be built with current systems and architecture?
- Are there technical constraints that make parts infeasible?

**Missing Details**
- Are edge cases addressed?
- Is error handling specified?
- Are data models described?
- Are API contracts defined?

**Ambiguities**
- Are there statements with multiple valid interpretations?
- Are there hidden assumptions?
- Are there undefined terms?

**Technical Constraints**
- Performance requirements?
- Scale considerations?
- External dependencies?
- Security implications?

### 3. Cross-Reference

**Codebase** — Use GitHub MCP tools to verify any claims about current systems. Check if described interfaces or behaviors match actual code.

**Jira** — Search for related or overlapping tickets. Note any duplicate work or dependencies.

### 4. Write the Draft

Update the queue item with the analysis:

```markdown
## Draft Response

### Scope Assessment
{1-2 sentences on overall scope clarity and feasibility}

### Clarifying Questions
1. **{Topic}** — {Question}
   - _Why this matters:_ {rationale}
   - _Answer:_ _(to be filled in)_

2. **{Topic}** — {Question}
   - _Why this matters:_ {rationale}
   - _Answer:_ _(to be filled in)_

### Suggested Changes
1. **{Section}** — {Change and why}

### Feasibility Notes
- {constraint or consideration}

### Related Tickets
- {TICKET-123}: {title} — {relevance}

### Missing Details
- {detail needed before design}
```

The `_Answer:_` fields are intentionally left blank — the human fills these in via the Edit action in review-queue after consulting with the PM. Multiple edit cycles are expected.

Update frontmatter `status` to `drafted` and move to `.claude/engineer-agent/queue/drafts/`.

### 5. Report

Report: "Spec refinement drafted for '{spec_title}'. {N} clarifying questions, {N} suggested changes."
