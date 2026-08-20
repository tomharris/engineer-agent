# Queue Reconciliation

Single source of truth for deciding **whether a polled item enters the queue, updates an item
already there, or is skipped**.

Read this file and follow it verbatim from:
- `skills/poll-jira/SKILL.md`
- `skills/poll-github-issues/SKILL.md`
- `skills/poll-github/SKILL.md`
- `skills/poll-slack/SKILL.md`
- `skills/poll-slite/SKILL.md`
- `commands/add-ticket.md` (manual add — the one caller allowed to override, see "Manual add")

Do not re-describe these rules in those files — delegate to this one, so the callers cannot drift
apart. This is a plain reference document, not a skill: callers reach it with `Read`, because
`scripts/cron-poll.sh` allowlists `Read` but not `Skill` or `Agent`.

`scripts/queue-dedup-check.sh` is the executable check on the invariant below. `tests/queue-dedup.test.sh`
covers it.

## The invariant

> **At most one queue file per `(type, source_id)` pair, across all four queue directories.**

`type` is part of the key on purpose: one ticket legitimately yields several items of *different*
types over its life (a `ticket` item, then a `qa-test-plan` for the same `ticket_key`). Those are
not duplicates. Two `ticket` items for one `source_id` always are.

### Why this needs stating

A duplicate is invisible on disk. Queue filenames embed a `{YYYYMMDD-HHmmss}` minted at write time,
so a second copy never collides with the first — it just appears alongside it, and the human either
reviews the same work twice or implements it twice. Nothing else in the system notices.

Two earlier rules each produced duplicates in practice, and both read as reasonable in isolation:

1. **Unrouted re-check.** An `_unrouted` item is deliberately kept out of `seen_*` state so it is
   re-examined until assigned. On the poll that finally routed it, the poller wrote a *new* file
   rather than updating the `_unrouted` one already sitting in `incoming/`.
2. **"Re-queue for updated context."** Re-queueing anything touched since `last_checked` fires for
   tickets touched by **engineer-agent itself**. Recording findings as a Jira comment bumps
   `updated`, which re-queues the ticket that was just completed — and that loop is
   self-sustaining, because the next cycle writes another comment.

Both are fixed by the same thing: a lookup keyed on `source_id` **before** deciding to write, and
one explicit branch per outcome.

## The rule

For every candidate item, **before routing and before drafting**, look up existing queue files whose
frontmatter `source_id` matches the candidate's, across **all four** directories
(`incoming/`, `drafts/`, `completed/`, `rejected/`) — restricted to the same `type` the poller is
about to write. Then take exactly one branch:

| Existing item | Action | Rationale |
|---|---|---|
| **In `completed/` or `rejected/`** | **Skip. Unconditionally.** Do not write, do not update. Count it and report it (see "Reporting"). | Terminal state is **absorbing**. The external action already ran or was explicitly declined. This is the branch that breaks the self-triggering loop: no amount of new activity — least of all the agent's own — may resurrect finished work. |
| **In `drafts/`** | **Leave the file alone.** Do not write a second file. Do not modify it. Count it as `unchanged`. | A draft is human-owned: someone may be mid-review, or may have hand-edited the draft response. Silently rewriting it under them destroys work. Fresh tracker context is not worth that. |
| **In `incoming/` and still `_unrouted`** | **Update that file in place.** Refresh the `## Context` section from the tracker, retry routing, and if it now resolves, set `project` / `routing_method` / `routing_rationale`, remove `matched_projects`, generate the draft, set `status: drafted`, and move the **same** file to `drafts/`. Keep the original filename. | This is the legitimate re-check intent. It just has to mutate the existing item instead of minting a rival. Keeping the filename preserves the original `created_at` ordering, so a long-unrouted ticket does not keep jumping to the top of the queue. |
| **In `incoming/` with a resolved project** | **Leave it alone.** Count as `unchanged`. | Already routed and awaiting draft generation; a second write would race the drafting step. |
| **Nothing anywhere** | **Create a new item** as the poller's write step describes. | The only case that mints a file. |

### Terminal is absorbing — and how to override

Skipping terminal items means a genuinely reopened ticket will not re-enter the queue on its own.
That is the correct default: the alternative re-queues finished work every cycle. When a ticket
really does need new work after completion, the override is **explicit and human**:

```
/engineer-agent add-ticket {TICKET-KEY}
```

### Manual add

`commands/add-ticket.md` is the one caller permitted to write an item whose `source_id` already
exists in a terminal directory, because a human asked for it by name. It must still not create a
*second live* item: if a matching item exists in `incoming/` or `drafts/`, report that and stop
rather than duplicating.

## Relationship to `seen_*` state

`state/last-poll.yaml`'s `seen_tickets` / `seen_issues` / `seen_prs` / `seen_docs` lists remain a
**cheap pre-filter** — they let a poll skip work without reading queue files. They are not the
invariant, and they are not authoritative:

- A `seen_*` hit is a reason to skip **querying detail**, never a substitute for the reconciliation
  lookup above.
- A `seen_*` **miss** does not license a write. Run the lookup regardless. The lists are lossy by
  design (unrouted items are deliberately omitted) and can be trimmed or lost without harm.

Keep appending to them as each poller's state step already describes.

## Reporting

Never let a skip be silent — a poll that says "0 new items" when it skipped six already-handled
tickets is indistinguishable from a broken poll. Each poller's report line must carry the counts:

```
Found N new {items}. R routed, U unrouted, S skipped (already handled), X unchanged.
```

If `S > 0`, add one line naming the skipped ids, so a wrongly-absorbed ticket is visible:

```
Skipped (terminal): WIRE-2189, WIRE-2201
```
