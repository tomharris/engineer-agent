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
references/                    — Shared procedural docs skills Read at runtime (routing-ladder.md)
scripts/                       — Cron polling, ntfy notify/listener, and setup scripts
config/engineer.example.yaml   — Config template
```

`references/` holds logic that several skills must apply *identically*. It is plain markdown read
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
└── state/
    ├── last-poll.yaml         — Dedup timestamps and seen IDs (per project, per Jira project key, per GitHub repo)
    ├── last-poll-receipt.yaml — Liveness receipt from the last cron poll (run_id, status, item count, errors)
    └── ntfy-seen.yaml         — Processed ntfy command message IDs (remote-approval dedup)
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

Slack access uses the Spy CLI (`agent.slack`, optional):
- `agent.slack.bin` — path to the `spy` binary. Effective binary = `agent.slack.bin` ?? `spy` (on PATH).
- `agent.slack.workspace` — default Slack workspace. Effective workspace = `projects.<slug>.slack.workspace` ?? `agent.slack.workspace` ?? Spy's own default. Pass it as `-w <workspace>` on every `spy` call (Spy errors when multiple workspaces are signed in and no default is set).

To find config for a specific project, look up `projects.<slug>`. Each project entry has `path`, `tracker`, `github`, `slack`, `jira`, `slite`, `qa`, and (optional) `exec` subsections. `exec.allowed_commands` is the build/test command allowlist for confined headless ticket implementation — see "Confined headless ticket implementation" under Notifications & Remote Approval. The `tracker` field (`"jira"` | `"github-issues"` | `"none"`) determines which ticket tracker a project uses. If absent, it's inferred: `jira` section present → `"jira"`, `github.issues` section present → `"github-issues"`, neither → `"none"`.

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

### QA Documentation Config

The `qa` subsection drives QA test plans: `base_url` and `console_command` (used during generation), plus optional documentation keys `document_to` (`"slite"` | empty — empty/absent disables) and `document_parent` (Slite channel/note id; empty ⇒ the user's private personal channel). When `document_to: slite`, a completed QA plan (review-queue Phase 3) is published to Slite as one note containing the full plan, the inlined `qa-test.sh` script, and the execution results — best-effort, never blocking completion.

## Queue File Format

Items enter the queue either via polling (`/engineer-agent poll` or the cron) or manually (`/engineer-agent add-ticket <ref>`). Both paths produce identically-shaped queue files.

Files move through: `~/.local/share/engineer-agent/queue/incoming/` → `queue/drafts/` → `queue/completed/` or `queue/rejected/`

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
- `type`: pr-review | slack-question | ticket | doc-review | spec-refinement | design-doc | ticket-plan | ticket-refinement | gap-audit | qa-test-plan | code-audit-finding | codify-candidate
- `source`: github | slack | jira | slite | audit | internal
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
- `jira_components`: (Jira tickets only) array of Jira component names on the ticket
- `jira_labels`: (Jira tickets only) array of Jira labels on the ticket
- `github_labels`: (GitHub issues only) array of label names on the issue
- `audit_category`: (code-audit-finding only) `security` | `correctness` | `secret` | `dependency`
- `audit_severity`: (code-audit-finding only) `critical` | `high` | `medium` | `low`
- `audit_confidence`: (code-audit-finding only) `medium` | `high` (low is filtered out)
- `audit_file`: (code-audit-finding only) repo-relative path to the offending file
- `audit_line_range`: (code-audit-finding only) e.g. `"42-58"`
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

**Writing a headless `claude -p` run** (both scripts do this; the rules below were each learned
from a run that failed silently):
- **Pin `--permission-mode`.** Otherwise the run inherits `permissions.defaultMode`; in `plan` mode
  `claude -p` prints a plan and exits 0 without doing anything.
- **`--permission-mode` is not enough on its own — pass `--allowedTools`.** Only a built-in set of
  Bash commands (`ls`, `cat`, `grep`, read-only `git`, …) is auto-approved. `gh` and `spy` are not
  in it, so they prompt in every mode, and a prompt in `-p` is a denial.
- **Don't put `--allowedTools` last before the prompt.** It takes a variable number of values and
  will swallow the prompt as another rule (`Input must be provided … when using --print`). Keep a
  single-value flag in between.
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
- **`forceLoginOrgUUID` is a separate, orthogonal wall that blocks *all* headless auth — keychain
  and env-token alike — so no scheduler choice helps while it is present.** When an org deploys a
  root-owned `/Library/Application Support/ClaudeCode/managed-settings.json` with
  `forceLoginMethod: claudeai` + `forceLoginOrgUUID: <uuid>`, Claude Code restricts login to that
  org, **exits at startup if the active credential isn't a verified member**, and per the official
  docs *blocks all environment credentials* (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
  `apiKeyHelper`, `CLAUDE_CODE_OAUTH_TOKEN`) "since organization membership can't be verified for an
  environment credential." It surfaces as `Unable to verify organization for the current
  authentication token. This machine requires organization <uuid> but the token could not be
  validated` and `claude` exits 1 — a **freshly-minted, org-valid `claude setup-token` still fails
  identically** (verified 2026-07-16), because it is an environment credential regardless of which
  org minted it. Under this policy the interactive GUI keychain login passes but a scheduler can't
  reach it, so a token on disk was a genuine dead end. **This policy was removed from this machine
  on 2026-07-17**; with it gone, the residual "Not logged in" was purely the out-of-session keychain
  problem above, fixed by the launchd migration. If the policy is ever re-deployed, the only
  surviving headless paths are (a) a cloud-provider inference path (Bedrock/Vertex/Foundry, via
  `CLAUDE_CODE_USE_BEDROCK`/`_VERTEX`/`_FOUNDRY`), which the docs exempt, or (b) an org/IT exemption
  or org-scoped headless credential. If a root-owned `managed-settings.json` is present, do **not**
  delete or shim around it — it is an intentional corporate security control.

Both `cron-poll.sh` and `approval-listener.sh` resolve the Claude Code binary from `PATH` by default, but honor a `CLAUDE_BIN` env var override (a specific shim/wrapper/install path). Because cron, systemd, and launchd do not inherit the interactive shell environment, `install-cron.sh` and `install-listener.sh` capture `CLAUDE_BIN` when set at install time and bake it into the launchd `EnvironmentVariables` (macOS) / systemd `Environment=` (Linux listener) / crontab entry (Linux poll) so the supervised runs use the same binary. On macOS `install-cron.sh` also accepts `EA_POLL_HOURS` (comma-separated clock hours) + `EA_POLL_MINUTE` to emit a `StartCalendarInterval` schedule confined to business hours instead of the default `StartInterval` every-N-minutes; this caps how much a first poll on a large assigned backlog can spend.

> **A supervised daemon runs whatever it parsed at launch — editing the script on disk
> does not reload it.** `install-listener.sh`'s `systemctl --user enable --now` is a no-op on an
> already-running unit, so before this was fixed a code deploy could leave the *old* listener
> running silently (it once ran ~28h past a commit and never emitted the newly-added acks). Two
> guards: `install-listener.sh` now `systemctl --user restart`s on every re-install (matching the
> macOS `kickstart -k` path), **and** `approval-listener.sh` re-execs itself at the top of its
> reconnect loop when its own mtime changes — the one point guaranteed to be *between* executes,
> so no in-flight approval is interrupted.

The listener's headless execute is capped with `--max-budget-usd`, chosen **per item type** from
the draft's `type:` frontmatter: `ticket` items (which run the full `implement-ticket` coding session)
get `TICKET_BUDGET_USD` (default `8.00`); everything else gets `DEFAULT_BUDGET_USD` (default
`2.00`). Override either via the `EA_TICKET_BUDGET_USD` / `EA_EXECUTE_BUDGET_USD` env vars. A flat
`0.50` used to abort every ticket approval with "Exceeded USD budget", stranding it in `drafts/`.
Only `ticket` unlocks the higher cap, so untrusted frontmatter can at worst pick between two fixed
values — never inflate spend.

### Confined headless ticket implementation

A `ticket` is the one item type whose *execution writes code* — approving it runs the full
`implement-ticket` flow (branch → inline iterative implementation → migrations/typecheck → draft PR), not a single
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

**Honest limit — this is "medium," not airtight.** Claude Code `Bash()` rules are command-prefix
matches, *not* cwd-scoped, so `Bash(git *)` also permits `git -C /elsewhere`. The worktree bounds
the *default* target and the command *set* is curated, but that prefix-vs-path gap is the residual
risk. Mitigating it: the command set is small and build-only, the source is an issue routed to the
user's own project, and the output is draft-only. `implement-ticket` is worktree-aware (Step 2: it
creates the branch in place when already inside the repo checkout, and pushes before `gh pr
create` so the headless run never hits an interactive push prompt).

Key invariant: **polling reads; only `execute-item` writes.** `cron-poll.sh` passes a deliberately
read-only `--allowedTools` allowlist (`gh pr list/view/diff`, `gh issue list/view`, `spy read/thread`,
and the read-only MCP verbs `mcp__atlassian__searchJiraIssuesUsingJql`/`getJiraIssue` and
`mcp__slite__search-notes`/`get-note`/`get-note-children`), so the poll can discover work and draft
responses but *physically cannot* post. `gh pr create`, `gh pr review`, `gh issue create` and
`spy send` are unmatched, as is `gh api` (`gh api -X POST` writes); so are the Jira/Slite **write**
MCP tools (`createJiraIssue`, `editJiraIssue`, `transitionJiraIssue`, `addComment*`, and every
Slite create/edit/append tool). MCP tools are denied unless named explicitly, exactly like `gh` —
so a poller that drives an MCP server (Jira, Slite) silently skips every run until its read verbs
are added here. This is what makes the approval gate structural rather than advisory: polling ingests
untrusted text (PR/issue bodies, Slack messages), so a prompt-injection payload must not be able
to reach a write verb. Keep every posting capability in `execute-item`, behind the gate. When
adding a source, give the poll its read verbs only.

Key invariant: **`/engineer-agent review-queue` (terminal) and `/engineer-agent execute` (remote) both delegate to the shared `execute-item` skill** — the single source of truth for what approving an item does. Two typed exceptions: `qa-test-plan` is interactive-only and is refused on the remote path; and an approved `ticket` on the remote path is handled by the listener's confined worktree implementation (above) rather than by `execute-item` — `implement-ticket` opens the draft PR itself. `execute-item`'s own `ticket` case is the *finisher* for the interactive/manual path, creating a draft PR from an **already-implemented, pushed branch** (it writes no code). (The `generate-qa` skill, when the app is reachable at `qa.base_url`, also runs its generated script and fixes failing scripted tests in place — fixing test defects but leaving genuine code-bug failures as reported findings, never demoting them to the manual checklist; best-effort, it skips execution and reports when the app is unreachable.) `scripts/lib-ntfy.sh` is the shared config reader sourced by `notify.sh` and `approval-listener.sh`.

**Security:** on public `ntfy.sh` a topic name is effectively a password (the `command_topic` can trigger Slack posts / PR creation). Use high-entropy names, set `auth_token`, and/or self-host via `server`. The listener also defends in depth: it only accepts `approve`/`reject`, only item ids matching `^[A-Za-z0-9._-]+$`, and only acts on items still in `queue/drafts/` (idempotent via `state/ntfy-seen.yaml`).

## Available Integrations

- GitHub (PRs and Issues): `gh` CLI via Bash (requires `gh auth login`)
- Slack: the [Spy](https://github.com/tomharris/spy) CLI (`spy`) via Bash — reuses the local
  Slack desktop session (no OAuth/app install). Reads with `spy read`/`spy thread`, posts
  with `spy send` (`--thread <ts>` for threaded replies). Same binary works in interactive
  skills and the headless cron/ntfy scripts.
- Jira: `mcp__atlassian__*` tools (optional — either Jira or GitHub Issues per project)
- Slite: `mcp__slite__*` tools
- ntfy (optional): push notifications + remote approval via `curl` (publish) and `scripts/approval-listener.sh` (subscribe). Listener requires `jq`.

## Documentation Maintenance

When any command, skill, config option, queue format, or integration is added, changed, or removed, check both `CLAUDE.md` and `README.md` for needed updates. These two files must stay in sync with each other and with the actual plugin behavior.
