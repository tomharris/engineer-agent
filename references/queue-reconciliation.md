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
covers it. Run with `--heal` (as `cron-poll.sh` does) it also *resolves* the duplicates that need no
human judgement — see "Auto-healing" at the end of this file.

## The invariant

> **At most one queue file per `(type, source_id)` pair, across all four queue directories.**

`type` is part of the key on purpose: one ticket legitimately yields several items of *different*
types over its life (a `ticket` item, then a `qa-test-plan` for the same `ticket_key`). Those are
not duplicates. Two `ticket` items for one `source_id` always are.

### The one exception: `{ticket, ticket-investigation}` is a single type family

`ticket` (code change → draft PR) and `ticket-investigation` (findings document → ticket comment)
are two *shapes* of the same work, chosen by `references/ticket-kind.md`. A ticket's kind can change
between polls — someone edits its Jira issue type, or retitles it `Spike: …` — and because the
invariant is keyed on `(type, source_id)`, the naive rule then mints a rival item for work already
queued or already finished. Terminal state would absorb nothing, because the key changed underneath
it.

So **a `source_id` may have at most one live item across the pair, and a terminal item of either
type absorbs the other.** Two asymmetric consequences, and each needs its rationale stated or the
next reader will "fix" one of them:

- **The poller lookup is family-wide, *including* terminal items.** When the candidate is either
  ticket type, look up existing items of **both** types for that `source_id` and apply the table
  below to whatever you find. This is what keeps the absorbing rule working after a kind flip — and
  it matters more here than anywhere else, because an investigation's own deliverable *is* a ticket
  comment, i.e. the exact `updated` bump described above.
- **`scripts/queue-dedup-check.sh` collapses the family only among *non-terminal* items.** Two live
  items for one `source_id` across the pair is always a poller failure. But a *completed*
  investigation followed by a fresh implementation draft is the legitimate spike → outcome handoff
  (`/engineer-agent add-ticket {KEY} --implement`), and flagging it would leave the check
  permanently red on the most likely real workflow — the crying-wolf failure described below.

Changing the deliverable of an already-handled ticket is a **human** act, exactly like reopening
one: `/engineer-agent add-ticket {ref} --investigate` / `--implement`.

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
about to write, **except for the two ticket types, which are looked up as one family** (see "The one
exception" above: a `ticket` candidate must also find an existing `ticket-investigation` for that
`source_id`, and vice versa). Then take exactly one branch:

| Existing item | Action | Rationale |
|---|---|---|
| **In `completed/` or `rejected/`** | **Skip. Unconditionally.** Do not write, do not update. Count it and report it (see "Reporting"). | Terminal state is **absorbing**. The external action already ran or was explicitly declined. This is the branch that breaks the self-triggering loop: no amount of new activity — least of all the agent's own — may resurrect finished work. |
| **In `drafts/`** | **Leave the file alone.** Do not write a second file. Do not modify it. Count it as `unchanged`. | A draft is human-owned: someone may be mid-review, or may have hand-edited the draft response. Silently rewriting it under them destroys work. Fresh tracker context is not worth that. |
| **In `incoming/` and still `_unrouted`** | **Update that file in place.** Refresh the `## Context` section from the tracker, retry routing, and if it now resolves, set `project` / `routing_method` / `routing_rationale`, remove `matched_projects`, classify the deliverable per `references/ticket-kind.md` (only now possible — the kind lists are per-project, so they need the slug), set `type` and the `ticket_kind_*` fields, generate the matching draft, set `status: drafted`, and move the file to `drafts/`. Keep the original `{YYYYMMDD-HHmmss}` prefix; the `{type}` segment of the filename is corrected if the kind resolved to an investigation. An item that already *has* a kind never has it re-decided here — only one it never had is filled in. | This is the legitimate re-check intent. It just has to mutate the existing item instead of minting a rival. Keeping the filename preserves the original `created_at` ordering, so a long-unrouted ticket does not keep jumping to the top of the queue. |
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

## Auto-healing

A duplicate used to be a pure alarm: the check went red and the poll re-pushed the identical ntfy
warning **every 15 minutes** until a human hand-rejected a copy — on the same topic the
Approve/Reject buttons arrive on. A topic that cries wolf four times an hour stops being read, which
defeats the remote approval gate itself. But most duplicates are mechanical (the poller minted a
rival file instead of updating in place) and one of the two copies holds no work at all, so the
resolution is one a script can get right.

`queue-dedup-check.sh --heal` resolves a group when **both** hold:

1. **No copy is in `completed/`.**
2. **At most one copy is *substantive*** — in `drafts/`, or carrying a `## Draft Response`.

The substantive copy is kept; if there is none, the **oldest** is kept (the filename's
`{YYYYMMDD-HHmmss}` is the created_at ordering, kept deliberately so a long-queued item does not
jump to the top of the review queue). Every other copy is **rejected**, not deleted: it moves to
`rejected/` with `status: rejected` and a `rejected_reason` naming the copy that was kept, so an
auto-resolution is auditable and reversible. `rejected/` is the disposal path the invariant already
ignores, so the group is genuinely resolved rather than suppressed.

**What it refuses to touch, and why each refusal is required rather than cautious:**

- **A group containing a `completed/` copy.** That is *either* the self-sustaining re-queue loop
  (heal-worthy) *or* a human's deliberate `add-ticket` override of terminal state, which "Manual
  add" above explicitly permits — and the two are indistinguishable on disk **by design**
  (`commands/add-ticket.md`: the item is written "so downstream skills see no difference between a
  manually-added and a polled item"). Auto-rejecting would silently discard the human's re-add.
- **A group with two or more substantive copies.** A draft is human-owned — someone may be
  mid-review or may have hand-edited it — and nothing on disk says which of two drafts to keep.

What remains after healing is exactly the set that needs a person, and `cron-poll.sh` pushes about
each `(type, source_id)` **once**: `--keys` prints the post-heal, post-baseline list, and the poll
diffs it against `state/queue-dedup-notified.tsv`. That ledger is rewritten to whatever is
unresolved *now*, so a duplicate that is resolved and later recurs is announced again rather than
swallowed by a stale entry. Pushed once, visible always: `/engineer-agent status` reports the
standing count so silence never means the duplicate went away.
