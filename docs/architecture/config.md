# Configuration

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
- `agent.autonomy.auto_execute` — a list of action tiers allowed to run **without** an approval gate. Supported: `draft-pr` (draft PRs merge nothing / request no review), and for the `implement-next` scheduled jobs `implement` (start the confined implementation without an Approve tap) and `jira-claim` / `github-claim` (assign/transition the Jira ticket, or assign the GitHub issue and set its Projects board status, without one); a job needs `implement` plus its tracker's claim tier to run unattended (see "Scheduled jobs"). `pr-ready` lets the `after_pr` pipeline (`scripts/pr-pipeline.sh`) mark an autopilot PR ready for review once CI is green and the browser test passed. The pipeline's other stages each have their own tier: `security-review` (run the `security.command` adapter and fix what the PR introduced), `qa-publish` (QA plan, Slite note, PR and Jira comments), `jira-transition` (move the ticket after ready) and `slack-post` (the `announce` message). `slack-react` adds/removes the `agent.slack.reactions` status emoji on a Slack item's message. Absent ⇒ empty ⇒ everything is gated.
- `agent.notify.ntfy` — push-notification + remote-approval settings (`server`, `topic`, `command_topic`, `auth_token`). Absent ⇒ no notifications; the workflow is otherwise unchanged.
- `agent.investigation` — which tickets deliver a **findings document** instead of code
  (`jira_types`, `github_labels`, `title_keywords`). Absent ⇒ shipped defaults apply, which include
  Jira type `Task`. Per-project `projects.<slug>.investigation.*` **replaces** a list rather than
  merging it, so a project can *narrow* the triggers (the operation that fixes a false positive); an
  explicitly empty list disables that tier. See "Ticket Kind" below.
- `agent.poll.scripted_sources` — a list of sources collected by a **deterministic script**
  rather than by the model (`github-issues`, `github`, `jira`, `slite`, `slack`). Absent/empty ⇒ the
  prompt-driven path, unchanged. Env override `EA_POLL_SCRIPTED_SOURCES`. See "Deterministic
  polling" below. `slack` additionally requires `agent.typesafe` — see "Scripted Slack polling".
- `agent.typesafe` — API access for the System One judgments (`api_key_env`, `api_key_file`,
  `api_base`, `model`, plus each feature's thresholds: `slack.min_question` / `slack.min_directed`
  / `slack.max_answered` / `slack.min_engineer`, `ticket_kind.min_imperative` and
  `routing.min_confidence`). Same credential
  rule as Jira/Slite: the keys name *where* the secret is and `scripts/lib-secret.sh` resolves it.
  **This is the only poll-path integration that sends content to a third party**, so the key is
  necessary for every feature below and sufficient for none — **each one opts in separately**, and
  without its own opt-in that judgment stays model-driven exactly as before:
  - **Slack relevance** — `slack` in `agent.poll.scripted_sources`. Sends message + thread text.
    See "Scripted Slack polling".
  - **Ticket-kind Tier 3 Form B** — `agent.typesafe.ticket_kind.enabled: true` (deny-by-default;
    only the exact string `true`). Sends a GitHub issue title + labels, never the body, and only
    for a title whose leading word already matches a configured keyword. See "Ticket Kind".
  - **Routing Tier 3b** — `agent.typesafe.routing.enabled: true` (same deny-by-default rule).
    Sends the item title + body (truncated, `EA_ROUTING_BODY_MAX`, default 4000 bytes) plus the
    candidate slugs and their `routing` hints — **the largest egress of the three** — and only for
    an item a shared repo/key left genuinely ambiguous. See "Ticket Routing".
- `agent.slack.user_name` / `agent.slack.user_id` — your Slack identity, read **only** by
  `poll-slack.sh`: `user_id` drops your own messages before any judgment is paid for, and both feed
  the "is this aimed at me?" judgment as state. Optional; absent, that judgment leans on
  `slack.keywords` alone and is correspondingly weaker.
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

To find config for a specific project, look up `projects.<slug>`. Each project entry has `path`, `tracker`, `github`, `slack`, `jira`, `slite`, `qa`, and (optional) `exec`, `investigation` and `jobs` subsections. `jobs` is a list of scheduled jobs — see "Scheduled jobs". `investigation` overrides the global kind lists for this project and carries `on_complete_status` — a Jira status to move the ticket to after a successful findings comment. Empty/absent ⇒ no transition, **and the transition MCP verbs are not added to the confined run's allowlist at all**, so capability follows config. `exec.allowed_commands` is the build/test command allowlist for confined headless ticket implementation — see "Confined headless ticket implementation" under Notifications & Remote Approval. The `tracker` field (`"jira"` | `"github-issues"` | `"none"`) determines which ticket tracker a project uses. If absent, it's inferred: `jira` section present → `"jira"`, `github.issues` section present → `"github-issues"`, neither → `"none"`.

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


### QA Documentation Config

The `qa` subsection drives QA test plans: `base_url` and `console_command` (used during generation), plus optional documentation keys `document_to` (`"slite"` | empty — empty/absent disables) and `document_parent` (Slite channel/note id; empty ⇒ the user's private personal channel). When `document_to: slite`, a completed QA plan (review-queue Phase 3) is published to Slite as one note containing the full plan, the inlined `qa-test.sh` script, and the execution results — best-effort, never blocking completion.

