# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

engineer-agent — A Claude Code plugin that automates senior software engineer tasks with an approval-gated workflow. The agent drafts PR reviews, Slack answers, ticket implementations, doc reviews, and standup updates. The human reviews and approves via `/engineer-agent review-queue` before anything is posted externally — or, with ntfy configured, approves remotely from a phone (see "Notifications & Remote Approval").

A few commands sit outside the approval queue because they produce read-only planning artifacts rather than external posts. `/engineer-agent uat-plan <refs...>` is one: it turns a list of GitHub issues / Jira tickets (expanding any Jira parent into its descendants) into a User Acceptance Testing checklist — a markdown table of user-facing tests with expected results, grouped by feature area — then prints it and saves a copy under `~/.local/share/engineer-agent/uat-plans/`. It works from ticket text only (no repo or queue involvement).

## Plugin Structure

This repo IS the plugin.

- **Development**: `claude --plugin-dir /path/to/engineer-agent`
- **Permanent install**:
  1. `/plugin marketplace add tomharris/engineer-agent`
  2. `/plugin install engineer-agent`

```
.claude-plugin/plugin.json    — Plugin manifest
commands/                      — Slash commands (/engineer-agent <command>)
skills/                        — Auto-invoked skills by task type
references/                    — Shared procedural docs skills Read at runtime (routing-ladder.md,
                                 ticket-kind.md, queue-reconciliation.md). These are the SPEC;
                                 scripts/lib-routing.sh and scripts/lib-ticket-kind.sh are the
                                 executable implementation of their deterministic tiers.
hooks/hooks.json               — Claude Code hook registrations (turn-completion pushes)
scripts/                       — Cron polling, ntfy notify/listener, setup scripts, credential
                                 storage, and the deterministic collector stack (see
                                 "Deterministic polling")
tests/                         — Shell test suites; `bash tests/run-all.sh` runs every one
config/engineer.example.yaml   — Config template
```

`references/` holds logic that several skills must apply *identically* — today `routing-ladder.md`
(which project), `ticket-kind.md` (what the ticket delivers), and `queue-reconciliation.md` (whether
an item enters the queue). It is plain markdown read
with `Read`, deliberately not a skill or subagent: `scripts/cron-poll.sh` allowlists `Read` but not
`Skill`/`Agent`, so anything shaped that way is unreachable from the cron — the one path with no
human fallback.

> **Reference these files via `${CLAUDE_PLUGIN_ROOT}`, never a bare relative path.** Cron runs from
> `$HOME`, so `references/routing-ladder.md` resolves to `~/references/…` and the `Read` fails —
> interactively it works fine (cwd is usually the project), so this breaks *only* the unattended
> path, silently. Same convention `skills/audit-code/SKILL.md` uses for `scripts/notify.sh`: prefer
> `${CLAUDE_PLUGIN_ROOT}`, fall back to a path relative to the skill's own directory.

Runtime data lives at the user level in `~/.local/share/engineer-agent/` (override with the
`EA_AGENT_DIR` env var; honors `XDG_DATA_HOME`). `scripts/lib-paths.sh` is the single source
of truth for this location — source it rather than hardcoding the path.

> **Do not move runtime data back under `~/.claude/`.** Claude Code guards everything inside a
> `.claude/` directory as sensitive and refuses the Edit/Write tools there — an explicit
> `--allowedTools "Edit(...)"` rule does **not** override it. The guard is invisible
> interactively (a human just approves the prompt), but silently fatal headlessly: it left both
> `cron-poll.sh` and `approval-listener.sh` unable to record state or move queue files, so the
> cron polled every 15 minutes for a month and never queued a single item. Installs predating
> the move are migrated with `scripts/migrate-storage.sh`.

```
~/.local/share/engineer-agent/
├── engineer.yaml              — User config (one file for all projects)
├── queue/
│   ├── incoming/              — Newly detected items
│   ├── drafts/                — Items with drafted responses
│   ├── completed/             — Approved and posted
│   └── rejected/              — Rejected with reason
├── uat-plans/                 — Saved UAT checklists from /engineer-agent uat-plan (not part of the queue)
├── investigations/            — Archived findings docs from ticket-investigation items (not part of the queue)
└── state/
    ├── last-poll.yaml         — Dedup timestamps and seen IDs (per project, per Jira project key, per GitHub repo)
    ├── last-poll-receipt.yaml — Liveness receipt from the last cron poll (run_id, status, item count, skipped, errors)
    ├── ntfy-seen.yaml         — Processed ntfy command message IDs (remote-approval dedup)
    ├── turn-notify/           — One marker per session armed for turn-completion pushes (<session_id>)
    └── turn-notify.log        — Turn-completion hook diagnostics (only when EA_TURN_NOTIFY_DEBUG=1)
```

## Config Loading Pattern

Every skill and command that needs config should start by reading `~/.local/share/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

The config has two top-level sections:
- `agent` — global settings (branch_prefix, max_pr_files, `max_issue_age_days`, channels, cron interval, `autonomy`, `notify`)
- `projects` — a map of project slugs to per-project integration config

`agent.max_issue_age_days` (optional) caps how old an assigned GitHub issue may be to enter the
queue: `poll-github-issues` drops issues whose `updatedAt` is older than that many days. `0` or
absent ⇒ no age limit. This is the recency guard that keeps a multi-year assigned backlog in a
shared tracker from flooding the queue (and exhausting the cron run's budget) on a first poll,
without having to pre-seed `seen_issues`.

Two `agent` subsections drive autonomy (both optional):
- `agent.autonomy.auto_execute` — a list of action tiers allowed to run **without** an approval gate. Only `draft-pr` is supported (draft PRs merge nothing / request no review). Absent ⇒ empty ⇒ everything is gated.
- `agent.notify.ntfy` — push-notification + remote-approval settings (`server`, `topic`, `command_topic`, `auth_token`). Absent ⇒ no notifications; the workflow is otherwise unchanged.
- `agent.investigation` — which tickets deliver a **findings document** instead of code
  (`jira_types`, `github_labels`, `title_keywords`). Absent ⇒ shipped defaults apply, which include
  Jira type `Task`. Per-project `projects.<slug>.investigation.*` **replaces** a list rather than
  merging it, so a project can *narrow* the triggers (the operation that fixes a false positive); an
  explicitly empty list disables that tier. See "Ticket Kind" below.
- `agent.poll.scripted_sources` — a list of sources collected by a **deterministic script**
  rather than by the model (`github-issues`, `github`, `jira`, `slite`). Absent/empty ⇒ the
  prompt-driven path, unchanged. Env override `EA_POLL_SCRIPTED_SOURCES`. See "Deterministic
  polling" below.
- `agent.jira` / `agent.slite` — REST access for the **scripted** Jira/Slite collectors only
  (`site`, `email`, `api_token_env`, `api_token_file`, `api_base`; Slite takes `api_key_env`,
  `api_key_file`, `api_base`). Every other Jira/Slite surface in the plugin uses `mcp__atlassian__*`
  / `mcp__slite__*` and needs none of this. **The credential is never in `engineer.yaml`** — these
  keys name *where* the secret is and `scripts/lib-secret.sh` resolves it (env → file → macOS
  Keychain) at use time. `scripts/setup-credentials.sh` stores and checks it.
- `agent.notify.turn_completions` — push an FYI at the end of every turn of an `implement-ticket` session (interactive and headless). Absent/false ⇒ off. Read by `yaml_agent_notify()` in `lib-paths.sh`; see "Turn-completion pushes (opt-in)".

Slack access (`agent.slack`, optional) has **two selectable backends**, chosen by
`agent.slack.method` (`spy` | `mcp-proxy`, default `spy`). Both present the **same
subcommand/JSON interface** (`read`/`thread`/`send`/`auth`, `--json`, `-w`), so the one thing
every call site does is resolve the **effective Slack binary**, then invoke it identically:

- **`agent.slack.method: spy` (default)** — the [Spy](https://github.com/tomharris/spy) CLI,
  reusing the local Slack desktop session (browser tokens). Effective binary =
  `agent.slack.bin` ?? `spy` (on PATH).
- **`agent.slack.method: mcp-proxy`** — for **Slack Enterprise Grid**, where spy's xoxc/xoxd
  scraping is broken and unsafe (first automated call force-logs the human out; xoxd rotates
  hourly). Effective binary = `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh` — a spy-compatible
  shim (bash + curl + jq) that reads Claude Code's OAuth token from the macOS login Keychain
  (`Claude Code-credentials`, **read-only**) and speaks JSON-RPC to Anthropic's MCP proxy
  fronting the official Slack connector (`agent.slack.mcp.server` / `.server_id`). No browser
  tokens, no LLM invocation, zero model-token cost.
  - **Read-only Keychain / skip-on-expiry.** The shim NEVER refreshes or rewrites the Keychain
    entry (an OAuth refresh rotates the refresh token and would invalidate Claude Code's own
    credential). On a missing/expired token it **skips cleanly**: prints `{"skipped":true,…}`
    and exits `75`. Callers treat `75` as a *skipped* Slack source (poll leaves `last_checked_ts`
    unchanged; execute-item/digest treat a `75` on `send` as a failed post left in `drafts/`).
    Claude Code re-auths on its own and the next run succeeds.
  - **In-session keychain.** `security find-generic-password` reads the login keychain, which on
    macOS only unlocks inside the GUI (Aqua) session — the same reason the poll runs as a
    gui-session LaunchAgent (see "Notifications & Remote Approval"). No new scheduler work: the
    existing `engineer-agent-poll` LaunchAgent already runs in-session.
- `agent.slack.workspace` — default Slack workspace. Effective workspace =
  `projects.<slug>.slack.workspace` ?? `agent.slack.workspace`. Pass it as `-w <workspace>` on
  every call. Under `spy` it disambiguates multiple signed-in workspaces (spy errors without a
  default); the `mcp-proxy` shim accepts `-w` but ignores it (the connector is bound to its
  authorized workspace).

To find config for a specific project, look up `projects.<slug>`. Each project entry has `path`, `tracker`, `github`, `slack`, `jira`, `slite`, `qa`, and (optional) `exec` and `investigation` subsections. `investigation` overrides the global kind lists for this project and carries `on_complete_status` — a Jira status to move the ticket to after a successful findings comment. Empty/absent ⇒ no transition, **and the transition MCP verbs are not added to the confined run's allowlist at all**, so capability follows config. `exec.allowed_commands` is the build/test command allowlist for confined headless ticket implementation — see "Confined headless ticket implementation" under Notifications & Remote Approval. The `tracker` field (`"jira"` | `"github-issues"` | `"none"`) determines which ticket tracker a project uses. If absent, it's inferred: `jira` section present → `"jira"`, `github.issues` section present → `"github-issues"`, neither → `"none"`.

### Jira Multi-Source Config

The `jira` section supports watching multiple Jira projects per engineer-agent project via a `sources` array:

```yaml
jira:
  sources:
    - project: "ENG"
      components: ["api"]    # optional: filter by Jira component
      labels: ["backend"]    # optional: filter by Jira label
    - project: "PLAT"
  assignee: "me@example.com"
  statuses: ["To Do", "In Progress"]
```

- Each source has a required `project` key and optional `components`/`labels` filters
- A source with no filters is a catch-all for that Jira project
- `assignee` and `statuses` are shared across all sources
- **Backward compat:** `jira.project` (string) is treated as `sources: [{project: <value>}]`
- Multiple engineer-agent projects can watch the same Jira project with different component/label filters (N:M mapping)

Routing itself lives in `references/routing-ladder.md` — see below.

### Ticket Routing

**`references/routing-ladder.md` is the single source of truth for which project a ticket belongs
to.** `poll-jira`, `poll-github-issues`, and `add-ticket` all `Read` it and follow it rather than
describing routing themselves — the same single-source-of-truth invariant `execute-item` has for
approvals, and for the same reason: three prose copies of a rule drift.

The ladder fires tier by tier; each tier requires **exactly one** match, and ambiguity always falls
through to the next:

| Tier | Basis | `routing_method` |
|---|---|---|
| 0 | Only one project watches this Jira key / repo | `single-candidate` |
| 1 | `[token]` title prefix equals a slug or `github.repos` entry | `prefix` |
| 2 | Jira `components`/`labels`; GitHub `github.issues.labels` | `filters` |
| 3a | `routing.keywords` / `routing.paths` hit | `keyword` |
| 3b | Semantic match against `routing.description` | `inferred` (+ `routing_rationale`) |
| 4 | Nothing resolved to exactly one | `_unrouted`, `matched_projects` set |

Tier 0 short-circuits: a project that is the sole watcher of its key/repo pays nothing for any of
this. Tiers 3a/3b consult the optional `projects.<slug>.routing` block (`description`, `keywords`,
`paths`) and are **skipped entirely when no candidate has one**, so installs that never add hints
behave exactly as they did before the ladder existed. An `inferred` route auto-routes and gets a
draft, but the draft still passes the normal approval gate — `review-queue` displays the method and
rationale so a wrong guess is visible rather than silent. Tier 3b may also **abstain**; a tie falls
to Tier 4, never to a coin flip. `add-ticket` is interactive, so it prompts at Tier 4 instead of
writing `_unrouted` (`routing_method: manual`).

**Two traps encoded in the GitHub path, each of which broke a real behavior:**
- `gh issue list --label a --label b` is **AND, not OR**, so several watchers' label filters cannot
  be unioned into one query the way `poll-jira` unions statuses into `status IN (...)`. Fetch the
  repo unfiltered and apply `github.issues.labels` as a *routing* predicate at Tier 2.
- Collection must be deduplicated **per repo**, not per project. When it ran per project, the global
  `source_id` dedup handed a shared repo's issue to whichever project the loop reached first — an
  arbitrary misroute that looked like a confident decision, with no `_unrouted` escape.

**Injection containment (Tier 3b reads untrusted ticket text):** the inference tier may only ever
output a slug from the Tier 0 candidate set, which is computed from config alone. So an injected
payload can at worst shuffle a ticket between projects that already legitimately watch that key or
repo — it cannot invent a target or reach an unrelated project. Ticket text is matched as *data*
(topic only); imperatives inside it ("assign this to X") are ignored. Routing decides only which
project's config drafts the item; every posting verb stays in `execute-item`, behind the gate.

### Ticket Kind

**`references/ticket-kind.md` is the single source of truth for what a ticket delivers** — a code
change (branch → draft PR → QA) or a findings document (a `## Findings` comment on the ticket + a
local archive). `poll-jira`, `poll-github-issues`, `add-ticket`, and `review-queue`'s unrouted
assignment flow all `Read` it, for the same reason they do the routing ladder.

Two independent ladders, and **routing runs first**: the kind lists are per-project overridable, so
there is no correct kind to compute until a slug exists. Routing answers *which project*; this
answers *what it delivers*. Neither reads the other's output.

| Tier | Basis | `ticket_kind_method` |
|---|---|---|
| 0 | `--investigate` / `--implement` on `add-ticket` | `manual` |
| 1 | Jira issue type name ∈ `jira_types` — **terminal for Jira** | `jira-issuetype` |
| 2 | GitHub label ∈ `github_labels` (after a `type:`/`kind/` prefix strip) | `github-label` |
| 3 | GitHub title keyword, delimited prefix or leading imperative | `title-keyword` (+ `ticket_kind_rationale`) |
| 4 | Nothing matched ⇒ code work, the status quo | `default` |

**Tier 1 being terminal for Jira is what removes the false-positive problem.** A Jira issue always
has a type, so Tier 1 always answers and title matching is unreachable for Jira — a Story titled
`Add spike protection to the rate limiter` is code work by structure, not by luck. For GitHub, Tier
3 requires a *form* (`Spike:`, `[Decision]`, or a leading imperative verb like `Investigate`), never
bare presence of a keyword, because it is impossible to write about rate limiting or decision
engines without tripping a presence test.

Unlike the routing ladder, the last tier is **not** a human: "nothing matched" has a correct,
non-surprising answer (code work — the behavior before this ladder existed), and both outcomes are
gated anyway. The human override is `add-ticket --investigate` / `--implement`.

> **`Task` ships as a trigger and is the one aggressive default.** In many Jira projects `Task` is
> the catch-all for ordinary code work, so on such an instance a routine ticket is drafted as an
> investigation. Bounded by the gate (the human reads an "Investigation Plan" that says "no branch,
> no PR") and by one line of config (`jira_types: ["Spike", "Decision"]`, globally or per project).

**Injection containment:** the ladder's entire output alphabet is two config-derived shapes, both
behind the approval gate. Ticket text is only ever the *left* side of a comparison — it never
contributes a keyword — so the trigger vocabulary is closed under config. Classification happens
during polling, which has a read-only allowlist, so it cannot reach a posting verb; the comment
target is `ticket_key` from the tracker API, never a key parsed out of ticket text; and the
investigation execution path is *narrower* than the implementation path, so a flip toward
investigation reduces capability.

**`{ticket, ticket-investigation}` is one `(type, source_id)` family.** A kind can change between
polls (an issue type edited, a title retitled), and since the dedup invariant is keyed on `type`, the
naive rule mints a rival item for work already queued or finished. So the poller lookup is
family-wide **including terminal items**, while `queue-dedup-check.sh` collapses the family only
among **non-terminal** ones — a completed investigation followed by a fresh implementation draft is
the legitimate spike → `add-ticket --implement` handoff, and flagging it would leave the check
permanently red on the most likely real workflow. Both asymmetries are deliberate; see
`references/queue-reconciliation.md`.

### QA Documentation Config

The `qa` subsection drives QA test plans: `base_url` and `console_command` (used during generation), plus optional documentation keys `document_to` (`"slite"` | empty — empty/absent disables) and `document_parent` (Slite channel/note id; empty ⇒ the user's private personal channel). When `document_to: slite`, a completed QA plan (review-queue Phase 3) is published to Slite as one note containing the full plan, the inlined `qa-test.sh` script, and the execution results — best-effort, never blocking completion.

## Queue File Format

Items enter the queue either via polling (`/engineer-agent poll` or the cron) or manually (`/engineer-agent add-ticket <ref>`). Both paths produce identically-shaped queue files.

Files move through: `~/.local/share/engineer-agent/queue/incoming/` → `queue/drafts/` → `queue/completed/` or `queue/rejected/`

**Invariant: at most one item per `(type, source_id)`.** `references/queue-reconciliation.md` is the
rule every poller follows to uphold it — skip / update-in-place / create, one branch each — and
`scripts/queue-dedup-check.sh` is the executable check, run automatically at the end of each
`cron-poll.sh`. A duplicate is otherwise invisible: queue filenames carry a `{YYYYMMDD-HHmmss}`
minted at write time, so a second copy of a ticket never collides with the first — it just sits
alongside it and the human reviews (or implements) the same work twice.

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

## Notifications & Remote Approval

ntfy turns the approval gate into a remote, async one without a custom server. Both directions are ntfy topics:

- **Outbound** (`topic`): after a poll, `cron-poll.sh` calls `scripts/notify.sh` to push each new draft with **Approve / Reject / Open** action buttons.
- **Inbound** (`command_topic`): the Approve/Reject buttons are ntfy `http` actions that POST `approve|<item-id>` / `reject|<item-id>` back to the command topic. `scripts/approval-listener.sh` (a long-running service installed by `scripts/install-listener.sh`) streams that topic and runs `/engineer-agent execute <item-id> <decision>` headlessly (an approved `ticket` takes the separate confined-implementation path instead — see "Confined headless ticket implementation"). After validating a command the listener also pushes two best-effort acknowledgements back to the outbound `topic` via `notify.sh --fyi`: a **receipt** ack (low priority, "📨 Received…") the moment the tap lands, and an **outcome** ack after the run — "✅ Done…" (normal) when the item leaves `queue/drafts/`, or "⚠️ Failed…" (urgent) when it did not. Invalid or already-seen commands are not acknowledged (avoids noise and confirming a live listener to a prober). The ack adds no posting capability — it is an outbound notification only, so the "polling reads; only execute-item writes" invariant is untouched.

### Turn-completion pushes (opt-in)

`implement-ticket` is the longest thing this plugin runs, and until you approve it nothing tells
you how it is going: the headless path sends one ✅/⚠️ after the *whole* run, and the interactive
path (`/engineer-agent:implement-ticket`) sent nothing at all. Setting
`agent.notify.turn_completions: true` pushes an FYI at the **end of every turn** — done, blocked,
pausing to ask you something, or dead on an API error.

It is a **Claude Code hook**, not a `notify.sh` line in the skill, and that distinction is the
whole point. This repo has learned twice over that a model's own report is not a completion signal
(hence the run-id receipt in `cron-poll.sh` and the `drafts/` existence check in the listener). A
prompt instruction fires only when the model chooses to — so it would go quiet on exactly the turns
worth hearing about: budget abort, API error, an early bail. `hooks/hooks.json` registers
`scripts/turn-notify-hook.sh` on five events and the harness fires them regardless.

**Arm → fire → disarm**, because a plugin-wide `Stop` hook otherwise runs on every turn of every
project of everyone who has the plugin enabled:

| | Armed by | Disarmed by |
|---|---|---|
| Interactive | `UserPromptSubmit` matching `^/engineer-agent[: ]implement-ticket` (primary — the literal text typed), or `PreToolUse:Skill` where `tool_input.skill` is `engineer-agent:implement-ticket` (backstop). Writes `state/turn-notify/<session_id>` | `SessionEnd`; plus a 24h prune on the arm path for sessions that crashed |
| Headless | `EA_TURN_NOTIFY=1`, set **inline** on the one `claude -p` in `run_ticket_implementation` — no file, no session correlation, nothing orphaned | process exit |

Two independent interactive arms exist because the namespaced `engineer-agent:implement-ticket`
form is only *guaranteed* while a same-named user-level skill forces disambiguation. Delete that
skill and the plugin's could be invoked bare, silently killing the `PreToolUse` arm — the prompt
matcher still catches it. Deliberately **out of scope:** a bare `implement-ticket`, which is
somebody else's skill.

**Default OFF, and the gate is checked at *arm* time only.** `hooks/hooks.json` registers
unconditionally on the next `/plugin update`, so the behavior change has to be consented to even
though the registration isn't — the same deny-by-default posture as `agent.autonomy.auto_execute`
and `exec.allowed_commands`. Checking the config only when arming is also what keeps the fire path
free: an unarmed session costs one `cat`, one `test -d` and one glob, with no config read, no awk,
no jq, no network.

**Three invariants in `turn-notify-hook.sh`, each guarding a different foot-gun:**
- **Always `exit 0`, never write stdout.** Exit 2 on `Stop` *blocks the turn from ending* and
  forces the model to continue; on `PreToolUse` it denies the tool; on `UserPromptSubmit` it blocks
  the prompt — and `UserPromptSubmit` stdout on exit 0 is **injected into the model's context**. So
  no `set -e`, no stray `echo`; diagnostics go to `state/turn-notify.log` under
  `EA_TURN_NOTIFY_DEBUG=1`.
- **jq is a soft dependency.** `cron-poll.sh` makes "deliberately NOT jq" policy for anything
  outside the separately-installed listener, and a plugin-wide hook is even more exposed. Every
  field used to *decide whether to push* is escape-free by construction (uuid / enum / skill slug /
  anchored raw-JSON prefix) and is read with `sed`. jq is used for exactly one thing — decoding
  `last_assistant_message` for the excerpt — so no jq means a label-only push, never a broken hook.
- **Nothing tappable reaches the phone.** No `--source-url` is passed, so there are no action
  buttons and no Open link, and `sanitize_text` replaces every `scheme://` URL, `www.` host and
  `mailto:` with `(link)` before anything hits the wire. The excerpt is model-authored text
  ultimately derived from untrusted ticket/PR/Slack bodies, and ntfy's mobile clients autolink URLs
  in the message body — so without this an injected line could render a tappable link inside a
  notification arriving on the very topic you have trained yourself to trust for Approve/Reject,
  aimed at you while you are away from your desk. *Residual, accepted:* a bare `evil.tld` with no
  scheme can still be autolinked by some clients; neutralizing that would also destroy `notify.sh`
  and `SKILL.md`, and the excerpt is the model's own summary rather than a quote.

Capped at `EA_TURN_NOTIFY_MAX` (40) pushes per session, with one "🔕 muted" push at the boundary so
the silence is explained. `EA_TURN_NOTIFY_ENABLED` overrides the config key either way — set it to
`0` in the listener's environment to disable just the headless leg. Hook registrations are read at
session start, so an existing install needs `/plugin update engineer-agent` (or a new session);
the listener's own mtime self-reexec covers `approval-listener.sh` but not this.

**Writing a headless `claude -p` run** (both scripts do this; the rules below were each learned
from a run that failed silently):
- **Pin `--permission-mode`.** Otherwise the run inherits `permissions.defaultMode`; in `plan` mode
  `claude -p` prints a plan and exits 0 without doing anything.
- **`--permission-mode` is not enough on its own — pass `--allowedTools`.** Only a built-in set of
  Bash commands (`ls`, `cat`, `grep`, read-only `git`, …) is auto-approved. `gh` and `spy` are not
  in it, so they prompt in every mode, and a prompt in `-p` is a denial.
- **Allowlist a CLI's read-only *preflight* verbs, not just its data verbs.** The model routinely
  probes a tool's health before using it (`gh auth status`, `gh --version`, `slack-mcp.sh auth`);
  when the probe is denied it concludes the **whole CLI is unavailable** and abandons every source
  *without ever trying the verbs that are allowed*. This has now broken two integrations the same
  way: the Slack `auth` preflight (fixed in `162a4bb`, which cascaded to a doomed direct-connector
  fallback) and `gh` — where five consecutive polls on 2026-07-24 reported `status: error` with all
  8 GitHub sources in `errors:` while `gh pr list` was allowlisted and working the entire time; the
  transcripts show only `gh auth status`/`gh --version` were ever issued. It presents as
  *intermittent*, not deterministic, because a run that happens to skip the probe (or shrug it off)
  still succeeds — the 2026-07-23 run hit the identical denial and recovered. Preflights are
  read-only, so listing them costs nothing against the read-only invariant.
- **Never let an unattended run write memory.** A receipt is a fact about **one** run; a memory is a
  belief applied to **all future** runs. The 2026-07-24 `gh` outage went from one flake to five
  identical failures because the second failing poll wrote a project memory asserting `gh` was
  permanently blocked — including "Do not treat this as transient and just rerun" — which every
  later poll then loaded, re-read, and confirmed **instead of retesting**. That converts an
  independent transient into a correlated, self-citing, permanent outage, and it defeats the
  receipt-based liveness design (which assumes failures are independent). Every headless prompt
  in `cron-poll.sh` and `approval-listener.sh` (the shared `NO_MEMORY_RULE`, applied to the
  generic execute, ticket implementation, and QA runs alike) therefore forbids creating/updating
  memory files and forbids treating an existing memory as evidence about the current run.
  **Memory is keyed by CWD, not by which script launched the run** — the poll and the listener's
  `run_generic_execute` both run from `$HOME`, so they share
  `~/.claude/projects/-home-tom/memory/` and can cross-contaminate; the ticket/QA runs `cd` into
  a per-run worktree and so get a throwaway namespace, but only as a side effect of the path
  sandbox, which is why the rule is applied uniformly rather than relying on that accident. If an
  unattended run ever misdiagnoses itself again, check that memory directory before believing the
  diagnosis.
- **Don't put `--allowedTools` last before the prompt.** It takes a variable number of values and
  will swallow the prompt as another rule (`Input must be provided … when using --print`). Keep a
  single-value flag in between.
- **Hook commands are NOT subject to `--allowedTools`.** A plugin's `hooks/hooks.json` runs
  whatever it registered regardless of the allowlist, because hooks are operator-configured rather
  than model-requested. So an `allowed_tools` array is not an exhaustive statement of what a
  headless run can cause to happen — `hooks/hooks.json` is the other half. Today that grants
  nothing new (`turn-notify-hook.sh` only shells out to `notify.sh`, which the confined ticket
  allowlist already carries), but keep hooks outbound-only and fail-open so it stays that way.
- **Use `Edit(path)`, never `Write(path)`.** The CLI rejects `Write(path)` rules; one `Edit` rule
  covers every file-editing tool. Path rules need `//abs` to anchor at the filesystem root — a
  single leading `/` anchors to the cwd.
- **Never trust the exit code.** `claude -p` exits 0 whenever the CLI ran, regardless of whether the
  work happened. Determine success from a real side effect: the listener checks that the item left
  `queue/drafts/`; the cron mints a `RUN_ID` only it knows and checks that the model echoed that
  exact id back into `state/last-poll-receipt.yaml` as its final step, pushing an ntfy alert if the
  receipt is missing or stale (and a lower-priority one if the receipt's `status` isn't `ok`).
- **Prove liveness with a token the script controls, not with mutation of a file the model authors
  for another purpose.** The cron used to fingerprint `last-poll.yaml` and warn if the hash was
  unchanged — but that file is a *semantic dedup cutoff*, not a health signal, and overloading it
  as one was wrong twice over: `poll-slack`'s `last_checked_ts` legitimately can't advance on a
  zero-message poll (so a Slack-only config false-warned on every quiet poll), and the timestamps
  are model-authored and were observed fabricated (a real run wrote a `last_checked` 40 minutes in
  the future). Content-change is only a freshness signal if the content is reliably distinct per
  run; a run-id echoed back is. Keep liveness and dedup state in separate files answering separate
  questions.
- **Redirect `</dev/null`** so the run doesn't block reading its parent's stdin.
- **Export `USER`.** cron/launchd/systemd hand the run a minimal environment — macOS cron sets
  `LOGNAME` but *not* `USER` — and the CLI keys its credential lookup on `$USER`, so a missing
  `USER` reads as `Not logged in · Please run /login` even when valid credentials are present and
  work interactively. This is not the same as the older `remote-settings.json` failure and its
  shim; a CLI update made credential resolution depend on `$USER`, which silently broke every
  cron poll. `lib-paths.sh` (sourced by both scripts, directly and via `lib-ntfy.sh`) derives it
  with `export USER="${USER:-$(id -un)}"`, so the fix needs no crontab/service reinstall.
- **The login keychain is readable only from *inside* the GUI session — so schedule headless runs
  in-session (launchd LaunchAgent), not out-of-session (crontab).** On macOS the primary Anthropic
  credential lives in the **login keychain**, which only unlocks within the user's GUI (Aqua) login
  session. A **crontab** job runs *outside* that session and cannot read it, so every cron poll dies
  with "Not logged in" even when `$USER` is correct and credentials work interactively. But a
  **launchd LaunchAgent bootstrapped into `gui/$UID`** runs *in* the session and reads the keychain
  fine — **verified 2026-07-17**: a throwaway gui-session LaunchAgent authenticated and exited 0
  running the exact binary a sibling crontab run failed on, and the `approval-listener` has always
  used this path. So on macOS `install-cron.sh` installs the poll as a **LaunchAgent**
  (`engineer-agent-poll`, mirroring `install-listener.sh`), not a crontab entry; Linux keeps crontab
  (no per-user GUI-keychain split there). An earlier note lumped "cron/launchd" together as both
  failing the keychain — that was wrong; only *out-of-session* schedulers fail. The tradeoff of the
  in-session agent: it only polls while the user is logged into the GUI. This is why we **do NOT
  re-add the reverted `auth.env`/`CLAUDE_CODE_OAUTH_TOKEN` loader** — the launchd path keeps no
  long-lived secret on disk.
- **`forceLoginOrgUUID` blocks *environment* credentials only — it does NOT block a keychain
  credential, so it is not a headless dead end.** When an org deploys a root-owned
  `/Library/Application Support/ClaudeCode/managed-settings.json` with `forceLoginMethod: claudeai`
  + `forceLoginOrgUUID: <uuid>`, Claude Code restricts login to that org, **exits at startup if the
  active credential isn't a verified member**, and per the official docs *blocks all environment
  credentials* (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `apiKeyHelper`,
  `CLAUDE_CODE_OAUTH_TOKEN`) "since organization membership can't be verified for an environment
  credential." It surfaces as `Unable to verify organization for the current authentication token.
  This machine requires organization <uuid> but the token could not be validated` and `claude`
  exits 1 — a **freshly-minted, org-valid `claude setup-token` still fails identically** (verified
  2026-07-16), because it is an environment credential regardless of which org minted it.
  **But the login-keychain credential is not an environment credential.** When it belongs to a
  verified member of the named org it passes under the policy, and a `gui/$UID` LaunchAgent can read
  it — so the in-session scheduler above is sufficient *with the policy in force*. **Verified
  2026-08-25** on a machine where the policy was present and Jamf-re-enforced: pristine `claude -p`
  under `env -i` (HOME/USER/PATH only) authenticated, then a full poll ran `status: ok` /
  `errors: []` across 21 sources. This corrects an earlier claim here that the policy "blocks *all*
  headless auth … no scheduler choice helps", and a companion claim that the policy had been
  *removed* from this machine on 2026-07-17 — it returned 2026-07-24 via Jamf and is active now.
  Wall A (policy) and Wall B (out-of-session keychain) were never stacked: **clearing B was
  sufficient.** Practical consequence: **the two walls fail differently, so read the error.**
  `Unable to verify organization…` = an environment credential is in play (remove it; don't add
  one). Plain `Not logged in` = the keychain isn't reachable — an out-of-session scheduler, a
  missing `USER`, or a GUI session that isn't logged in. Only if a keychain credential is genuinely
  unavailable (no interactive login possible, e.g. a headless build box) do the fallbacks apply:
  (a) a cloud-provider inference path (Bedrock/Vertex/Foundry, via
  `CLAUDE_CODE_USE_BEDROCK`/`_VERTEX`/`_FOUNDRY`), which the docs exempt, or (b) an org/IT exemption
  or org-scoped headless credential. Do **not** re-add an `auth.env`/`CLAUDE_CODE_OAUTH_TOKEN`
  loader — that is precisely the credential class the policy rejects. If a root-owned
  `managed-settings.json` is present, do **not** delete, truncate, or shim around it (and do not
  patch the `claude` binary's `managed/settings` string to make it unreadable) — it is an
  intentional corporate security control, and MDM restores it anyway.

Both `cron-poll.sh` and `approval-listener.sh` resolve the Claude Code binary from `PATH` by default, but honor a `CLAUDE_BIN` env var override (a specific shim/wrapper/install path). Because cron, systemd, and launchd do not inherit the interactive shell environment, `install-cron.sh` and `install-listener.sh` capture `CLAUDE_BIN` when set at install time and bake it into the launchd `EnvironmentVariables` (macOS) / systemd `Environment=` (Linux listener) / crontab entry (Linux poll) so the supervised runs use the same binary. On macOS `install-cron.sh` also accepts `EA_POLL_HOURS` (comma-separated clock hours) + `EA_POLL_MINUTE` to emit a `StartCalendarInterval` schedule confined to business hours instead of the default `StartInterval` every-N-minutes; this caps how much a first poll on a large assigned backlog can spend.

> **Changing `CLAUDE_BIN` (or any `EnvironmentVariables` entry) in a LaunchAgent plist does not
> affect the running job — you must `bootout` + `bootstrap`, not `kickstart`.** launchd caches a
> job's environment block when the job is loaded, so an edited plist is inert until the job
> definition is re-read. `launchctl kickstart -k` restarts the *process* but reuses the *cached
> definition*, so it silently does not pick up the change. This burned a real migration: both
> `engineer-agent-poll` and `engineer-agent-listener` ran for hours with a live
> `CLAUDE_BIN` pointing at a wrapper whose target binary had been moved away, while the plists on
> disk had already been corrected — the poll wrote no receipt and the listener failed every
> approval with `No such file or directory` and left the item in `drafts/`. Note the
> `approval-listener.sh` mtime self-reexec **cannot** catch this class of staleness: the script file
> is unchanged, it is the job environment that is stale. So always verify with
> `launchctl print gui/$UID/<job> | grep CLAUDE_BIN` — reading the plist proves nothing about what
> is running. `install-cron.sh` / `install-listener.sh` do a full bootout+bootstrap, so a
> re-install is also a valid fix; a hand-edited plist is not.

The poll's own per-run budget is capped with `--max-budget-usd`, default **`6.00`**, overridable via
`EA_POLL_BUDGET_USD` (captured at install time and baked into launchd/crontab like `CLAUDE_BIN`). A
full 6-project × 4-source poll that reads live Slack channels and may draft a PR review / ticket
intent inline can exceed a low cap; when it does, `claude -p` aborts mid-run, writes no receipt, and
the next fire re-attempts the same work — a flat `2.00` did exactly this once mcp-proxy Slack reads
started succeeding. `cron-poll.sh` also takes a **PID lockfile** (`state/cron-poll.lock`) and exits
early if another poll is already running (a stale lock from a dead PID is reclaimed): two concurrent
polls thrash the same state/receipt files and each burns its full budget racing the other.

> **A supervised daemon runs whatever it parsed at launch — editing the script on disk
> does not reload it.** `install-listener.sh`'s `systemctl --user enable --now` is a no-op on an
> already-running unit, so before this was fixed a code deploy could leave the *old* listener
> running silently (it once ran ~28h past a commit and never emitted the newly-added acks). Two
> guards: `install-listener.sh` now `systemctl --user restart`s on every re-install (matching the
> macOS `kickstart -k` path), **and** `approval-listener.sh` re-execs itself at the top of its
> reconnect loop when its own mtime changes — the one point guaranteed to be *between* executes,
> so no in-flight approval is interrupted.

**Which copy of the plugin the service supervises (`EA_LISTENER_FROM_CACHE`).**
`install-listener.sh` defaults to supervising **its own checkout**, which is right on a
`--plugin-dir` dev box but means the listener and the interactive skills can resolve *different*
`${CLAUDE_PLUGIN_ROOT}`s — the dev repo vs. the marketplace cache — and so drift apart whenever you
commit without pushing, or push without `/plugin update`. Setting `EA_LISTENER_FROM_CACHE=1` at
install time supervises the **installed cache** copy instead, putting both on the same root.

It cannot do that by naming the cache dir in the plist/unit: that path is **version-pinned**
(`…/plugins/cache/engineer-agent/engineer-agent/<ver>`) and old versions are **retained**, so a
service naming `1.10.0` would keep running `1.10.0` forever after the next `/plugin update` —
and *silently*, because the mtime self-reexec above sees an unchanged file at an unchanged path,
which is exactly the stale-daemon failure that guard exists to prevent. So the installer generates
a **stable launcher** at `~/.local/bin/engineer-agent-listener` that resolves the highest installed
version at each launch and `exec`s it (so it leaves no wrapper process). Consequence: a new version
is picked up on the next service **restart** (`launchctl kickstart -k` / `systemctl --user restart`),
not on `/plugin update` alone and not by re-running the installer. The launcher duplicates
`resolve_installed_plugin_root()`'s few lines rather than sourcing `lib-paths.sh` — that library
lives *inside* the versioned dir being resolved; keep the two in sync.

The listener's headless execute is capped with `--max-budget-usd`, chosen **per item type** from
the draft's `type:` frontmatter: `ticket` items (which run the full `implement-ticket` coding session)
get `TICKET_BUDGET_USD` (default `8.00`); `ticket-investigation` items (a read-only research session
— pricier than a single post, cheaper than writing code) get `INVESTIGATE_BUDGET_USD` (default
`3.00`); everything else gets `DEFAULT_BUDGET_USD` (default `2.00`). Override via the
`EA_TICKET_BUDGET_USD` / `EA_INVESTIGATE_BUDGET_USD` / `EA_EXECUTE_BUDGET_USD` env vars (note none of
these are baked into the launchd plist / systemd unit, so a *supervised* listener ignores them —
only `CLAUDE_BIN` is captured at install time). A flat
`0.50` used to abort every ticket approval with "Exceeded USD budget", stranding it in `drafts/`.
Only the two exact strings `ticket` and `ticket-investigation` unlock a different cap, so untrusted
frontmatter can at worst pick among three fixed constants — never inflate spend. The comparisons are
exact (`case` globs, not prefixes), so a near-miss type like `ticket-plan` correctly gets the
default; there is a regression test pinning that. The best-effort QA generation that follows a ticket implementation
(see below) is a *separate* `claude -p` run with its own cap, `QA_BUDGET_USD` (default `2.00`,
override `EA_QA_BUDGET_USD`).

### Confined headless ticket implementation

A `ticket` is the one item type whose *execution writes code* — approving it runs the full
`implement-ticket` flow (branch → inline iterative implementation → migrations/typecheck → self-review of the diff → draft PR → best-effort QA plan), not a single
`gh` call. That cannot run under the read/post allowlist the other types use, so the listener
gives `ticket` a **separate, deliberately confined execution path** (`run_ticket_implementation`
in `approval-listener.sh`). It is the one place untrusted issue text can steer code, so the two
things that define the sandbox are decided in **plain bash, before `claude` starts** — untrusted
text can influence code *inside* the sandbox but never the *shape* of it:

1. **Path isolation.** The listener creates a throwaway `git worktree` of the target repo
   (detached at the base branch) under `~/.local/share/engineer-agent/worktrees/` and runs the
   headless session with that as cwd, so the user's real checkout is never the target. The
   worktree is torn down (`git worktree remove --force`) when the run ends, pass or fail; the
   branch and any pushed commits / draft PR persist. Because that cwd cannot reach outside
   itself, the confined run *writes* `queue/completed/<item>` but cannot delete the
   `queue/drafts/<item>` original — so the listener **reconciles the move in plain bash after
   the run** (removes the stale `drafts/` copy when the `completed/` copy exists). The
   queue-move, like worktree creation, is a privileged step kept on the listener's side of the
   sandbox boundary; without it a shipped PR false-flagged as `⚠️ Failed` because the drafts/
   copy lingered.
2. **Narrow allowlist.** Build/test commands come from `projects.<slug>.exec.allowed_commands`
   in config; the listener validates each against `^[A-Za-z0-9._/-]+$` and expands it to a
   `Bash(<cmd> *)` rule, added to `Read/Edit/Write/Glob/Grep`, `Bash(git *)`, `Bash(gh *)`,
   `Bash(mv *)`, and `notify.sh`. **Deny-by-default:** a project with no (valid) list has remote
   ticket approval *refused* — the item stays in `drafts/`, a `⚠️ Failed` push tells the user to
   set the list, and no unconfined session ever runs. It is never `Bash(*)` / `bypassPermissions`.
3. **Draft-PR review gate** (downstream, unchanged): the output is a draft PR the human reviews.

When `agent.notify.turn_completions` is on, this run is also handed `EA_TURN_NOTIFY=1` and
`EA_TURN_NOTIFY_LABEL=<item>` as an **inline `env` on that one process** — resolved in plain bash
alongside the worktree and the allowlist, for the same reason. Being inline rather than exported
is what keeps `run_qa_generation`'s separate run silent; the ticket therefore produces one 🔔 in
addition to the listener's 📨/✅, and QA still produces only its 🧪.

**QA test plan (best-effort, after the draft PR).** Once the implementation has actually shipped
(the `completed/<item>` record exists), and *only* if the project has `projects.<slug>.qa.base_url`
configured, the listener runs a **second, separate** confined `claude -p` (`run_qa_generation`) —
inside the same still-live worktree, before teardown, so `git diff <base>...HEAD` sees the branch
changes — that follows the `qa`/`generate-qa` flow to draft a `qa-test-plan` queue item for the
branch. It is a deliberately *different* allowlist from the implementation run: it **adds**
`Bash(curl *)` (Pass 3 script execution) and `mcp__atlassian__getJiraIssue` (Jira AC) and **drops**
the build-command rules — QA writes no code, so widening the code-writing sandbox with network
egress is avoided; the implementation run, symmetrically, keeps the build rules but never gets
`curl`. QA is read + queue-draft only (it posts nothing external — Slite publishing still happens
later at review-queue/execute-item), so it needs no approval gate, and its result is surfaced as an
informational FYI push (`qa-test-plan` is interactive-only for approval, so it is *never* an
actionable Approve/Reject). It is **best-effort and decoupled**: a failure or an absent qa config
is logged and skipped, and never flips the ticket's ✅/⚠️ ack — a shipped PR is never re-flagged as
failed because QA hiccuped.

**Its queue move is reconciled in bash too, for the same reason the implementation's is.** The QA
run creates its item in `incoming/` and must move it to `drafts/` — the only dir the approval gate
reads — but that delete is outside the worktree cwd and the sandbox refuses it regardless of the
`Bash(mv *)` rule. Told to `mv`, the run wrote the `drafts/` copy, left the `incoming/` original,
and reported the leftover in prose; the result was a live duplicate of one `(qa-test-plan,
source_id)` that `queue-dedup-check.sh` then flagged on every poll forever. So the prompt now says
what the implementation prompt says — write the destination, don't try to remove the original — and
`reconcile_incoming_draft_move()` finishes the move on the privileged side, guarded on the `drafts/`
counterpart existing under the identical basename.

**Honest limit — this is "medium," not airtight.** Claude Code `Bash()` rules are command-prefix
matches, *not* cwd-scoped, so `Bash(git *)` also permits `git -C /elsewhere`. The worktree bounds
the *default* target and the command *set* is curated, but that prefix-vs-path gap is the residual
risk. Mitigating it: the command set is small and build-only, the source is an issue routed to the
user's own project, and the output is draft-only. `implement-ticket` is worktree-aware (Step 2: it
creates the branch in place when already inside the repo checkout, and pushes before `gh pr
create` so the headless run never hits an interactive push prompt).

### Confined headless ticket investigation

A `ticket-investigation` is the one item type whose deliverable is **prose posted on the ticket**.
Approving it remotely runs `run_ticket_investigation` — a third confined path, sibling to
`run_ticket_implementation`, with the same worktree isolation and the same
`completed/`-then-reconcile handshake (both now share `reconcile_queue_move()` so they cannot
drift). Three deliberate divergences, each of which a reader will otherwise "fix" back:

1. **No `exec.allowed_commands` requirement.** An investigation runs no build commands, so the
   deny-by-default refusal must *not* apply — otherwise every doc-only ticket on a project without a
   build list is refused outright, which is the bug this feature exists to fix.
2. **No code-writing verbs, and no broad `Bash(git *)` / `Bash(gh *)`.** Those prefixes would
   re-grant `git push` / `gh pr create` / `gh api -X POST` to a path whose whole premise is that it
   writes no code. Read-only git verbs and two `gh issue` verbs are enumerated instead, plus the
   read-only preflights `gh auth status` / `gh --version` (a denied preflight makes the model
   conclude the whole CLI is unavailable — the failure that cost five consecutive polls) and
   `Bash(echo:*)` for the compound-command probe. `--add-dir "$AGENT_DIR"` is **required**: under
   `acceptEdits` edits are auto-accepted only under the cwd, and the cwd is the worktree while the
   run must write the archive and the `completed/` record outside it.
3. **No QA afterwards, structurally.** `run_qa_generation` is only reachable from
   `run_ticket_implementation`; QA tests a diff and there is none. Not a flag — but it has a
   regression test, because "QA didn't run" is otherwise indistinguishable from a silent failure.

**A ticket comment is the first append-only terminal action in this plugin, and that needs a
guard.** Every other one is retry-tolerant: `gh pr review` re-submits, `gh pr create` errors on an
existing PR, a queue move is a no-op the second time. But the listener judges success purely by
"did the item leave `drafts/`" and, on failure, actively invites a retry (`⚠️ Failed … re-run`). So a
run that posts the comment and *then* dies (budget abort, API error) leaves the item in `drafts/`,
the user taps Approve again, ntfy mints a **new** message id so `state/ntfy-seen.yaml` does not
dedup it — and the ticket gets a second findings document, each one bumping `updated`, which is the
self-sustaining re-queue loop `references/queue-reconciliation.md` exists to stop. So before
launching, the listener globs `investigations/{key}-*.md`; if anything matches it does **not**
investigate again. That works only because the archive path is **pinned in the prompt by the
listener** rather than chosen by the model.

**Honest limit — this moves the gate, and says so.** Everywhere else, the human approves *the exact
text that will be posted*. Here they approve a **plan**, and the model then authors and posts prose
derived from untrusted ticket text with no second look. Post-capable-and-gated is precedented
(`run_generic_execute` holds `Bash(gh *)` + `createJiraIssue`); ingesting-untrusted-text-and-posting
in the same unsupervised run is not. Containment: the `ticket_key` is validated in plain bash and
the run **refuses to start** if it fails; the prompt carries a `TARGET:` directive naming that key as
the only permitted comment target, capping it at one comment and instructing that any instruction
inside the ticket text naming another issue be ignored — the same pre-expanded pinning
`cron-poll.sh` gives `${SLACK_BIN}`. And **MCP permission rules cannot be scoped to arguments**, so
`addCommentToJiraIssue` is a capability over every issue the Atlassian token can reach and
`Bash(gh issue comment:*)` over every repo `gh` is authed for; the prompt pin is the only scoping
that exists. Same "medium, not airtight" admission as `Bash(git *)` vs `git -C /elsewhere` above.
The transition verbs are stricter still: they are absent from the allowlist entirely unless
`investigation.on_complete_status` is configured, so capability follows config.

Key invariant: **polling reads; only `execute-item` writes.** `cron-poll.sh` passes a deliberately
read-only `--allowedTools` allowlist (`gh pr list/view/diff`, `gh issue list/view`,
`gh auth status`/`gh --version`, the Slack
backend's `read`/`thread` — `spy` or `scripts/slack-mcp.sh`, keyed off `agent.slack.method` and
resolved in plain bash before `claude` starts — and the read-only MCP verbs
`mcp__atlassian__searchJiraIssuesUsingJql`/`getJiraIssue` and
`mcp__slite__search-notes`/`get-note`/`get-note-children`), so the poll can discover work and draft
responses but *physically cannot* post. `gh pr create`, `gh pr review`, `gh issue create` and the
Slack `send` verb (under either method) are unmatched, as is `gh api` (`gh api -X POST` writes); so
are the Jira/Slite **write**
MCP tools (`createJiraIssue`, `editJiraIssue`, `transitionJiraIssue`, `addComment*`, and every
Slite create/edit/append tool). MCP tools are denied unless named explicitly, exactly like `gh` —
so a poller that drives an MCP server (Jira, Slite) silently skips every run until its read verbs
are added here. This is what makes the approval gate structural rather than advisory: polling ingests
untrusted text (PR/issue bodies, Slack messages), so a prompt-injection payload must not be able
to reach a write verb. Keep every posting capability in `execute-item`, behind the gate. When
adding a source, give the poll its read verbs only. (The investigation feature needed **no** new
poll verbs: the poll only drafts an *investigation plan*, `mcp__atlassian__getJiraIssue` already
supplies the `issuetype` the kind ladder reads, and `Read` already reaches
`references/ticket-kind.md`. The comment and the transition happen later, behind the gate.)

Key invariant: **`/engineer-agent review-queue` (terminal) and `/engineer-agent execute` (remote) both delegate to the shared `execute-item` skill** — the single source of truth for what approving an item does. Three typed exceptions: `qa-test-plan` is interactive-only and is refused on the remote path; an approved `ticket` on the remote path is handled by the listener's confined worktree implementation (above) rather than by `execute-item` — `implement-ticket` opens the draft PR itself; and an approved `ticket-investigation` is likewise handled by the listener's confined **read-only** investigation (`run_ticket_investigation`) — `investigate-ticket` posts the ticket comment itself. `execute-item`'s own `ticket-investigation` case is the *finisher* for the interactive path: it posts an **already-written** `## Findings` section and refuses if there isn't one. `execute-item`'s own `ticket` case is the *finisher* for the interactive/manual path, creating a draft PR from an **already-implemented, pushed branch** (it writes no code). (The `generate-qa` skill, when the app is reachable at `qa.base_url`, also runs its generated script and fixes failing scripted tests in place — fixing test defects but leaving genuine code-bug failures as reported findings, never demoting them to the manual checklist; best-effort, it skips execution and reports when the app is unreachable.) `scripts/lib-ntfy.sh` is the shared config reader sourced by `notify.sh` and `approval-listener.sh`.

**Security:** on public `ntfy.sh` a topic name is effectively a password (the `command_topic` can trigger Slack posts / PR creation). Use high-entropy names, set `auth_token`, and/or self-host via `server`. The listener also defends in depth: it only accepts `approve`/`reject`, only item ids matching `^[A-Za-z0-9._-]+$`, and only acts on items still in `queue/drafts/` (idempotent via `state/ntfy-seen.yaml`).

## Available Integrations

- GitHub (PRs and Issues): `gh` CLI via Bash (requires `gh auth login`)
- Slack (two backends via `agent.slack.method`, see "Config Loading Pattern" above): the
  [Spy](https://github.com/tomharris/spy) CLI (`spy`, default) reusing the local Slack desktop
  session (no OAuth/app install), OR `scripts/slack-mcp.sh` (`mcp-proxy`, for Enterprise Grid)
  going through the Keychain OAuth token + Anthropic MCP proxy. Both expose the same interface:
  reads with `<slack> read`/`<slack> thread`, posts with `<slack> send` (`--thread <ts>` for
  threaded replies). Same binary works in interactive skills and the headless cron/ntfy scripts.
  Because the MCP-proxy shim runs as one Bash invocation, its internal `curl`/`jq`/`security`
  subprocesses need no separate allowlist entry — a single `Bash(<shim> read:*)`-style rule
  covers the whole call. **But that rule must match the shim's path as the model *actually runs*
  it, and getting there took several corrections, each learned from a real failing poll (transcript
  evidence, not theory):** the skills reference the shim as `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh`
  (per `poll-slack`/execute-item), and (1) the **model expands `${CLAUDE_PLUGIN_ROOT}` to an
  absolute path** before Bash ever sees it — it does *not* pass the literal `${CLAUDE_PLUGIN_ROOT}`
  token, so a single-quoted-literal allowlist rule is dead code and never matches (an earlier fix
  that added one did nothing); and (2) **that expanded root is not stable — it has been observed
  resolving to THREE different dirs across runs**: the dev-repo `PLUGIN_ROOT` a script derives from
  its own location (a bare `--plugin-dir` run), the *installed cache* path
  (`~/.claude/plugins/cache/engineer-agent/engineer-agent/<ver>`, when marketplace-installed shadows
  `--plugin-dir`), **and** the *marketplace checkout* path
  (`~/.claude/plugins/marketplaces/engineer-agent`). A rule built from only one or two of these
  misses whenever the runtime picks the third, and any miss denies the Slack call non-interactively
  (a prompt under `-p` is a denial). Fix: `cron-poll.sh` and `approval-listener.sh` allowlist the
  shim's **expanded** abs path for **all three** candidate roots — the script's own `PLUGIN_ROOT`,
  `resolve_installed_plugin_root()` (highest-version installed cache dir), and
  `resolve_marketplace_plugin_root()` (the marketplace checkout) — all three in `lib-paths.sh`, so
  whichever root the runtime resolves, a rule matches. (3) The **poll allowlist must also include
  the `auth` verb, not just `read`/`thread`**: the model runs `slack-mcp.sh auth` as a read-only
  token preflight before reading, and when only `read`/`thread` were allowed that preflight was
  denied — the model then treated the shim as unavailable and cascaded to the direct
  `mcp__claude_ai_Slack__slack_read_channel` connector, which is *also* unlisted, so both Slack
  paths were denied and the poll silently drafted nothing for the affected projects while its
  narrative sometimes still (wrongly) claimed Slack "succeeded" — trust the receipt's `errors:`
  list and the transcript, not the prose summary. `cron-poll.sh` allowlists `read`/`thread`/`auth`
  for every root; `approval-listener.sh` uses a trailing-`*` rule that already covers all verbs.
  (`spy` needs none of this — it is a bare literal identical in rule and invocation; that is the
  pattern the shim's path form can't reach.) (4) **A rule must match the command *form*, not just
  the path — and the durable fix is to stop the model guessing at all.** The root was never the
  only variable: the model also chooses how to *invoke* the shim, and it was observed emitting
  `bash <abs>/scripts/slack-mcp.sh auth 2>&1`, whose executable is `bash` — matching no `<abs>/…`
  rule, so the call is refused outright. That denial is **fatal, not recoverable**: the model
  concludes the shim is unavailable and cascades to the unlisted direct connector, and every Slack
  source errors. Transcript-confirmed on `2026-08-01T15:00Z` and `2026-08-03T13:04Z` — **exactly**
  the two runs out of the last sixteen that emitted a `bash `-prefixed call, and exactly the two
  that failed; the other fourteen used the bare form and succeeded. The form varied run-to-run
  because the model *rediscovers the shim every run*: `${CLAUDE_PLUGIN_ROOT}` is not resolvable
  inside the run (the probe `echo "PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT"` is itself refused with
  `Contains simple_expansion`), so it falls back to `find`/`ls` and improvises. So the **primary**
  fix is a `SLACK:` directive in the poll prompt that pins the exact resolved `${SLACK_BIN}` and
  forbids filesystem discovery, a `bash`/`sh`/`env` prefix, compound commands, and the
  `mcp__claude_ai_Slack__*` fallback — the same pre-expanded-path treatment `notify.sh` already
  got. The allowlist widening (bare **and** `bash `-prefixed, generated as roots × verbs × forms
  in both scripts) is now only defense in depth for when the model improvises anyway. Note the
  connector is deliberately **not** allowlisted: the shim stays the single Slack path so its
  exit-`75` skip-on-expiry semantics remain well-defined. Also allowlist `Bash(echo:*)` — Claude
  Code evaluates each part of a compound command separately, so the model's habitual
  `… auth 2>&1; echo "EXIT:$?"` probe got the *whole* invocation refused; it recovered by retrying,
  so it never failed a poll, but it burned a turn on nearly every run.
- Jira: `mcp__atlassian__*` tools (optional — either Jira or GitHub Issues per project)
- Slite: `mcp__slite__*` tools
- ntfy (optional): push notifications + remote approval via `curl` (publish) and `scripts/approval-listener.sh` (subscribe). Listener requires `jq`. Turn-completion pushes (`hooks/hooks.json` → `scripts/turn-notify-hook.sh`) add **no** hard dependency — jq is used only to decode the message excerpt, and its absence degrades to a label-only push.


## Deterministic polling (scripted collectors)

A poll used to be one `claude -p` session that read ~87KB of instructions (`commands/poll.md`, five
`skills/poll-*/SKILL.md`, three `references/*.md`) plus every raw API response, on **every fire,
every 15 minutes**, to do work that is almost entirely string comparison and file writing. The
steady state of a healthy queue is `items_queued: 0`, so most of that spend bought the answer
"nothing new".

`agent.poll.scripted_sources` moves the mechanical half into bash. The run becomes two phases:

```
cron-poll.sh
  ├─ PHASE A  scripts/poll-{github-issues,github-prs,jira,slite}.sh   (no model)
  │           fetch → filter → reconcile → route → classify → write queue file → state + receipt
  │           emits queue/incoming/*.md + state/poll-manifest.tsv
  └─ PHASE B  claude -p, ONLY if the manifest is non-empty
              drafts each manifest item and moves it to drafts/
```

**When Phase A finds nothing and every configured source is scripted, `claude` is never started.**
A full 5-repo poll of a real config takes ~6s and writes a receipt byte-identical to the model's.

### What is scripted and what is not

| Work | Where |
|---|---|
| Config parse, tracker inference, per-source configured/skipped decision | bash (`ea-config.sh`) |
| Fetch (`gh issue list`/`pr list`; Jira + Slite REST via curl), all filters, priority mapping | bash |
| Reconciliation table (skip / unchanged / update-in-place / create) | bash (`lib-queue.sh`) |
| Routing ladder **tiers 0–3a**, for GitHub, Jira *and* Slite | bash (`lib-routing.sh`) |
| Jira JQL construction, quoting, and the account-timezone conversion | bash (`poll-jira.sh`) |
| Credential resolution (env → file → Keychain), read-only | bash (`lib-secret.sh`) |
| Ticket-kind **tiers 0–2 and 3 Form A** | bash (`lib-ticket-kind.sh`) |
| Filename, frontmatter, `## Context`, branch slug | bash (`lib-queue-write.sh`) |
| State + receipt | bash (`lib-state.sh`, `cron-poll.sh`) |
| Routing **tier 3b** (semantic), kind **Form B** (imperative-vs-noun), Slack relevance | **model** |
| **All draft prose** | **model** |

The three judgment tiers are **flagged in the manifest**, never guessed. `needs_routing=1` writes
the item as `project: _unrouted` with `matched_projects`, which the model finishes through the
already-documented `incoming/` + `_unrouted` → update-in-place branch of
`references/queue-reconciliation.md` — no new state, no new code path.

### The scripts

| File | Role |
|---|---|
| `lib-yaml.sh` | one generic indent-stack YAML reader (`yaml_get`/`yaml_get_list`/`yaml_keys`/`yaml_seq_len`), including block sequences of mappings (`jira.sources`) and block scalars (`routing.description`) |
| `ea-config.sh` | normalizes `engineer.yaml` to flat greppable lines, applying defaults, tracker inference and the `investigation.*` replace-not-merge rule **once** |
| `lib-queue.sh` | frontmatter access + `queue_disposition` (the reconciliation table) + `poll_resume_candidates` |
| `lib-queue-write.sh` | queue-item construction, with real YAML escaping |
| `lib-routing.sh` / `lib-ticket-kind.sh` | the deterministic ladder tiers |
| `lib-state.sh` | round-trips `state/last-poll.yaml`, preserving model-written sections |
| `lib-time.sh` | GNU/BSD-portable timestamp helpers |
| `poll-github-issues.sh` / `poll-github-prs.sh` / `poll-jira.sh` / `poll-slite.sh` | the collectors |
| `lib-secret.sh` / `setup-credentials.sh` | resolve (read-only) and store the Jira/Slite API credentials |
| `queue-status.sh` / `queue-list.sh` | the data behind `status` / `review-queue` |

> **`ea-config.sh dump` emits a CURATED view and deliberately omits `agent.notify.ntfy.*`.** On
> public ntfy.sh the `command_topic` is effectively a password for remote approval, and a poller
> has no use for it. Keeping it out means the normalized config can be logged or cached while
> debugging without leaking the credential.

### Invariants that survive the move

- **Polling still only reads.** The collectors call `gh issue list` / `gh pr list`, and — for Jira
  and Slite — `GET`/`POST /search` REST endpoints that return data only. No posting verb is
  reachable from Phase A at all; the read-only guarantee is structural in bash rather than enforced
  by an `--allowedTools` allowlist. The Jira credential is an API token whose scope is the account's
  own permissions, so this is the one place where "read-only" is a property of the *verbs used*
  rather than of the *capability held* — keep it that way: no collector may ever call
  `POST /issue/{key}/comment` or a transition.
- **Injection containment is stronger, not weaker.** The routing candidate set is computed from
  config alone and every tier can only narrow it, so a scripted route can only ever emit a slug the
  config already permits. The kind ladder's entire output alphabet is two fixed strings.
- **Terminal state stays absorbing.** `queue_disposition` looks up the whole `{ticket,
  ticket-investigation}` family *including* `completed/` and `rejected/`, so the self-sustaining
  re-queue loop (engineer-agent's own comment bumps `updatedAt`) cannot restart.

### Jira and Slite: what REST changes

These two have no CLI to shell out to, which is why they were previously listed as permanently
model-driven. Four consequences that a reader will otherwise try to "simplify" away:

- **Jira REST API v2, not v3.** v3 returns `description` as an Atlassian Document Format *tree*;
  reconstructing prose from that in bash would be a parser of its own, and its failure mode is a
  queue item with an empty or mangled `### Description` that a human then approves work from. v2
  returns text. Both are supported on Jira Cloud.
- **`jq` is a hard dependency of these two collectors and a soft one for the poll.** The GitHub
  collectors use `gh --jq` (gh's embedded engine) to honour the "the cron path is jq-free" policy;
  there is no equivalent for curl. So a missing `jq` exits 3 and the model polls that source, which
  is what the policy actually protects.
- **The JQL timezone conversion is load-bearing.** A bare datetime in JQL is read in the *account's*
  Jira profile timezone, not UTC, so feeding it a UTC watermark's clock digits shifts the window by
  the account offset — six hours into the **future** for a Denver account, after which every ticket
  updated during working hours falls before the cutoff. The poll then queues nothing and reports
  `status: ok`, which is indistinguishable from a quiet day. The offset is read off a real returned
  timestamp (DST-correct, no tz database); a **failed** bootstrap exits 3 rather than assuming UTC,
  because silently assuming +00:00 on a non-UTC account reintroduces the bug with no signal at all.
- **Slite's tag exposure is not guaranteed.** The note object is read for several plausible tag
  shapes; when none is present the doc is matched on the search query that found it and the item
  records `label_source: query`, so the approval gate can see the match was weaker than a real tag
  comparison. An *unrecognisable* response shape exits 3 rather than yielding zero docs — "no docs
  need review" must never be something a parse failure can say.

**A bug fixed in passing:** `skills/poll-slite/SKILL.md` iterates per project and queues a matching
doc for each. In a real config all six projects set `doc_labels: ["needs-review"]`, so every review
doc matches every project and the global `source_id` dedup silently awards it to whichever project
the loop reached first — the shared-repo trap in a different costume. `poll-slite.sh` collects docs
once and routes them through the ladder, so the ambiguous case becomes a visible `_unrouted` item
instead of an invisible arbitrary assignment.

### Credentials

`agent.jira.*` / `agent.slite.*` name **where** the token is, never what it is: `engineer.yaml` is a
file people paste into issues when asking for help, and `ea-config.sh dump` is documented as safe to
log. `lib-secret.sh` resolves env var → file → macOS Keychain and never writes; `setup-credentials.sh`
is the single (interactive) writer, and its `check` subcommand reports what resolves without printing
a secret.

> **Prefer the Keychain on macOS.** cron/launchd/systemd hand the run a minimal environment, so a
> token exported from a shell profile is present in every terminal you test from and ABSENT in the
> supervised poll — the collector then skips cleanly every 15 minutes forever, and the only symptom
> is that Jira is never actually scripted. This is the same class of bug as the missing `$USER` that
> once broke every cron poll. The poll already runs as a `gui/$UID` LaunchAgent specifically so it
> can read the login keychain (`slack-mcp.sh` relies on the same property), so this needs no
> scheduler change. `setup-credentials.sh check` warns when a token resolves only from the
> environment.

Credentials are passed to curl via `--config -` (**stdin**), never `-u`/`-H` in argv: an argv
credential is readable by any other process on the box via `ps`, and this runs unattended every 15
minutes. Both test suites assert the secret never appears in argv.

### Two hazards the design has to handle

**1. Nothing may be stranded in `incoming/`.** Only `drafts/` is reachable by the approval gate, and
the reconciliation table says a resolved `incoming/` item is "leave alone" — so an item written by
Phase A whose drafting phase died would sit there **forever, invisibly**. Two guards:
`poll_resume_candidates()` re-emits any `incoming/` item lacking a `## Draft Response` into every
subsequent manifest (self-healing on the next tick), and `queue-status.sh` reports the count as a
warning. `tests/lib-queue.test.sh` and `tests/poll-github-issues.test.sh` both pin it.

**2. `gh --jq`, not `jq`.** The collectors use gh's *embedded* jq engine, so they add no dependency
and stay inside the "the cron path is jq-free" policy `cron-poll.sh` sets. A Slack collector would
need real `jq` and must gate on it softly (fall back to the model), never hard-fail.

### Gotchas learned while building this — each cost a real debugging cycle

- **Flow *and* block sequences.** A real `engineer.yaml` mixes them (`exec.allowed_commands:` is a
  block list; `github.repos: ["a", "b"]` is flow). `lib-paths.sh`'s `yaml_project_list()` handles
  block only and gets away with it because its one caller reads `exec.allowed_commands`. A reader
  that missed flow would poll **zero repos, silently**.
- **Multi-line flow sequences.** `config/engineer.example.yaml` ships `title_keywords` wrapped
  across two lines. A single-line-only parser returns an empty list and silently disables the whole
  title tier of `references/ticket-kind.md` for anyone who copied the example.
- **`while read` drops an unterminated final line.** `read` returns non-zero at EOF without a
  newline, so the loop body never runs for that line. This silently produced `github_labels: []` —
  a valid-looking value that degrades Tier 2 routing and Tier 2 kind classification. Producers emit
  a trailing newline; consumers use `|| [ -n "$var" ]`.
- **`date -d` is GNU-only** and macOS runs LaunchAgents. A BSD fallback that merely strips a UTC
  offset is *six hours wrong* rather than failing, so `lib-time.sh` normalizes offsets in shell and
  both platforms take one path.
- **`exit` still runs awk's `END` block**, so an `END` that also prints emits the count twice.
- **`set -o pipefail` + `grep -q`** reports a *successful* match as a failed pipeline, because
  `grep -q` closes the pipe and the upstream dies of SIGPIPE. Capture output first, then grep.
- **`close` is a reserved word in awk** and cannot be a parameter name.
- **No apostrophes inside the awk program.** `lib-yaml.sh` holds its whole awk script in a
  single-quoted string, so an apostrophe in a *comment* terminates it and the file stops parsing.
  That is why the existing code writes `\047` for a literal quote. A comment reading "the
  sequence's parent" is a syntax error.
- **A bare statement before `else` is not portable awk.** `if (c) x = 1` on its own line followed by
  `else` is rejected by BSD awk (which is what macOS LaunchAgents run). Brace every arm.
- **`"maxResults":1` is a substring of `"maxResults":100`.** A test stub dispatching on the former
  served the timezone fixture to every search page, so the collector saw zero issues and every
  assertion after it failed. Anchor on the trailing comma.
- **Jira `jira.sources` is a block sequence of MAPPINGS**, which `lib-yaml.sh` refused outright
  before this work (`[]#map-unsupported`). It is now modelled as indexed sub-paths
  (`…sources[0].project`) rather than flattened, because the elements are a set whose filters must
  stay attached to their own project key — flattened, a catch-all source silently inherits the
  previous one's component filter.
- **`routing.description` is written as a folded block scalar (`>-`) in a real config**, and the
  reader returned the literal `>-` as the value. Tier 3b of the routing ladder has no other input,
  so the tier looked configured while deciding on two characters of punctuation.

### A spec ambiguity this surfaced

`references/ticket-kind.md` gives Form A as a regex ending
`… [ \] ) ]? \s* ( : | — | – | - | \| | · | end-of-title )`, but also lists `[Decision] queue
backend` among the titles that **fire** — and under the literal regex it does not, since what
follows the bracket is `queue`. `lib-ticket-kind.sh` implements the doc's **worked examples** (a
closing bracket is itself a delimiter) and says so at the implementation site;
`tests/ticket-kind.test.sh` pins every fires/does-not-fire example verbatim. A model reading the doc
resolved this by intuition each run; a script has to pick, which is how the ambiguity became visible.

## Tests

`tests/run-all.sh` runs every suite (there is no CI). Each is self-isolating: `set -uo pipefail`,
`PASS`/`FAIL` counters, an `mktemp -d` sandbox and `export EA_AGENT_DIR=…`, with PATH shims for
external binaries (`gh`, `claude`, `curl`, `security`). Follow that shape when adding one.

## Documentation Maintenance

When any command, skill, config option, queue format, or integration is added, changed, or removed, check both `CLAUDE.md` and `README.md` for needed updates. These two files must stay in sync with each other and with the actual plugin behavior.
