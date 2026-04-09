---
name: refine-ticket
description: "Analyze an existing ticket (Jira, GitHub issue, or text) for scope clarity, implementation feasibility, testability, and sizing. Use this skill when processing a ticket-refinement queue item."
version: 1.0.0
model: sonnet
---

# Refine a Ticket

Analyze an existing ticket and produce a structured assessment with a Fibonacci sizing estimate grounded in codebase analysis.

## Tools Needed

- `Read`, `Write` — read/write queue items and source code
- `Grep`, `Glob` — search codebase for referenced modules, files, and test patterns
- `Bash` — run `gh issue view` to fetch GitHub issues
- `mcp__atlassian__getJiraIssue` — fetch Jira ticket details
- `mcp__atlassian__searchJiraIssuesUsingJql` — find related or blocking tickets

## Input

A queue item file in `~/.claude/engineer-agent/queue/incoming/` with type `ticket-refinement`, containing the ticket content in `## Context`.

## Steps

### 1. Read the Ticket

Read the queue item to get the full ticket content from the `## Context` section. Extract `project`, `ticket_key`, and `source` from frontmatter.

Read `~/.claude/engineer-agent/engineer.yaml` to find the project config at `projects.<project>` for codebase path and integration settings.

### 2. Analyze the Codebase

Using the project path from config:

- `Grep` for modules, classes, functions, or files referenced in the ticket
- `Glob` to find similar implementations or related code areas
- Check existing test patterns (`Glob` for `*test*`, `*spec*`) in the affected areas
- Read key files to understand current architecture in the relevant areas

### 3. Cross-Reference

Determine the tracker type for this project:
- Read `projects.<project>.tracker` from config
- If `tracker` is absent, infer: `jira` section present → `"jira"`, `github.issues` section present → `"github-issues"`, neither → `"none"`

**If tracker is `jira`:** Search for related, blocking, or duplicate tickets using `mcp__atlassian__searchJiraIssuesUsingJql` with JQL.

**If tracker is `github-issues`:** Search for related issues using `gh` CLI:
```bash
gh issue list --repo {owner}/{repo} --search "{keywords from ticket title}" --json number,title,url
```

**Additionally:** If the source is GitHub (regardless of tracker), use `gh` to check for related PRs in the repo.

Note any dependencies, blockers, or overlapping work.

### 4. Assess Four Dimensions

**Scope**
- Are boundaries well-defined? What's in and out of scope?
- Are success criteria clear and measurable?
- Are there implicit requirements not stated?

**Implementation Feasibility**
- Which files and modules are likely affected?
- Are there existing patterns to follow?
- What are the technical risks (architecture mismatch, missing infrastructure, coupling)?
- Are there external dependencies or migration concerns?

**Testability**
- Can the acceptance criteria be verified with tests?
- What test strategy is appropriate (unit, integration, e2e)?
- Are there gaps — areas that are hard to test or have unclear expected behavior?

**Sizing**
- Assign a Fibonacci estimate: 1, 2, 3, 5, 8, 13, or 21
- Ground the estimate in the codebase analysis: number of files affected, complexity of changes, test coverage needed, risk level
- 1-2: Trivial, single-file change with clear pattern to follow
- 3: Small but touches multiple files or has some ambiguity
- 5: Medium, requires design thought and touches several areas
- 8: Large, significant complexity or risk
- 13-21: Epic-sized, should probably be broken down

### 5. Write the Draft

Update the queue item with the analysis:

```markdown
## Draft Response

### Sizing Estimate
**Points:** {N} (Fibonacci)
**Rationale:** {1-2 sentences grounded in codebase analysis}

### Scope Assessment
{Analysis of boundaries, success criteria, and implicit requirements}

### Implementation Feasibility
- **Files likely affected:** {list with paths}
- **Existing patterns to follow:** {references to similar code}
- **Risks:** {technical risks identified}

### Testability
- **Test strategy:** {unit/integration/e2e recommendations}
- **Gaps:** {untestable or unclear areas}

### Questions & Suggestions
1. **{Topic}** — {Question or suggestion}
   - _Why this matters:_ {rationale}

### Related Work
- {TICKET-123}: {title} — {relevance}
```

Update frontmatter:
- Set `status` to `drafted`
- Set `estimated_size` to the Fibonacci number

Move the file to `~/.claude/engineer-agent/queue/drafts/`.

### 6. Report

Report: "Ticket refinement drafted for '{ticket_title}' — estimated at {N} points. {M} questions/suggestions."
