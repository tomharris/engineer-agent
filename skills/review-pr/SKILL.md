---
name: review-pr
description: "Review a pull request for correctness, bugs, architecture guideline adherence, and past team decisions. Use this skill when processing a PR review queue item, or when asked to review a specific PR."
version: 1.0.0
---

# Review a Pull Request

Generate a thorough code review for a pull request, structured with severity levels.

## Tools Needed

- `Bash` — `gh pr view`, `gh pr diff`, and `gh api` for GitHub access
- `Read` — read queue items, config, and local repo files
- `Write` — write draft review
- `Grep`, `Glob` — search codebase for patterns

## Input

Either:
- A queue item file path in `~/.local/share/engineer-agent/queue/incoming/` with type `pr-review`
- Or a direct PR URL/reference (owner, repo, PR number)

## Steps

### 1. Load PR Details

If working from a queue item, read the file to get `repo`, `pr_number`, and `project` from frontmatter.

Read `~/.local/share/engineer-agent/engineer.yaml` to access project config at `projects.<project>` if needed.

Fetch PR details and diff via Bash:
```bash
gh pr view {pr_number} --repo {repo} --json title,body,author,files,commits,headRefName,baseRefName,url,number
gh pr diff {pr_number} --repo {repo}
```

This gives you:
- Full diff (from `gh pr diff`)
- PR description, files changed list, and commit messages (from `gh pr view --json`)

### 2. Understand Team Conventions

Try to read the target repo's `CLAUDE.md`. If the project has a `path` in config (`projects.<project>.path`), use `Read` to read `{path}/CLAUDE.md` directly. For remote repos, fetch via Bash:
```bash
gh api repos/{owner}/{repo}/contents/CLAUDE.md --jq '.content' | base64 -d
```

This file contains:
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

### 4. Filter Findings

A review is useful, not comprehensive. Before structuring, test every candidate finding; drop
the ones that fail into **Dismissed** with a one-line reason:

- **Hypothetical, not actual.** "What if X is null?" counts only if a real caller can pass null.
  Trace the call site; dismiss if upstream validation or the type system rules it out.
- **"I'd have done it differently."** A preference without a concrete failure is not a finding.
- **Premature abstraction.** Suggesting an extraction/interface counts only if the code must vary
  a second way now.
- **Missing context.** Code the PR didn't touch, or a pattern consistent with the rest of the
  repo, is not this PR's finding.
- **Nitpick gravity.** If every remaining finding is style, the PR is probably fine. Say so and
  recommend APPROVE rather than inflating nits to fill the review.

Never dismiss a security or correctness finding with a concrete execution path for being
uncomfortable or single-sourced. If Critical + Important exceeds 5, filter harder: either some
are Suggestions, or the PR needs REQUEST_CHANGES with the top few, not an exhaustive list.

### 5. Structure the Review

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
- **Disposition:** — left blank in the initial draft; filled in when the finding is acted on
  (`fixed` / `accepted-risk` / `deferred` / `n/a`) with a one-line note. This closes the
  integrate loop: the completed review becomes an auditable "found X → did Y" record.

### 6. Write the Draft

If working from a queue item, update the file:

1. Add the `## Draft Response` section with the structured review
2. Update frontmatter `status` from `incoming` to `drafted`
3. Move the file from `~/.local/share/engineer-agent/queue/incoming/` to `~/.local/share/engineer-agent/queue/drafts/`

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

### Findings & Disposition

{The shared ledger — one row per Critical/Important finding above. Dispositions start blank
and are filled as findings are resolved, so the completed item records how each was handled.}

| Source | Finding | Disposition | Note |
|---|---|---|---|
| pr-review | {finding} | fixed / accepted-risk / deferred / n/a | {commit or rationale} |

### Dismissed

{Approver-only; never posted to the PR. One line per dropped candidate:
`file:line — {finding} — {rule from Step 4}`. Lets the approver restore one they disagree with.
"None" if nothing was dropped.}
```

`### Dismissed` must stay the last section: `execute-item` posts everything above it.

### 7. Report

Report: "PR review drafted for {source_id}. Review has {N} critical, {N} important, {N} suggestion findings ({N} dismissed)."
