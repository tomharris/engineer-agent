# Queue

## Queue File Format

Items enter the queue either via polling (`/engineer-agent poll` or the cron) or manually (`/engineer-agent add-ticket <ref>`). Both paths produce identically-shaped queue files.
Invoking `/engineer-agent:implement-ticket <ref>` directly also goes through `add-ticket` (forced
`--implement`) before implementing, so the ticket gets a queue item and a `seen_*` entry and the
next poll reconciles it as `unchanged` instead of queueing a duplicate. `seen_*` alone would not
do this: pollers dedup on queue files, and the scripted collectors never read `seen_*`.

Files move through: `~/.local/share/engineer-agent/queue/incoming/` → `queue/drafts/` → `queue/completed/` or `queue/rejected/`

**Invariant: at most one item per `(type, source_id)`.** `references/queue-reconciliation.md` is the
rule every poller follows to uphold it — skip / update-in-place / create, one branch each — and
`scripts/queue-dedup-check.sh` is the executable check, run automatically at the end of each
`cron-poll.sh`. A duplicate is otherwise invisible: queue filenames carry a `{YYYYMMDD-HHmmss}`
minted at write time, so a second copy of a ticket never collides with the first — it just sits
alongside it and the human reviews (or implements) the same work twice.

> **A duplicate must not become a recurring notification.** The check used to be a pure alarm: it
> stayed red, and the poll re-pushed the identical ntfy warning **every 15 minutes** until a human
> hand-rejected a copy — on the very topic the Approve/Reject buttons arrive on, which is the one
> topic that must never be trained into background noise. Two changes, both in
> `references/queue-reconciliation.md` → "Auto-healing":
> - **`--heal` (how `cron-poll.sh` now runs it) resolves what needs no judgement.** A group with no
>   `completed/` copy and at most one *substantive* copy (in `drafts/`, or carrying a
>   `## Draft Response`) is resolved by moving the others to `rejected/` with a `rejected_reason` —
>   keeping the substantive copy, else the oldest, so `created_at` ordering survives. Rejected, not
>   deleted: every auto-resolution stays auditable and reversible. These never reach the phone.
> - **What it refuses is pushed once per `(type, source_id)`,** tracked in
>   `state/queue-dedup-notified.tsv` and diffed against `queue-dedup-check.sh --keys` (the
>   post-heal, post-baseline list). The ledger is rewritten to whatever is unresolved *now*, so a
>   recurrence after a fix is announced again instead of being swallowed by a stale entry.
>   It refuses exactly two shapes, and both refusals are required rather than cautious: a group
>   containing a `completed/` copy is **indistinguishable by design** from a human's deliberate
>   `add-ticket` override of terminal state (healing it would delete their re-add), and a group with
>   two drafts gives no way to know which one a human is mid-review on.
> Pushed once, visible always — `/engineer-agent status` reports the standing count, so silence
> never means the duplicate went away.

Terminal state (`completed/`, `rejected/`) is **absorbing** for pollers. This is not fussiness: the
previous "re-queue anything updated since last_checked" rule was self-sustaining, because
engineer-agent recording its own findings as a Jira comment bumps `updated`, which re-queued the
ticket it had just completed, which produced another comment. `add-ticket` is the deliberate
human-only override.

`incoming/` is for items that are detected but not yet drafted; a skill drafts them and moves
them to `drafts/`. Skills that compose the full `## Draft Response` in the same run that
discovers the item (`audit-code`) write directly to `drafts/` as `status: drafted` instead —
there is no undrafted window to protect. **Only `drafts/` is reachable by the approval gate:**
`review-queue` lists `drafts/` (plus `_unrouted` items in `incoming/`), and `execute-item` acts
only on `drafts/`, treating anything else as an idempotent no-op. An item parked in `incoming/`
with a finished draft is invisible to both approval paths — terminal and ntfy — and fails
silently in each. When adding an item type, make sure something moves it to `drafts/`.

Filename: `{YYYYMMDD-HHmmss}-{type}-{short-id}.md`

YAML frontmatter fields:
- `type`: pr-review | slack-question | ticket | ticket-investigation | doc-review | spec-refinement | design-doc | ticket-plan | ticket-refinement | gap-audit | qa-test-plan | code-audit-finding | codify-candidate
- `source`: github | slack | jira | slite | file | audit | internal (`file` = a local document path
  given to `refine-spec` / `create-design-doc` / `create-tickets`; its `source_url` is a `file://`
  URI and its `source_id` is `file:{absolute path}`, so the spec → design doc → ticket-plan
  prior-artifact lookups chain the same way they do for `slite:{doc_id}`)
- `source_url`: URL to the original item
- `source_id`: Unique identifier (e.g. "org/repo#142")
- `title`: Short description
- `priority`: urgent | normal | low
- `created_at`: ISO 8601 timestamp
- `status`: incoming | drafted | completed | rejected
- `project`: Project slug matching a key in the `projects` config map, or `_unrouted` for tickets that could not be automatically routed
- `matched_projects`: (only for `_unrouted` items) array of project slugs that matched, or empty array if no rules matched. Applies to Jira and GitHub items alike.
- `routing_method`: which tier of `references/routing-ladder.md` resolved the project — `single-candidate` | `prefix` | `filters` | `keyword` | `inferred` | `manual` (`manual` = a human picked it via `add-ticket` or `review-queue`)
- `routing_rationale`: one line naming the evidence, **only** when `routing_method: inferred` — this is what makes an auto-routed judgment call auditable at the approval gate
- `ticket_kind_method`: (ticket / ticket-investigation only) which tier of
  `references/ticket-kind.md` chose the deliverable — `manual` | `jira-issuetype` | `github-label` |
  `title-keyword` | `default`. Absent on `_unrouted` items, which are classified late (the kind
  lists are per-project, so they need a slug first).
- `ticket_kind_rationale`: one line naming the evidence, **only** when `ticket_kind_method` is
  `title-keyword` — the tier that reads untrusted prose, so `review-queue` surfaces it at the gate
  exactly as it does `routing_method: inferred`
- `jira_issue_type`: (Jira tickets only) the issue type **name** (e.g. `Spike`) — the Tier 1 input,
  recorded so the gate can audit the decision's input and not just its output
- `jira_components`: (Jira tickets only) array of Jira component names on the ticket
- `jira_labels`: (Jira tickets only) array of Jira labels on the ticket
- `github_labels`: (GitHub issues only) array of label names on the issue
- `audit_category`: (code-audit-finding only) `security` | `correctness` | `secret` | `dependency`
- `audit_severity`: (code-audit-finding only) `critical` | `high` | `medium` | `low`
- `audit_confidence`: (code-audit-finding only) `medium` | `high` (low is filtered out)
- `audit_file`: (code-audit-finding only) repo-relative path to the offending file
- `audit_line_range`: (code-audit-finding only) e.g. `"42-58"`
- `jira_status`: (Jira tickets only) the ticket's current status name
- `doc_id`: (doc-review only) the Slite note id (`source_id` is the prefixed `slite:{doc_id}`)
- `doc_labels`: (doc-review only) array of labels the doc carries
- `label_source`: (doc-review only) `tags` | `query` — whether the doc's label match came from a
  real tag comparison or only from the search term that found it. Recorded because the Slite REST
  API does not reliably expose tags, and the gate should see when the match was the weaker kind
- `channel_id` / `channel_name` / `message_ts` / `author` / `author_id`: (slack-question only) where
  the message came from and who wrote it
- `thread_ts`: (slack-question only) the thread parent when the message is itself a reply; the
  answer is posted there instead of under `message_ts`
- `watch_source`: (slack-question only) `mentions` | `my-threads` when a slack/watch job found it
  that way; absent for a channel scan
- `relevance_method`: (slack-question only) how the "is this a question for me?" tier was decided —
  `typesafe` when `scripts/poll-slack.sh` judged it. Absent on a model-drafted item, which decided
  it inline and recorded nothing
- `relevance_scores`: (slack-question only, with `relevance_method`) the four raw probabilities,
  e.g. `question=0.93 directed=0.88 answered=0.04 engineer=0.81`. Recorded for the same reason
  `routing_rationale` is: this is a judgment tier reading untrusted prose, so the gate must be able
  to audit the evidence and not only the verdict
- `codify_target`: (codify-candidate only) `memory-file` | `skill-note` | `claude-md`
- `codify_path`: (codify-candidate only) absolute path of the file the learning will be written to on approval

Body sections:
- `## Context` — metadata about the work item. For ticket/implementation items this leads with
  an `### Intent` block (Goal / Key constraints / Definition of done / Non-goals) synthesized
  from the ticket so the session and PR are self-contained intent artifacts.
- `## Draft Response` — filled by the processing skill. Review/QA/implementation items carry a
  `### Findings & Disposition` ledger (Source | Finding | Disposition | Note) that records how
  each surfaced finding was resolved (`fixed` / `accepted-risk` / `deferred` / `real-bug-filed`
  / `not-executed` / `n/a`), closing the verify→integrate loop; `execute-item` ensures it is
  filled before an item moves to `completed/`.

