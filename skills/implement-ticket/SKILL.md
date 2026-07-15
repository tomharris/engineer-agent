---
name: implement-ticket
description: "Implement a ticket (Jira or GitHub Issue) by creating a branch, writing code using Ralph Loop, and preparing a PR. Use this skill when a ticket queue item is approved for implementation."
version: 1.0.0
---

# Implement a Ticket

Implement the code changes described in a ticket using iterative development via Ralph Loop.

## Tools Needed

- `Bash` — git operations, run tests, Ralph Loop invocation, `gh pr create`
- `Read`, `Write`, `Edit` — code changes and reading repo files
- `Glob`, `Grep` — codebase navigation

## Input

A queue item file in `~/.local/share/engineer-agent/queue/drafts/` with type `ticket` that has been approved by the human. The file contains the ticket details, acceptance criteria, and implementation plan.

## Steps

### 1. Read the Approved Item

Read the queue item to extract:
- `ticket_key` from frontmatter
- `project` from frontmatter
- Target repo from the implementation plan
- Acceptance criteria from the context section
- Implementation plan from the draft response

Then synthesize the **Intent block** — a compact, self-contained framing of the work, so the
session and the eventual PR are reusable intent artifacts even if the ticket itself is thin.
Derive each field from the ticket's acceptance criteria and description (if the item's
`## Context` already carries an `### Intent` block — e.g. one emitted by `create-tickets` —
reuse it verbatim rather than regenerating):

```markdown
### Intent
- **Goal:** {one line — the user-facing outcome this delivers}
- **Key constraint(s):** {the binding limits — perf, compat, scope}
- **Definition of done:** {the acceptance criteria, condensed to checkable bullets}
- **Non-goals:** {what this explicitly does NOT do — prevents scope creep}
```

If the ticket lacks enough detail to fill **Goal** or **Definition of done**, do not invent
intent — fall back to the "Ticket too vague" edge case below (draft "Needs clarification",
priority `urgent`, do not start Ralph Loop).

Read `~/.local/share/engineer-agent/engineer.yaml` and extract:
- `agent.branch_prefix` — MUST be read from config. There is no fallback default. If the key is missing or empty, tell the user to set `agent.branch_prefix` in `~/.local/share/engineer-agent/engineer.yaml` and stop. Use the literal string from the yaml file verbatim — do not substitute any other value.
- `agent.autonomy.auto_execute` — an optional list of action tiers that skip the approval gate. Absent ⇒ empty list. Whether `draft-pr` is present here decides Step 5 below.
- `projects.<project>.path` — the absolute path to the project directory
- `projects.<project>.github.owner` and repos for PR creation

### 2. Set Up Branch

Navigate to the project's working directory using `projects.<project>.path` from config.

Determine the tracker type for this project:
- Read `projects.<project>.tracker` from config
- If `tracker` is absent, infer: if `source` frontmatter is `github` → `github-issues`, if `jira` → `jira`

Create the branch based on tracker type. The `{branch_prefix}` placeholder below must be substituted with the literal `agent.branch_prefix` value read from config in step 1 — never with the string `engineer-agent` or any other guess.

**If tracker is `github-issues`:**
- Extract issue number from `ticket_key` (strip the `#` prefix)
- Derive a slug from the title: lowercase, replace non-alphanumeric characters with hyphens, truncate to 40 chars, strip trailing hyphens
- Branch name: `{branch_prefix}/issue-{number}-{slug}`

**If tracker is `jira`:**
- Branch name: `{branch_prefix}/{ticket_key}`

```bash
cd {projects.<project>.path}
git checkout -b {branch_name}
```

### 3. Start Ralph Loop

Invoke Ralph Loop to iteratively implement the ticket. Construct the prompt from the queue item:

```
/ralph-loop "Implement ticket {ticket_key}: {title}

## Intent
{the Intent block synthesized in Step 1 — Goal / Key constraints / Definition of done / Non-goals}

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
**Project:** {project}
**Iterations used:** {N} of 10

### Changes Made
{git diff --stat output}

### Test Results
{test output summary}

### Findings & Disposition
{Any finding surfaced while implementing — a failing test, a review note, a bug found
in passing — recorded with its disposition so the integrate loop is auditable. Use the
shared ledger format (omit the section entirely only if genuinely nothing was surfaced):}

| Source | Finding | Disposition | Note |
|---|---|---|---|
| {impl / test / self-review} | {what was found} | fixed / accepted-risk / deferred / n/a | {commit sha or rationale} |

### Remaining Work
{if partial, what still needs to be done}
```

### 5. Create the Draft PR

A **draft** PR merges nothing and requests no review, so it is safe to create without a
gate. Decide based on `agent.autonomy.auto_execute` (read in Step 1):

- **If `draft-pr` is in `auto_execute`:** create the draft PR automatically now (no second
  approval), then send an FYI push so the human knows it exists:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" --fyi \
    --title "Draft PR created: {ticket_key}" \
    --message "{project} — {title} ({iterations} iters, tests {pass|fail})" \
    --priority normal --tags rocket --source-url "{pr_url}"
  ```
- **Otherwise (default):** leave the implementation result in the queue and create the draft
  PR only when the human approves it via `/engineer-agent review-queue`.

Look up `projects.<project>.github.owner` and the repo from config.

**PR body composition.** Lead the body with the **Intent block** from Step 1, then the changes
summary and test results, then the **Findings & Disposition** ledger from the Implementation
Result (when non-empty). This makes the PR self-contained as an intent + integrate record — a
reviewer can see the goal, the definition of done, and how each finding was resolved without
opening the ticket. Create the PR based on tracker type:

**If tracker is `github-issues`:**
```bash
gh pr create --repo {owner}/{repo} --title "#{number}: {title}" --body "{Intent block; 'Closes #{number}'; changes summary; test results; Findings & Disposition ledger}" --head "{branch_prefix}/issue-{number}-{slug}" --base main --draft
```

**If tracker is `jira`:**
```bash
gh pr create --repo {owner}/{repo} --title "{ticket_key}: {title}" --body "{Intent block; ticket link; changes summary; test results; Findings & Disposition ledger}" --head "{branch_prefix}/{ticket_key}" --base main --draft
```

### 6. Update Queue Item

Move the queue item to `~/.local/share/engineer-agent/queue/completed/` with `status: completed`.

## Edge Cases

- **Ticket too vague:** If acceptance criteria are missing or unclear, set the draft to say "Needs clarification" and set priority to `urgent`. Do not start Ralph Loop.
- **Tests won't pass:** If Ralph Loop hits max iterations with failing tests, report partial progress and let the human decide whether to continue manually.
- **Wrong repo:** If the target repo can't be determined, ask in the draft for the human to specify it.
