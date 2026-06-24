# QA Plan Documentation to Slite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optionally publish a completed QA test plan (full plan + inlined scripts + execution results) to Slite, controlled by a new per-project `qa.document_to` config.

**Architecture:** A new documentation step at the end of Phase 3 (Archive) in `commands/review-queue.md` — the only place QA plans complete (it is interactive-only; `execute-item` refuses `qa-test-plan`). It reads `projects.<project>.qa.document_to`; when `"slite"`, it composes the three local archive artifacts into one note via `mcp__slite__create-note`, parented at `qa.document_parent` or (when empty) the user's personal Slite channel. Best-effort: a publish failure never un-completes the plan.

**Tech Stack:** Markdown skill/command definitions, YAML config, Slite MCP tools (`mcp__slite__list-channels`, `mcp__slite__create-note`).

## Global Constraints

- This plugin is authored in Markdown + YAML; there is no automated test harness. Verification is by inspection and `grep`.
- Only `slite` is a supported `document_to` value today; empty/absent disables the feature (must preserve current behavior exactly).
- Documentation is best-effort and non-blocking — it runs only after the plan is fully completed and locally archived, and a failure is reported but never rolls back completion.
- `CLAUDE.md` and `README.md` must stay in sync with each other and actual behavior (repo Documentation Maintenance rule).
- Generated commits must not attribute Claude.

---

### Task 1: Add config keys to the example and README config block

**Files:**
- Modify: `config/engineer.example.yaml` (the `qa:` block under `projects.my-api`)
- Modify: `README.md:108-110` (the `qa:` block in the config example)

**Interfaces:**
- Produces: the config keys `projects.<slug>.qa.document_to` (string: `"slite"` | empty) and `projects.<slug>.qa.document_parent` (string: Slite channel/note id | empty) that Task 2 reads.

- [ ] **Step 1: Edit `config/engineer.example.yaml`**

Replace the existing `qa` block:

```yaml
    qa:
      base_url: "http://localhost:3000"  # base URL for curl commands in QA test scripts
      console_command: ""                # e.g. "rails console", "python manage.py shell", "node" (optional)
```

with:

```yaml
    qa:
      base_url: "http://localhost:3000"  # base URL for curl commands in QA test scripts
      console_command: ""                # e.g. "rails console", "python manage.py shell", "node" (optional)
      document_to: ""                    # where to document completed QA plans: "slite" | "" (empty/absent disables)
      document_parent: ""                # Slite channel/note id for the QA doc; empty → user's private (personal) channel
```

- [ ] **Step 2: Edit `README.md` config block (lines ~108-110)**

Apply the identical two-line addition to the `qa:` block in `README.md` so it matches the example file.

- [ ] **Step 3: Verify both blocks match**

Run: `grep -n "document_to\|document_parent" config/engineer.example.yaml README.md`
Expected: two hits in each file (one `document_to`, one `document_parent` per file).

- [ ] **Step 4: Commit**

```bash
git add config/engineer.example.yaml README.md
git commit -m "feat: add qa.document_to and qa.document_parent config keys"
```

---

### Task 2: Add the documentation step to Phase 3 of review-queue

**Files:**
- Modify: `commands/review-queue.md` — the `**Phase 3 — Archive:**` block (ends with the `Print: "QA complete..."` line) and the `allowed-tools` frontmatter list.

**Interfaces:**
- Consumes: `projects.<project>.qa.document_to` and `projects.<project>.qa.document_parent` from Task 1; the Phase 3 archive artifacts (`qa-test.sh`, `test-plan.md`, `results.md`) and the item's frontmatter (`ticket_key`, `title`, `branch`, `base`, `source_url`, `pr_url`).
- Produces: a Slite note created via `mcp__slite__create-note`; no new interface other types depend on.

- [ ] **Step 1: Add Slite tools to `allowed-tools` (if not already present)**

`mcp__slite__create-note` is already in the frontmatter `allowed-tools`. Add `mcp__slite__list-channels` to that list (needed to resolve the personal channel). The line becomes:

```yaml
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Agent", "AskUserQuestion", "mcp__slite__append-blocks", "mcp__slite__create-note", "mcp__slite__list-channels"]
```

- [ ] **Step 2: Append the documentation step to Phase 3**

In `commands/review-queue.md`, the Phase 3 block currently ends with:

```
  5. Print: "QA complete. Plan archived to `~/.claude/engineer-agent/qa-plans/{branch}-{timestamp}/`"
```

Immediately after that line (still inside Phase 3, before the `After the three QA phases complete...` paragraph), insert:

````
  **Phase 3b — Document the completed plan (optional):**

  This runs only after the plan is fully completed and locally archived above. It is
  best-effort: a failure here is reported but never un-completes the plan.

  1. Read `projects.<project>.qa.document_to` from `~/.claude/engineer-agent/engineer.yaml`.
     - Empty or absent → skip silently (feature disabled).
     - `slite` → continue.
     - Any other value → print `unrecognized qa.document_to value '{value}'; skipping QA documentation` and skip.
  2. Resolve the Slite parent id:
     - If `projects.<project>.qa.document_parent` is set, use it.
     - If empty/absent, call `mcp__slite__list-channels` and select the user's personal
       channel — the channel whose id is prefixed `user-`. Use that id as the parent.
       If no personal channel can be resolved, print `could not resolve a private Slite
       channel; skipping QA documentation` and skip.
  3. Compose the note content (a complete record), in order:
     - A header: ticket key + `source_url`, PR URL (`pr_url` or "None"), `branch`, `base`,
       base URL, and the completion timestamp.
     - The full test plan — the `test-plan.md` content saved in Phase 3 (manual checklist,
       REPL/console tests, coverage summary).
     - The generated `qa-test.sh` script inlined in a fenced ```bash code block.
     - The execution results — the `results.md` content saved in Phase 3 (stdout, pass/fail
       counts, manual checklist status, notes on failed items).
  4. Call `mcp__slite__create-note` with:
     - title: `QA Plan: {ticket-key} — {title} ({branch})`
     - parent: the resolved parent id from step 2
     - content: the composed record from step 3
  5. On success, print: `QA plan documented to Slite: {note_url}`.
     On any failure (channel resolution or note creation), print a warning with the error
     and continue — the plan remains completed and locally archived.
````

- [ ] **Step 3: Verify the insertion**

Run: `grep -n "Phase 3b\|document_to\|list-channels\|QA plan documented" commands/review-queue.md`
Expected: hits showing the new Phase 3b block, the `document_to` read, the channel resolution, and the success message.

- [ ] **Step 4: Commit**

```bash
git add commands/review-queue.md
git commit -m "feat: document completed QA plans to Slite in review-queue Phase 3"
```

---

### Task 3: Update CLAUDE.md and README feature docs

**Files:**
- Modify: `CLAUDE.md` — the project-entry subsection list (mentions `qa`) and the Notifications parenthetical describing `generate-qa`.
- Modify: `README.md` — the `/engineer-agent qa` command description (around line 328) and the features bullet (line 15).

**Interfaces:**
- Consumes: the config keys and behavior from Tasks 1-2. Produces no code interface.

- [ ] **Step 1: Update `CLAUDE.md` qa description**

In the `## Config Loading Pattern` section, the sentence listing project subsections reads:
`Each project entry has \`path\`, \`tracker\`, \`github\`, \`slack\`, \`jira\`, \`slite\`, and \`qa\` subsections.`
Leave that sentence as is, and add a new sentence after the Jira routing subsections (at a sensible spot near the end of the Config section) documenting the `qa` keys:

```
The `qa` subsection drives QA test plans: `base_url` and `console_command` (used during generation), plus optional documentation keys `document_to` (`"slite"` | empty — empty/absent disables) and `document_parent` (Slite channel/note id; empty ⇒ the user's private personal channel). When `document_to: slite`, a completed QA plan (review-queue Phase 3) is published to Slite as one note containing the full plan, the inlined `qa-test.sh` script, and the execution results — best-effort, never blocking completion.
```

- [ ] **Step 2: Update the CLAUDE.md Notifications parenthetical**

In `## Notifications & Remote Approval`, the parenthetical about `qa-test-plan` being interactive-only is accurate and needs no behavioral change. Confirm it still reads correctly alongside the new step; no edit required unless it contradicts. (Verification only — make no change if consistent.)

- [ ] **Step 3: Update `README.md` qa command description**

At the end of the `/engineer-agent qa` description paragraph (line ~328), after "Approve via `/engineer-agent review-queue qa`.", append:

```
On completion, if `qa.document_to: slite` is configured, the full plan — manual checklist, the inlined `qa-test.sh` script, and the execution results — is published to Slite as a single note (under `qa.document_parent`, or your private personal channel when unset). Leave `document_to` empty to disable.
```

- [ ] **Step 4: Verify docs mention the feature**

Run: `grep -n "document_to" CLAUDE.md README.md`
Expected: at least one hit in each file describing the feature.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document QA plan Slite documentation feature"
```

---

## Self-Review

**Spec coverage:**
- Config key `document_to` (value = destination, "slite"|empty) → Task 1. ✓
- `document_parent` with personal-channel default → Task 1 (config) + Task 2 step 2 (resolution). ✓
- Hook at Phase 3 after archive/completion → Task 2. ✓
- Full record (plan + inlined scripts + results) → Task 2 step 3. ✓
- Best-effort/non-blocking → Task 2 step 2/5. ✓
- Unrecognized value warn-and-skip → Task 2 step 1. ✓
- Docs (example, CLAUDE.md, README) → Tasks 1 & 3. ✓

**Placeholder scan:** No TBD/TODO; every edit shows exact content. ✓

**Type consistency:** Config keys `document_to` / `document_parent` and the resolved-parent flow are named identically across Tasks 1-3. ✓
