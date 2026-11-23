# Drafting a queue item

How to write an item's `## Draft Response`. Read by `scripts/jobs-draft.sh` (the drafting run of
every `watch` job) and `commands/add-ticket.md`. The scripted collectors have already written the
item's frontmatter and `## Context`; drafting adds the draft, sets `status: drafted` and moves the
file to `drafts/` under the same filename. An item left in `incoming/` is invisible to every
approval path.

Never draft an `_unrouted` item unless the run was told to route it; it stays in `incoming/` until
the user assigns a project via `/engineer-agent review-queue`.

## By type

| `type` | Draft |
|---|---|
| `pr-review` | Follow the `review-pr` skill: `gh pr view {number} --repo {owner}/{repo} --json title,body,author,files,commits,headRefName,baseRefName,url,number` and `gh pr diff`, then a structured review. |
| `slack-question` | Follow the `answer-slack` skill. |
| `doc-review` | Follow the `review-doc` skill. |
| `ticket` | The implementation plan below. |
| `ticket-investigation` | The investigation plan below. |

## Tickets (`ticket`, `ticket-investigation`)

1. Read the ticket details.
2. Identify the repo from `projects.<project>.github.owner` and `repos`.
3. **Only for a GitHub `ticket`:** derive a branch slug from the title: lowercase, replace
   non-alphanumeric characters with hyphens, truncate to 40 chars, strip trailing hyphens. Skip it
   for an investigation, which has no branch.
4. Draft the plan **matching the item's `type`**. Do **not** perform the investigation: drafting
   writes the plan only, so a ticket the human rejects never costs research, and the research runs
   once, under the approval's budget cap, in its confined read-only worktree.

### `ticket` (code work)

Branch: `{branch_prefix}/{ticket_key}` for Jira, `{branch_prefix}/issue-{number}-{slug}` for GitHub.

```markdown
## Draft Response

### Implementation Plan

**Target repo:** {repo}
**Branch:** {branch}
**Approach:** {2-3 sentence summary}

### Files to Modify
- {file_path} — {what changes}

### Implementation Method
This ticket will be implemented iteratively in-session (plan → edit → test → fix), up to ~10 passes, done when all acceptance criteria are met and tests pass.

### Action on Approval
Approving this item implements the changes on a feature branch, then opens a draft PR.
```

### `ticket-investigation` (findings document)

`{ref}` is the Jira key (`ENG-789`) or `#{number}` for a GitHub issue. The transition clause is
Jira-only, and only when `on_complete_status` is configured.

```markdown
## Draft Response

### Investigation Plan

**Target repo:** {repo}
**Question:** {the unknown to resolve or the decision to make, one sentence}
**Where to look:** {2–5 files/dirs/subsystems, each with why}
**History to check:** {commits/PRs likely to explain the current shape, if any}
**Method:** read-only inspection — Read/Grep/Glob plus `git log`/`show`/`diff`/`blame`. No branch,
no code changes, no build or test commands.
**Deliverable:** a `## Findings` document (Question / Answer / Evidence with file:line citations /
Open Questions / Next Steps{, plus Options + Recommendation for a decision}), posted as a comment
on {ref} and archived under `~/.local/share/engineer-agent/investigations/`.

### Action on Approval
Approving this item runs a read-only investigation and **posts the findings as a comment on
{ref}**, plus a local archive{, then transitions the ticket to {on_complete_status}}.
**No branch, no PR, no QA test plan.**
```

> Never emit the code-work template for a `ticket-investigation`. Its "implemented iteratively …
> ~10 passes" and "opens a draft PR" lines are what the human reads at the approval gate, so an
> investigation carrying them would win approval for an action that never happens.
