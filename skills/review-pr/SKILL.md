---
name: review-pr
description: "Review a pull request for correctness, bugs, architecture guideline adherence, and past team decisions. Use this skill when processing a PR review queue item, or when asked to review a specific PR."
version: 1.0.0
---

# Review a Pull Request

Generate a thorough code review for a pull request, structured with severity levels.

## Tools Needed

- `mcp__plugin_github_github__pull_request_read` — read PR diff and details
- `mcp__plugin_github_github__get_file_contents` — read files in the repo for context
- `mcp__plugin_github_github__list_commits` — understand commit history
- `Read` — read queue items and config
- `Write` — write draft review
- `Grep`, `Glob` — search codebase for patterns

## Input

Either:
- A queue item file path in `queue/incoming/` with type `pr-review`
- Or a direct PR URL/reference (owner, repo, PR number)

## Steps

### 1. Load PR Details

If working from a queue item, read the file to get `repo` and `pr_number` from frontmatter.

Call `mcp__plugin_github_github__pull_request_read` with the owner, repo, and PR number to get:
- Full diff
- PR description
- Files changed list
- Commit messages

### 2. Understand Team Conventions

Try to read the target repo's `CLAUDE.md` via `mcp__plugin_github_github__get_file_contents` (owner, repo, path: "CLAUDE.md"). This contains:
- Architecture guidelines
- Past team decisions
- Code style conventions
- Patterns to follow

If no CLAUDE.md exists, proceed without team-specific context.

### 3. Review the Changes

Analyze the PR diff for:

**Correctness**
- Logic errors, off-by-one bugs, null/undefined handling
- Incorrect assumptions about data shapes or types
- Missing edge cases

**Bugs**
- Race conditions, memory leaks, resource cleanup
- Security issues (injection, XSS, auth bypass)
- Error handling gaps

**Architecture Adherence**
- Does this follow patterns established in CLAUDE.md?
- Does it respect the project's module boundaries?
- Are new abstractions justified and consistent?

**Team Decisions**
- Does this follow conventions from CLAUDE.md?
- Does it use the team's preferred libraries/patterns?
- Are naming conventions consistent?

### 4. Structure the Review

Organize findings by severity:

- **Critical** — Must fix before merge. Bugs, security issues, data loss risks.
- **Important** — Should fix. Architecture violations, maintainability concerns.
- **Suggestion** — Nice to have. Style improvements, refactoring opportunities.
- **Positive** — What's done well. Highlight good patterns to encourage them.

For each finding, include:
- File path and line number(s)
- What the issue is
- Why it matters
- Suggested fix (when applicable)

### 5. Write the Draft

If working from a queue item, update the file:

1. Add the `## Draft Response` section with the structured review
2. Update frontmatter `status` from `incoming` to `drafted`
3. Move the file from `queue/incoming/` to `queue/drafts/`

The draft response format:

```markdown
## Draft Response

### Review Summary

{1-2 sentence overall assessment}

**Recommendation:** APPROVE | COMMENT | REQUEST_CHANGES

### Critical

{findings or "None"}

### Important

{findings or "None"}

### Suggestions

{findings}

### Positive

{what's done well}
```

### 6. Report

Report: "PR review drafted for {source_id}. Review has {N} critical, {N} important, {N} suggestion findings."
