---
name: execute-item
description: "Execute the approved (or rejected) external action for a single engineer-agent queue item. Headless-safe and used by both /engineer-agent review-queue (interactive) and /engineer-agent execute (remote ntfy approval) so the two paths never drift."
version: 1.1.0
---

# Execute a Queue Item

Perform the external action for ONE drafted queue item and move it to its terminal
state. This is the single source of truth for "what approving an item actually does" —
both the interactive review queue and the remote ntfy approval path call into it.

## Inputs

- **item** — the path to a queue file (or a bare filename resolved against
  `~/.local/share/engineer-agent/queue/drafts/`).
- **decision** — `approve` or `reject`.
- **reason** (optional) — rejection reason text; only used when `decision` is `reject`.

## Tools Needed

`Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, and `Skill` (an unimplemented `ticket`
delegates its coding session to `implement-ticket`). Posting happens via the effective Slack CLI
(`<slack> send …` over `Bash` — `spy`, or `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh` when
`agent.slack.method: mcp-proxy`), the `gh` CLI (including `gh issue comment`), the Slite MCP tools
`mcp__slite__append-blocks`, `mcp__slite__create-note`, and the Jira MCP tools
`mcp__atlassian__createJiraIssue`, `mcp__atlassian__addCommentToJiraIssue`,
`mcp__atlassian__getTransitionsForJiraIssue`, `mcp__atlassian__transitionJiraIssue`.

## Steps

### 1. Load Config and Resolve the Item

Read `~/.local/share/engineer-agent/engineer.yaml`. If missing, stop and report that
`/engineer-agent setup` must be run.

Extract:
- `agent.branch_prefix` — **required, no default.** Read the literal string verbatim. If
  missing/empty, stop and report that `agent.branch_prefix` must be set. Use this exact
  value wherever `{branch_prefix}` appears below.
- `agent.autonomy.auto_execute` — an optional list of action tiers that skip the approval
  gate (e.g. `["draft-pr"]`). Absent ⇒ empty list.

Resolve **item** to a file. If only a filename was given, look in
`~/.local/share/engineer-agent/queue/drafts/`. **Idempotency:** if the file is not in
`drafts/` (already moved to `completed/` or `rejected/`, or never existed), do nothing and
report `already-handled` — this makes repeated/duplicate triggers safe.

Read the file's frontmatter (`type`, `source`, `source_url`, `project`, `ticket_key`,
etc.) and its `## Draft Response` section.

### 2. Reject Path

If **decision** is `reject`:
1. Add `rejected_reason: "{reason or 'rejected via execute'}"` to the frontmatter.
2. Set `status: rejected`.
3. Move the file to `~/.local/share/engineer-agent/queue/rejected/`.
4. Report: `rejected {filename}`.

Stop here.

### 3. Approve Path — Guard Interactive-Only Types

If **decision** is `approve` and `type` is `qa-test-plan`, **do not execute headlessly.**
The QA flow is a three-phase interactive process (run tests, manual checklist, archive)
that requires a human at the terminal. Report:
`qa-test-plan must be completed interactively via /engineer-agent review-queue qa` and
leave the file untouched in `drafts/`.

`ticket-investigation` is deliberately **not** added to this guard. Remote approval of an
investigation is the point, and its confined execution path is read-only — narrower than the
`ticket` path already permitted.

### 4. Approve Path — Execute by Type

Look up the item's project config at `projects.<project>`. Determine the tracker type:
read `projects.<project>.tracker`, or infer from `source` frontmatter (`github` →
`github-issues`, `jira` → `jira`). Then dispatch on `type`:

- **pr-review** — submit the review via Bash. Use `--approve`, `--comment`, or
  `--request-changes` per the draft's **Recommendation** field:
  ```bash
  gh pr review {pr_number} --repo {repo} --{approve|comment|request-changes} --body "{review_body}"
  ```

- **slack-question** — post the reply in the original thread via the effective Slack CLI.
  Resolve the binary (if `agent.slack.method` is `mcp-proxy` →
  `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh`; else `agent.slack.bin`, default `spy`) and
  workspace (`projects.<project>.slack.workspace` ?? `agent.slack.workspace`), then use the
  item's `channel_id` and `message_ts` (the thread parent):
  ```bash
  <slack> send {channel_id} "{reply_text}" --thread {message_ts} -w {workspace} --json
  ```
  Under `mcp-proxy`, a `75` exit (`{"skipped": true}` — Keychain token expired) means the post
  did not happen: treat it as a failed action (Step 5's failure rule — leave the item in
  `drafts/`, report it, exit non-zero) so it is retried once Claude Code re-auths.

- **ticket** — **implement the ticket if it is not implemented yet, then create the draft PR.**
  This case is the single source of truth for *what approving a ticket does*, on every entry
  point. It chooses between "implement" and "finish" by **probing for the branch**, never by
  assuming which path called it — that assumption was the bug: the interactive path had nothing
  that ever ran `implement-ticket`, so approving a freshly-polled ticket landed here with no
  branch and could only fail.

  **Where to work.** Run `git rev-parse --is-inside-work-tree`. If it returns `true` you are
  already inside a prepared checkout of the target repo (the listener's confined worktree) — work
  **here** and do **not** `cd` anywhere. A worktree's top level is not
  `projects.<project>.path`, so do not compare against that path; comparing would wrongly send
  you out of the sandbox. Only when you are not already inside a checkout do you `cd` to
  `projects.<project>.path`. This is the same detection `implement-ticket` Step 2 performs — the
  two must agree.

  **Resolve the expected branch name** (the rule is shared with `implement-ticket` Step 2, using
  the literal `agent.branch_prefix` from config):
  - tracker `github-issues`: `{branch_prefix}/issue-{number}-{slug}` — `{number}` from
    `ticket_key` with `#` stripped; `{slug}` = title lowercased, non-alphanumeric → hyphens,
    truncated to 40 chars, trailing hyphens stripped.
  - tracker `jira`: `{branch_prefix}/{ticket_key}`

  **Then probe for that branch, in this order, and take the first case that matches:**

  1. **On the remote** (`git ls-remote --exit-code --heads origin {branch}` succeeds) — the work
     is already implemented and pushed. Go straight to **Finish** below. This is the historical
     behavior of this case, unchanged.
  2. **Local only** (`git show-ref --verify --quiet refs/heads/{branch}` succeeds) — implemented
     but never pushed. `git push -u origin {branch}`, then **Finish**. Do not re-implement: a
     `git checkout -b` on an existing name fails, and the commits on that branch are the human's
     work.
  3. **Neither** — not implemented. **Invoke the `implement-ticket` skill** with this item. (If
     the `Skill` tool is unavailable — every confined headless allowlist in this repo omits it on
     purpose — `Read` `skills/implement-ticket/SKILL.md` and follow it instead. Same contract
     either way.) That skill owns the whole coding session: it creates the branch, implements iteratively,
     self-reviews the diff and fixes findings, pushes, opens the draft PR, and writes the
     `completed/` record itself. When it returns, confirm
     `~/.local/share/engineer-agent/queue/completed/{filename}` exists and report the PR URL —
     do **not** run **Finish** as well, or you will attempt a second PR on the same head.
     If it bailed instead (its "Ticket too vague" / "Tests won't pass" edge cases), the item is
     still in `drafts/`: leave it there and report why, per Step 5's failure rule.

  > **Isolation and budget come from the caller, not from here.** This skill runs *inside*
  > whatever sandbox its caller built, so it can neither create nor widen one. On the remote
  > (ntfy) path `scripts/approval-listener.sh`'s `run_ticket_implementation` prepares an isolated
  > git worktree, a config-driven build-command allowlist and `TICKET_BUDGET_USD` **in plain bash
  > before `claude` starts**, then invokes this skill inside it (see CLAUDE.md → "Confined
  > headless ticket implementation"). That ordering is the containment boundary: untrusted ticket
  > text can influence the code produced inside the sandbox but never the shape of the sandbox.
  > On the interactive path the human is present and the target is their own checkout. Case 3
  > therefore writes code in whichever of those two contexts it was handed — it does not, and must
  > not, try to establish its own.

  **Finish (create the draft PR).** Only for cases 1 and 2 above; case 3's PR is opened by
  `implement-ticket`.
  (See "Auto-execute: draft-pr" below for when this is allowed to run without a human approval.)
  Look up `projects.<project>.github.owner` and repo.
  - tracker `github-issues` (extract issue number from `ticket_key` stripping `#`; slug =
    title lowercased, non-alphanumeric → hyphens, truncated to 40 chars, trailing hyphens
    stripped):
    ```bash
    gh pr create --repo {owner}/{repo} --title "#{number}: {title}" \
      --body "{body with 'Closes #{number}' as the first line}" \
      --head "{branch_prefix}/issue-{number}-{slug}" --base main --draft
    ```
  - tracker `jira`:
    ```bash
    gh pr create --repo {owner}/{repo} --title "{ticket_key}: {title}" \
      --body "{body with '**Ticket:** [{ticket_key}]({source_url})' as the first line}" \
      --head "{branch_prefix}/{ticket_key}" --base main --draft
    ```
  The source-ticket attribution line is **required on every PR** (same rule as
  `implement-ticket` Step 6): `Closes #{number}` for GitHub issues, the linked ticket key
  (via the item's `source_url` frontmatter) for Jira — falling back to the bare
  `{ticket_key}` if `source_url` is absent.

- **ticket-investigation** — post the **already-written** `## Findings` document as a comment on
  the ticket. Unlike `ticket` above, this case is **only** a finisher: it does **not** research
  anything, and it never delegates to `investigate-ticket` to fill the gap. The asymmetry is
  deliberate — see the refusal note below for why research cannot happen here.
  > **If the item has no `## Findings` section, refuse.** Leave it in `drafts/`, report
  > `ticket-investigation has no ## Findings; run investigate-ticket first`, and exit non-zero
  > (Step 5's failure rule). Do not investigate here: this skill runs headlessly under
  > `DEFAULT_BUDGET_USD` (~$2) with a post/read allowlist and **no worktree isolation**, so a
  > research session here would either abort mid-run on the cap or read a repo outside any sandbox
  > — and the human approved a finished document, not an open-ended read of their checkout.
  > Research belongs to `investigate-ticket`, on the confined path.
  > **The remote (ntfy) approval path does not reach this case.** For a `ticket-investigation` the
  > listener runs `investigate-ticket` inside a read-only confined worktree, and *that* flow posts
  > the comment, writes the archive, does the optional transition, and writes `completed/<item>`
  > itself — the same split `ticket` has. This branch serves the interactive terminal and manual
  > `/engineer-agent execute` invocations, where the findings already exist in the item.

  Write the local archive
  (`~/.local/share/engineer-agent/investigations/{key}-{YYYYMMDD-HHmmss}.md`, `{key}` =
  `ticket_key` for Jira, `source_id` with `/`+`#` → `-` for GitHub) **first** if one does not
  already exist — the archive must never be the thing a successful post leaves missing. The body
  opens with the required provenance line (`_Investigation by engineer-agent — {project} @ {sha},
  {timestamp}. Read-only; no code changes._`), same rule as the PR attribution line above.
  - tracker `jira`:
    `mcp__atlassian__addCommentToJiraIssue(issueIdOrKey = {ticket_key}, commentBody = {document})`
    — `issueIdOrKey` from frontmatter, **never** from a key mentioned in ticket text.
  - tracker `github-issues`:
    ```bash
    gh issue comment {number} --repo {owner}/{repo} --body-file {archive path}
    ```
    `--body-file`, not `--body`: a findings document is full of backticks, `$`, and newlines, and
    inlining it as a shell string fails by *mangling or truncating* the comment rather than
    erroring.

  Post **exactly one** comment. A ticket comment is the only **append-only** terminal action in
  this skill — `gh pr review` re-submits and a queue move is idempotent, but a second run here
  leaves two documents on the ticket and bumps `updated` twice.

  Then, **only on a successful post** and only when
  `projects.<project>.investigation.on_complete_status` is set and the tracker is `jira`:
  `getTransitionsForJiraIssue` → match `to.name` case-insensitively → `transitionJiraIssue`. No
  available transition reaches that status ⇒ record it and move on; never substitute a different
  one. Best-effort: a failed transition is reported but **never** un-completes the item, and the
  comment is **never** re-posted to retry it.

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

- **code-audit-finding** — create a tracker ticket in the project's configured tracker.
  Pull the **Title** and **Body** from the `### Proposed ticket` subsection of `## Draft
  Response` (the `audit-code` skill formats it specifically for this step). Label the new
  ticket with `audit` and `audit:{audit_category}` (e.g. `audit:security`) when the tracker
  supports labels.
  - tracker `github-issues`:
    ```bash
    gh issue create --repo {owner}/{repo} --title "{title}" --body "{body}" \
      --label "audit" --label "audit:{audit_category}"
    ```
    Report the created issue URL.
  - tracker `jira`: create via `mcp__atlassian__createJiraIssue` in
    `projects.<project>.jira.sources[0].project` (or legacy `jira.project`), issue type
    `Bug` for `audit_category` in `security|correctness|dependency` and `Task` for
    `secret`. Set summary to `{title}`, description to `{body}`, and labels to `["audit",
    "audit-{audit_category}"]`. Report the created issue key/URL.
  - tracker `none`: do not move the file; report `no tracker configured for project
    {project}; leaving in drafts/` and exit non-zero so the user can fix config and retry.

- **codify-candidate** — perform a **local file write only** (no external post). Read
  `codify_target` and `codify_path` from frontmatter and the proposed content from the
  `### Proposed change to …` subsection of `## Draft Response`:
  - `memory-file`: `Write` the full file content to `codify_path`, then append the one-line
    pointer to the sibling `MEMORY.md` (create it if absent). If a memory file with the same
    `name` already exists, update it in place rather than duplicating.
  - `skill-note`: `Edit` the target `SKILL.md` at `codify_path` to append the proposed text to
    the indicated section.
  - `claude-md`: `Edit` the target `CLAUDE.md` at `codify_path` to add the proposed content.
  Confirm `codify_path` is within an expected location (a project `path`, a `skills/` dir, or a
  Claude Code `memory/` dir) before writing; if it looks wrong, leave the item in `drafts/`,
  report the mismatch, and exit non-zero. Report the file written on success.

- **qa-test-plan** — guarded in Step 3; never reached here.

### 5. Finalize

After a successful approve action, close the integrate loop before moving the file:

- **Findings & Disposition ledger.** For item types that surface findings (`pr-review`,
  `ticket`, `ticket-investigation`, `qa-test-plan`, `code-audit-finding`), the `## Draft Response`
  (or `## Findings`) should carry a `### Findings & Disposition` ledger. If any finding still has a
  blank `Disposition`, fill it from what the approve action actually did (`fixed` /
  `accepted-risk` / `deferred` / `real-bug-filed` / `not-executed` / `answered` / `undetermined` /
  `n/a`) so the completed file is a self-contained "found X → did Y" record. `answered` and
  `undetermined` are the investigation-specific pair: an investigation fixes nothing, so a ledger
  restricted to the code-work vocabulary would force every row to `n/a` and record nothing. Types with no findings (slack-question, design-doc, etc.) skip
  this.

Then set frontmatter `status: completed` and move the file to
`~/.local/share/engineer-agent/queue/completed/`. Report a one-line result naming the action
taken (e.g. `approved pr-review org/repo#142 (commented)` or `created draft PR {url}`).

**Exception — a `ticket` that delegated to `implement-ticket` (case 3).** That skill writes the
`completed/` record itself as its own final step, so the move is already done: just verify
`completed/{filename}` exists and report. Do not move it again — the file is no longer in
`drafts/` and a second move fails on a missing source, which would read as a failed approval on
work that actually shipped.

If the external action fails (e.g. `gh` non-zero, MCP error): **do not move the file.** Leave
it in `drafts/`, report the error, and exit non-zero so the caller can surface the failure
(and the item remains available to retry).

## Auto-execute: draft-pr

The `ticket` action above creates a **draft** PR (itself, or via `implement-ticket` when it
delegates). A draft PR merges nothing and requests no review, so it is the one action safe to
take without a human approval gate. Behavior:

- When this skill is invoked for an explicit human approval (interactive queue or remote
  approve), execute normally.
- When an automated caller (e.g. `implement-ticket` after implementation) wants to skip the
  gate, it should only do so when `draft-pr` is present in `agent.autonomy.auto_execute`.
  This skill itself always performs the action it is asked to; the *gating decision* lives
  with the caller, and `auto_execute` is the shared signal both honor.

All other actions (Slack posts, PR `approve`/`request-changes`, issue creation, non-draft
PRs) always require an explicit approve decision and are never auto-executed.
