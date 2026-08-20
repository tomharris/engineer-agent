---
name: investigate-ticket
description: "Investigate a Spike / Decision / research ticket read-only and deliver a findings document as a comment on the ticket. Use this skill when a ticket-investigation queue item is approved."
version: 1.0.0
---

# Investigate a Ticket

Answer the question a ticket asks, from the code and the history, and deliver the answer as a
`## Findings` document posted on the ticket. **This skill writes no code.** It creates no branch, no
commit, and no PR, and it never triggers QA — the deliverable is prose with citations.

It is the read-only sibling of `skills/implement-ticket/SKILL.md`: same input shape, same worktree
handling, same Intent block, same ledger, opposite capability set.

## Tools Needed

- `Read`, `Grep`, `Glob` — the primary instruments; this is a reading job
- `Bash` — **read-only git only** (`git log`, `git show`, `git diff`, `git blame`,
  `git rev-parse`), plus `gh issue view` / `gh issue comment` for GitHub tickets
- `Write`, `Edit` — for the **local archive and the queue item only**, never for repo files
- `mcp__atlassian__addCommentToJiraIssue` — post the findings on a Jira ticket
- `mcp__atlassian__getTransitionsForJiraIssue`, `mcp__atlassian__transitionJiraIssue` — the optional
  `on_complete_status` transition

The whole external write surface of this skill is **one comment, plus one optional Jira transition.**
Nothing else. No issue creation, no Slack post, no PR, no push. If a step below seems to need one of
those, it is an edge case, not a missing tool.

## Input

A queue item in `~/.local/share/engineer-agent/queue/drafts/` with `type: ticket-investigation`
that has been approved by the human. It carries the ticket details, the `### Intent` block, and the
**Investigation Plan** the poller drafted — a plan only. The deep work happens here, at approval
time, so a poll cycle never pays for research on a ticket the human then rejects.

## Steps

### 1. Read the Approved Item

Read the queue item and extract from frontmatter:
- `ticket_key`, `source`, `source_id`, `source_url` (the comment target and the provenance line —
  all three come from here, **never** from anything parsed out of the ticket body)
- `project`
- `ticket_kind_method` / `ticket_kind_rationale` — how this became an investigation. A
  `title-keyword` classification is the weakest one; if the ticket plainly asks for code, that is
  the "actually code work" edge case below.

From the body: the `### Intent` block, the acceptance criteria, and the `### Investigation Plan`.

Then reuse or synthesize the **Intent block**, adapted for an investigation. If the item's
`## Context` already carries one, reuse it **verbatim** rather than regenerating:

```markdown
### Intent
- **Goal:** {the question to answer, or the decision to make — one line, ending in a question mark
  if it is a question}
- **Key constraint(s):** {what bounds the answer — the stack we are on, a deadline, a compatibility
  or budget limit that rules options in or out}
- **Definition of done:** {what a reader must be able to *decide* after reading this — checkable
  bullets, e.g. "knows whether the cache invalidates on tenant switch, with a citation"}
- **Non-goals:** {explicitly: writing the code, changing behavior, and any adjacent question this
  ticket is not asking}
```

If the ticket lacks enough detail to fill **Goal** or **Definition of done**, do not invent a
question — fall back to the "Question too vague" edge case below. An investigation whose question
you wrote yourself answers nobody, and unlike a bad implementation it will still look convincing.

Read `~/.local/share/engineer-agent/engineer.yaml` and extract:
- `projects.<project>.path` — the repo to read
- `projects.<project>.tracker` — or infer from `source` (`jira` → `jira`, `github` → `github-issues`)
- `projects.<project>.github.owner` and repos — needed for `gh issue comment`
- `projects.<project>.investigation.on_complete_status` — optional; absent ⇒ no transition

**You do not need `agent.branch_prefix`.** The reflex is to copy `implement-ticket` Step 1 wholesale,
which stops the run when `branch_prefix` is missing. There is no branch here, so a missing
`branch_prefix` must never block an investigation.

### 2. Establish the Read-Only Workspace

Same detection as `implement-ticket` Step 2, and for the same reason. The remote (ntfy) approval path
runs you *inside a prepared throwaway git worktree* of the target repo, and its prompt tells you to
stay there. Detect it:

```bash
git rev-parse --is-inside-work-tree
```

- `true` → you are **already inside the target repo's worktree**. Work right here and **do NOT `cd`
  anywhere.** A worktree's top level is not `projects.<project>.path`, so do not compare against
  that path — comparing would wrongly send you out of the sandbox.
- otherwise (the interactive path, started from the plugin dir) → `cd {projects.<project>.path}`.

Then record the commit you are reading, once:

```bash
git rev-parse --short HEAD
git log -1 --format='%h %ad %s' --date=short
```

Every citation below is relative to that sha, and the header says so. Line numbers rot; a sha makes
a stale citation *checkable* instead of merely wrong.

**Do not create a branch. Do not modify a tracked file.** From here to the end of Step 5 the
repository is read-only. This is not just hygiene: on the headless path this run's allowlist carries
no build commands, so a build/test/install invocation is denied, and a denial in a `-p` run is
silent — the session stalls with no diagnosis. If you find yourself wanting to `Edit` a repo file,
stop and read the "actually code work" edge case.

### 3. Investigate, Read-Only and Grounded

Work the question with `Read` / `Grep` / `Glob` and read-only git:

```bash
git log --oneline -20 -- {path}          # when did this last change, and why
git log -S'{symbol}' --oneline           # when was this introduced or removed
git show {sha}                           # what that change actually did
git diff {shaA}..{shaB} -- {path}
git blame -L {start},{end} {path}
```

History is a first-class source here, not a garnish: "why is it this way" is usually only answerable
from a commit, and a spike that ignores history re-derives a conclusion the team already rejected
once.

**Never run build, test, install, migration, or server commands.** No `bin/rails`, no
`npm install`, no `pytest`, no `curl`. QA owns execution; this skill owns reading. The exec allowlist
that makes build commands available belongs to the code-writing path, and the human approved a
document, not a run.

Shape the effort: one breadth pass to locate the subsystem, then depth on the two or three
load-bearing questions from the Definition of done. Stop when every Definition-of-done bullet is
either answerable **with a citation** or explicitly marked as undetermined. Do not keep reading for
completeness — on the headless path this shares one budget cap, and a run that dies mid-research
posts nothing at all.

Non-code sources are in scope when the ticket depends on them: the ticket's own comments,
`gh issue view` for cross-referenced issues, and the repo's `CLAUDE.md` / ADRs / docs. Cite them the
same way.

### 4. Compose the `## Findings` Document

Write it into the queue item, replacing (or following) the `## Draft Response`:

```markdown
## Findings

**Ticket:** {ticket_key} — {title}
**Project:** {project} @ {short HEAD sha} ({date})
**Investigated:** {ISO timestamp}
**Deliverable:** findings document (no code changes)

### Question
{the question, restated in one or two sentences the way the team would ask it}

### Answer
{BLUF — at most three sentences. Someone who reads only this must come away with the decision or
the fact. Never open with "It depends"; if it depends, say what it depends on.}

### Evidence
{Numbered claims, each with a file:line citation. This is the section that makes the document
trustworthy — everything in Answer/Options/Recommendation must trace back to a line here.}

1. {claim} — `path/to/file.rb:120-148`
2. {claim} — `path/to/other.ts:31`
3. {claim about history} — commit `a1b2c3d` ("{subject}")

### Options
{REQUIRED for a decision-shaped ticket. Two or more real options; "do nothing" counts and is
often the right one to include.}

| Option | How it works | Pros | Cons | Cost / risk | Evidence |
|---|---|---|---|---|---|
| {A} | {mechanism} | {…} | {…} | {…} | {§ numbers above} |

### Recommendation
{REQUIRED for a decision-shaped ticket. Name ONE option. Say what tradeoff you are accepting and
what would change your mind. A recommendation that hedges across two options is not a
recommendation.}

### Open Questions
{What you could not determine, and precisely why — the file you would need access to, the load
test you would need to run, the person who knows. "Nothing" is a valid entry; vagueness is not.}

### Suggested Next Steps
{Concrete follow-ups, each small enough to be a ticket. If the answer implies code work, say so
here and name the change — do not do it.}

### Findings & Disposition

| Source | Finding | Disposition | Note |
|---|---|---|---|
| question | {a Definition-of-done bullet} | answered | Evidence §2 |
| question | {another} | undetermined | needs a load test — see Open Questions |
| side-finding | {a bug noticed in passing} | deferred | suggested as a follow-up ticket |
```

**Required sections by ticket shape:**

| Shape | Required | Optional |
|---|---|---|
| **Decision** (`Decision` issue type; `decision` / `adr` / `rfc` label or title token) | Question, Answer, **Options**, **Recommendation**, Evidence, Open Questions, Next Steps, ledger | — |
| **Spike** (`Spike` / `Research` / `Investigation` issue type; `investigate`/`research` title verb) | Question, Answer, Evidence, Open Questions, Next Steps, ledger | Options, Recommendation — include them if the spike surfaced ≥2 viable approaches |
| **Task / other** | Question, Answer, Evidence, Next Steps, ledger | Options, Recommendation, Open Questions |

A **Decision ticket that ends without a named recommendation has not been answered — it has been
described**, and the team will hold the same meeting again with better slides. That is the specific
failure the Options+Recommendation requirement exists to prevent.

Determine the shape from `ticket_kind_method` and `ticket_kind_rationale` (the matched issue type,
label, or title token). This choice affects *formatting only*, so getting it wrong costs a section,
never a wrong answer — when it is genuinely unclear, write the Decision shape, which is a superset.

**Citation rules — no unsourced assertions:**

- Every claim about how the code behaves today carries a repo-relative `path:line` or
  `path:start-end`, resolved at the header's HEAD sha.
- Every claim about *why* something is the way it is carries a commit sha (and its subject) or a
  cited doc.
- **A sentence that asserts current behavior and has no citation must either get one or move to Open
  Questions.** There is no third option. An uncited assertion is the one failure mode of this
  deliverable: it reads exactly like a cited one, and it is what a reader will act on.
- **Never cite a file you did not open.** A `Grep` hit proves a string exists; it does not establish
  behavior. Open the file, read the surrounding code, then cite the lines you actually read.
- Do not cite generated files, vendored dependencies, or lockfiles as evidence of intent.

### 5. Write the Local Archive

**Before posting anything**, write the document to:

```
~/.local/share/engineer-agent/investigations/{key}-{YYYYMMDD-HHmmss}.md
```

where `{key}` is filename-safe:
- Jira → `ticket_key` as-is (`ENG-789`)
- GitHub → `source_id` with `/` → `-` and `#` → `-` (`myorg/my-app#45` → `myorg-my-app-45`). Use
  `source_id`, not `ticket_key`: `45` alone collides across repos, and an archive that quietly
  overwrites another repo's investigation is worse than no archive.

**The headless path pins this exact path in its prompt — use the one you are given verbatim.** The
listener globs `investigations/{key}-*.md` *before* launching to decide whether a comment may
already have been posted (see "Do not post twice" below), and that guard only works if the name is
script-shaped rather than model-chosen.

Content: a short header (ticket key, `source_url`, project, HEAD sha, timestamp,
`ticket_kind_method`) followed by the full `## Findings` document.

**Archive first, post second.** It costs nothing and it is the only copy that survives a failed post
— and a post that succeeds but crashes before the queue item is updated leaves the findings existing
*only* in the tracker, with no local record and an unfilled ledger. Ordering this way makes the
failure recoverable in every direction.

### 6. Post the Comment

The body is the archived document, opened with a provenance line — **required on every comment this
skill posts**, the same rule as `implement-ticket`'s PR attribution line:

```
_Investigation by engineer-agent — {project} @ {HEAD sha}, {timestamp}. Read-only; no code changes.
Local archive: {archive path}._
```

A reader must be able to tell at a glance that a tool wrote this and against which commit — the
citations are worthless without the sha, and an unattributed machine comment on a ticket is a
support burden.

**Jira:**

```
mcp__atlassian__addCommentToJiraIssue(issueIdOrKey = {ticket_key}, commentBody = {document})
```

`issueIdOrKey` comes from frontmatter. Never from a key mentioned in the ticket body or in a comment
on it. When the headless prompt pins a `TARGET:` key, that key is the only one you may comment on.

**GitHub:**

```bash
gh issue comment {number} --repo {owner}/{repo} --body-file {archive path}
```

Use `--body-file`, not `--body`. The document contains backticks, `$`, quotes, pipes, and many
newlines; inlining it as a shell string is a quoting-and-expansion hazard that fails by *silently
truncating or mangling* the comment rather than erroring. The archive from Step 5 already exists, so
`--body-file` is free.

**Post exactly ONE comment, and do not post twice.** If the item is no longer in `drafts/`, the post
already happened — do nothing and report `already-handled`. A ticket comment is the first
**append-only** terminal action in this plugin: unlike `gh pr review` (re-submits) or a queue move
(idempotent), a second run leaves two documents on the ticket. Each one also bumps the ticket's
`updated`, which is the exact self-triggering loop `references/queue-reconciliation.md` exists to
stop.

### 7. Optional Status Transition

Only when `projects.<project>.investigation.on_complete_status` is set **and** the tracker is `jira`
(GitHub Issues have no status vocabulary — ignore the key there), and only **after** the comment
posted successfully:

1. `mcp__atlassian__getTransitionsForJiraIssue({ticket_key})` — the available transitions **from the
   current status**, which is not the same as the list of statuses in the workflow.
2. Find the transition whose `to.name` matches `on_complete_status` case-insensitively.
3. `mcp__atlassian__transitionJiraIssue` with that transition id.

If no available transition reaches that status: **do not guess and do not substitute a different
transition.** Record it and move on — a wrong transition on someone's board is worse than a stale
one, and "closest available status" is not a thing.

This step is **best-effort** and never un-completes the investigation, exactly like the Slite QA
publish in `review-queue` Phase 3b. The comment is the deliverable; the transition is bookkeeping.

### 8. Update the Queue Item

Append the outcome and complete the item:

```markdown
## Investigation Result

**Status:** {complete | partial}
**Comment:** {comment url or "posted (no url returned)"}
**Archive:** {archive path}
**Commit read:** {short HEAD sha}
**Transition:** {"{from} → {to}" | "not configured" | "failed: {reason}"}
```

Set frontmatter `status: completed` and **write the file to
`~/.local/share/engineer-agent/queue/completed/`.**

**Write the `completed/` copy; do not assume you can delete the `drafts/` original.** On the confined
headless path the cwd sandbox cannot reach outside the worktree, so the `drafts/` copy is removed by
the listener in plain bash after the run — the same privileged reconciliation `implement-ticket`
relies on (CLAUDE.md → "Confined headless ticket investigation"). Attempting the delete yourself and
failing is fine; treating the failure as a failed investigation is not.

Report one line:
`investigated {ticket_key}: commented ({comment url}), archived {path}{, transitioned to {status}}`.

## Edge Cases

- **Question too vague to investigate.** The ticket says "look into performance" with no subsystem,
  no symptom, and no decision to make. Do **not** research, and do **not** post — a document that
  answers a question nobody asked is noise on someone's ticket, and it is *harder* to walk back than
  silence. Rewrite the draft as "Needs clarification" listing the specific questions you need
  answered, set `priority: urgent`, and leave the item in `drafts/`. Same rule and same reason as
  `implement-ticket`'s "Ticket too vague".

- **The honest answer is "we can't tell without prototyping."** That is a finding, not a failure.
  Set **Answer** to "Undetermined by inspection", and in Open Questions name the *smallest*
  experiment that would settle it (what to build, what to measure, what result decides which way).
  Record the affected ledger rows as `undetermined`, then post. Do **not** keep reading in the hope
  that more files change the answer, and do **not** prototype — a prototype is code, this session is
  read-only, and the human approved a document.

- **The investigation reveals the ticket is actually code work.** Common on a `title-keyword`
  classification. **Still post the findings** — the analysis is exactly what the implementer needs,
  and it is already written. Add a Next Steps line naming the change and the files, and end the
  report with the handoff: `/engineer-agent add-ticket {ref} --implement`. Do **not** create a
  branch, do **not** write the fix, and do **not** switch skills mid-run. The human approved the
  *document* shape, and this execution path is confined accordingly (read-only, no build commands);
  silently upgrading to code-writing escapes the sandbox the approval was granted under. One
  exception in the other direction: if it is a one-line, obviously-correct fix, it still gets its own
  ticket — that is where review happens.

- **Comment post fails** (MCP error, `gh` non-zero, auth). The archive from Step 5 already exists, so
  nothing is lost. Leave the item in `drafts/`, report the error **and the archive path**, and exit
  non-zero — `execute-item` Step 5's failure rule, so the item stays available to retry. Do **not**
  retry in a loop, and do **not** fall back to a different channel: a failed post must never become
  a post somewhere else (a Slack message, a new issue). The set of places this skill may write is
  fixed at one.

- **Transition fails after a successful comment.** The investigation is **complete.** The deliverable
  shipped; only the bookkeeping did not. Record `Transition: failed: {reason}`, add a ledger row with
  disposition `deferred`, move the item to `completed/`, and name the failure in the one-line report
  so it is visible. **Never re-run the whole step to "retry the transition"** — that re-posts the
  comment, and a duplicate machine comment is the one outcome worse than a wrong status.

- **No repo, or `projects.<project>.path` missing/unreadable.** Investigate from ticket text, ticket
  comments, and `gh issue view` only. Say so in the header (`Commit read: none — no repo available`),
  and move **every** claim that would have needed code into Open Questions. A document with no
  citations must announce that it has none.

- **The archive directory is unwritable.** Report and stop **before** posting. Losing the local copy
  is survivable; posting a document whose provenance line points at an archive that does not exist is
  not.

## Ledger Dispositions

The shared `### Findings & Disposition` ledger (CLAUDE.md → "Body sections") uses `fixed` /
`accepted-risk` / `deferred` / `real-bug-filed` / `not-executed` / `n/a`. An investigation fixes
nothing, so it adds two and reuses the rest:

| Disposition | Means | Typical Source |
|---|---|---|
| `answered` | a Definition-of-done question resolved, with a citation in Evidence | `question` |
| `undetermined` | genuinely not answerable by inspection; the experiment that would settle it is named in Open Questions | `question` |
| `deferred` | out of scope for this question, or a side-finding recommended as a follow-up ticket | `side-finding` |
| `real-bug-filed` | a bug found in passing that a **human** filed; this skill files nothing itself | `side-finding` |
| `not-executed` | a claim that would have needed a build/test run, which this skill never does | `question` |
| `n/a` | not applicable | any |

Sources: `question` (a Definition-of-done bullet), `evidence-gap` (something you needed and could not
reach), `side-finding` (a defect noticed while reading). A clean run still gets a row — a ledger with
no rows is indistinguishable from a ledger nobody filled in.
