# QA Plan Documentation to Slite — Design

**Date:** 2026-06-24
**Status:** Approved (pending spec review)

## Goal

When a QA test plan is **completed**, optionally publish a permanent record of it to
Slite — the full test plan with all generated scripts inlined. This is controlled by a new
per-project config setting whose value names the documentation destination.

## Config

A per-project `qa` section gains two optional keys:

```yaml
projects:
  my-api:
    qa:
      base_url: "http://localhost:3000"
      console_command: ""
      document_to: "slite"        # "slite" | "" — destination for completed QA plans.
                                  # Empty or absent disables documentation. Only "slite" is supported today.
      document_parent: ""         # Slite channel/note id to create the QA doc under.
                                  # Empty/absent → default to the user's private (personal) Slite channel.
```

- `document_to` is the feature switch **and** the destination selector. Absent or empty ⇒
  feature off (current behavior, unchanged).
- `document_parent` only applies when `document_to: slite`. When set, the note is created
  under that Slite channel/note id (mirrors `slite.design_doc_parent`). When empty/absent,
  the note defaults to the user's **private personal channel**, resolved at runtime — never
  a hardcoded id.
- Any `document_to` value other than `slite` (or empty) is unrecognized ⇒ warn and skip.

## Where it hooks in

QA-plan completion is **interactive-only**: `execute-item` explicitly refuses `qa-test-plan`,
so completion happens solely in the Phase 3 (Archive) flow of `commands/review-queue.md`.
The new documentation step is the single hook point — there is no headless/remote path to
update.

The step runs **after** the existing Phase 3 work:
1. the local `~/.claude/engineer-agent/qa-plans/{branch}-{timestamp}/` archive is written, and
2. the queue item frontmatter is set to `status: completed` and moved to `queue/completed/`.

Documentation is the last action, layered on top of an already-complete plan.

## Behavior

After Phase 3 archive + completion:

1. Read `projects.<project>.qa.document_to`.
   - Empty/absent ⇒ skip silently (feature off).
   - `slite` ⇒ continue.
   - Any other value ⇒ report `unrecognized qa.document_to value '{value}'; skipping` and stop.
2. Resolve the Slite parent:
   - `qa.document_parent` set ⇒ use it.
   - empty/absent ⇒ call `mcp__slite__list-channels` and select the user's **personal**
     channel (the channel whose id is prefixed `user-`). Use that id as the parent.
3. Call `mcp__slite__create-note`:
   - **title:** `QA Plan: {ticket-key} — {title} ({branch})`
   - **parent:** the resolved parent id
   - **content:** the full record (see below)
4. Report the created note URL.

## Documented content (full record)

A single note containing, in order:

- A short header (ticket key + URL, PR URL, branch, base, base URL, completion timestamp).
- The full **test plan**: manual checklist, REPL/console tests, and coverage summary —
  i.e. the `## Draft Response` body that is already archived as `test-plan.md`.
- The generated **`qa-test.sh` script inlined** in a fenced ```bash code block.
- The **execution results** (the `results.md` content: stdout, pass/fail counts, manual
  checklist completion status, notes on any failed items).

These are exactly the three artifacts written to the local archive, composed into one note.

## Error handling

Documentation is **best-effort and non-blocking**. It runs only after the plan is genuinely
complete (tests run, checklist done, locally archived, moved to `completed/`). If Slite
note creation (or channel resolution) fails, report the error to the user but **do not
un-complete or block** the plan — the local archive remains the source of truth. A failed
publish is a reported warning, never a rollback.

## Out of scope

- No new destinations beyond `slite` (the value is extensible by design, but only `slite`
  is implemented now).
- No headless/remote documentation path (QA completion is interactive-only).
- No change to how QA plans are generated, run, or archived locally.

## Docs to update

Per the repo's Documentation Maintenance rule:
- `config/engineer.example.yaml` — add `document_to` / `document_parent` to the `qa` block.
- `CLAUDE.md` — note the new `qa` keys; update the Notifications parenthetical describing
  `generate-qa` if needed.
- `README.md` — document the feature and config keys.
