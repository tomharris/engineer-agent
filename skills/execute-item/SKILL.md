---
name: execute-item
description: "Execute the approved (or rejected) external action for a single engineer-agent queue item. Headless-safe and used by both /engineer-agent review-queue (interactive) and /engineer-agent execute (remote ntfy approval) so the two paths never drift."
version: 1.0.0
---

# Execute a Queue Item

Perform the external action for ONE drafted queue item and move it to its terminal
state. This is the single source of truth for "what approving an item actually does" —
both the interactive review queue and the remote ntfy approval path call into it.

## Inputs

- **item** — the path to a queue file (or a bare filename resolved against
  `~/.claude/engineer-agent/queue/drafts/`).
- **decision** — `approve` or `reject`.
- **reason** (optional) — rejection reason text; only used when `decision` is `reject`.

## Tools Needed

`Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, and the posting MCP tools:
`mcp__claude_ai_Slack__slack_send_message`, `mcp__slite__append-blocks`,
`mcp__slite__create-note`.

## Steps

### 1. Load Config and Resolve the Item

Read `~/.claude/engineer-agent/engineer.yaml`. If missing, stop and report that
`/engineer-agent setup` must be run.

Extract:
- `agent.branch_prefix` — **required, no default.** Read the literal string verbatim. If
  missing/empty, stop and report that `agent.branch_prefix` must be set. Use this exact
  value wherever `{branch_prefix}` appears below.
- `agent.autonomy.auto_execute` — an optional list of action tiers that skip the approval
  gate (e.g. `["draft-pr"]`). Absent ⇒ empty list.

Resolve **item** to a file. If only a filename was given, look in
`~/.claude/engineer-agent/queue/drafts/`. **Idempotency:** if the file is not in
`drafts/` (already moved to `completed/` or `rejected/`, or never existed), do nothing and
report `already-handled` — this makes repeated/duplicate triggers safe.

Read the file's frontmatter (`type`, `source`, `source_url`, `project`, `ticket_key`,
etc.) and its `## Draft Response` section.

### 2. Reject Path

If **decision** is `reject`:
1. Add `rejected_reason: "{reason or 'rejected via execute'}"` to the frontmatter.
2. Set `status: rejected`.
3. Move the file to `~/.claude/engineer-agent/queue/rejected/`.
4. Report: `rejected {filename}`.

Stop here.

### 3. Approve Path — Guard Interactive-Only Types

If **decision** is `approve` and `type` is `qa-test-plan`, **do not execute headlessly.**
The QA flow is a three-phase interactive process (run tests, manual checklist, archive)
that requires a human at the terminal. Report:
`qa-test-plan must be completed interactively via /engineer-agent review-queue qa` and
leave the file untouched in `drafts/`.

### 4. Approve Path — Execute by Type

Look up the item's project config at `projects.<project>`. Determine the tracker type:
read `projects.<project>.tracker`, or infer from `source` frontmatter (`github` →
`github-issues`, `jira` → `jira`). Then dispatch on `type`:

- **pr-review** — submit the review via Bash. Use `--approve`, `--comment`, or
  `--request-changes` per the draft's **Recommendation** field:
  ```bash
  gh pr review {pr_number} --repo {repo} --{approve|comment|request-changes} --body "{review_body}"
  ```

- **slack-question** — call `mcp__claude_ai_Slack__slack_send_message` to post the reply
  in the original thread.

- **ticket** — create a **draft** PR. (See "Auto-execute: draft-pr" below for when this is
  allowed to run without a human approval.) Look up `projects.<project>.github.owner` and repo.
  - tracker `github-issues` (extract issue number from `ticket_key` stripping `#`; slug =
    title lowercased, non-alphanumeric → hyphens, truncated to 40 chars, trailing hyphens
    stripped):
    ```bash
    gh pr create --repo {owner}/{repo} --title "#{number}: {title}" \
      --body "{body with 'Closes #{number}'}" \
      --head "{branch_prefix}/issue-{number}-{slug}" --base main --draft
    ```
  - tracker `jira`:
    ```bash
    gh pr create --repo {owner}/{repo} --title "{ticket_key}: {title}" --body "{body}" \
      --head "{branch_prefix}/{ticket_key}" --base main --draft
    ```

- **doc-review** — call `mcp__slite__append-blocks` to post review comments on the document.

- **spec-refinement** — no external action. Report: `spec refinement complete; run
  /engineer-agent create-design-doc {source_url}`.

- **design-doc** — call `mcp__slite__create-note` with the title from frontmatter, parent
  from `projects.<project>.slite.design_doc_parent`, and content from `## Draft Response`.

- **ticket-refinement** — no external action. Report: `ticket refinement complete for
  {ticket_key}`.

- **ticket-plan** — by tracker:
  - `github-issues`: create an issue per ticket in the plan via
    `gh issue create --repo {owner}/{repo} --title "{title}" --body "{body}" --label "{labels}"`;
    report created issue URLs.
  - `jira` / `none`: no automated creation; report that the plan is approved for reference.

- **gap-audit** — no external action. Count gaps in the `### Checklist` section and report
  `gap audit acknowledged ({N} gaps)`.

- **qa-test-plan** — guarded in Step 3; never reached here.

### 5. Finalize

After a successful approve action: set frontmatter `status: completed` and move the file to
`~/.claude/engineer-agent/queue/completed/`. Report a one-line result naming the action
taken (e.g. `approved pr-review org/repo#142 (commented)` or `created draft PR {url}`).

If the external action fails (e.g. `gh` non-zero, MCP error): **do not move the file.** Leave
it in `drafts/`, report the error, and exit non-zero so the caller can surface the failure
(and the item remains available to retry).

## Auto-execute: draft-pr

The `ticket` action above creates a **draft** PR. A draft PR merges nothing and requests no
review, so it is the one action safe to take without a human approval gate. Behavior:

- When this skill is invoked for an explicit human approval (interactive queue or remote
  approve), execute normally.
- When an automated caller (e.g. `implement-ticket` after Ralph Loop) wants to skip the
  gate, it should only do so when `draft-pr` is present in `agent.autonomy.auto_execute`.
  This skill itself always performs the action it is asked to; the *gating decision* lives
  with the caller, and `auto_execute` is the shared signal both honor.

All other actions (Slack posts, PR `approve`/`request-changes`, issue creation, non-draft
PRs) always require an explicit approve decision and are never auto-executed.
