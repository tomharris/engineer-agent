---
name: implement-ticket
description: "Implement a Jira ticket by creating a branch, writing code using Ralph Loop, and preparing a PR. Use this skill when a ticket queue item is approved for implementation."
version: 1.0.0
---

# Implement a Ticket

Implement the code changes described in a Jira ticket using iterative development via Ralph Loop.

## Tools Needed

- `Bash` — git operations, run tests, Ralph Loop invocation
- `Read`, `Write`, `Edit` — code changes
- `Glob`, `Grep` — codebase navigation
- `mcp__plugin_github_github__get_file_contents` — read repo files
- `mcp__plugin_github_github__create_pull_request` — open PR on approval

## Input

A queue item file in `.claude/engineer-agent/queue/drafts/` with type `ticket` that has been approved by the human. The file contains the ticket details, acceptance criteria, and implementation plan.

## Steps

### 1. Read the Approved Item

Read the queue item to extract:
- `ticket_key` from frontmatter
- Target repo from the implementation plan
- Acceptance criteria from the context section
- Implementation plan from the draft response

Also read `.claude/engineer-agent/engineer.yaml` and extract `agent.branch_prefix` (default: `engineer-agent`).

### 2. Set Up Branch

Navigate to the target repo's working directory. Create a new branch:

```bash
git checkout -b {branch_prefix}/{ticket_key}
```

### 3. Start Ralph Loop

Invoke Ralph Loop to iteratively implement the ticket. Construct the prompt from the queue item:

```
/ralph-loop "Implement ticket {ticket_key}: {title}

## Acceptance Criteria
{acceptance_criteria}

## Implementation Plan
{implementation_plan}

## Instructions
- Implement the changes described above
- Write or update tests to cover the new behavior
- Run the test suite after each change
- Follow the patterns and conventions in CLAUDE.md
- Keep changes focused on the ticket scope — do not refactor unrelated code
" --max-iterations 10 --completion-promise "All acceptance criteria met and tests pass"
```

### 4. After Ralph Loop Completes

When Ralph Loop finishes (either by fulfilling the promise or hitting max iterations):

1. Check the outcome:
   - If promise was fulfilled: implementation is complete
   - If max iterations hit: implementation may be partial

2. Gather results:
   - Run `git diff --stat` to list changed files
   - Run the test suite to confirm status
   - Summarize what was implemented vs. what remains

3. Update the queue item:

```markdown
## Implementation Result

**Status:** {complete | partial}
**Branch:** {branch_prefix}/{ticket_key}
**Iterations used:** {N} of 10

### Changes Made
{git diff --stat output}

### Test Results
{test output summary}

### Remaining Work
{if partial, what still needs to be done}
```

### 5. Create PR (on approval)

When the human approves the implementation result via `/engineer review-queue`:

Call `mcp__plugin_github_github__create_pull_request` with:
- `owner`: from config
- `repo`: target repo
- `title`: "{ticket_key}: {title}"
- `body`: Include the ticket link, changes summary, and test results
- `head`: `{branch_prefix}/{ticket_key}`
- `base`: `main` (or the repo's default branch)
- `draft`: true (open as draft PR for further review)

### 6. Update Queue Item

Move the queue item to `.claude/engineer-agent/queue/completed/` with `status: completed`.

## Edge Cases

- **Ticket too vague:** If acceptance criteria are missing or unclear, set the draft to say "Needs clarification" and set priority to `urgent`. Do not start Ralph Loop.
- **Tests won't pass:** If Ralph Loop hits max iterations with failing tests, report partial progress and let the human decide whether to continue manually.
- **Wrong repo:** If the target repo can't be determined, ask in the draft for the human to specify it.
