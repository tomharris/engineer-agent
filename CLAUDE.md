# CLAUDE.md

## Project

engineer-agent — a Claude Code plugin that automates senior-engineer tasks behind an approval gate.
It drafts PR reviews, Slack answers, ticket implementations, doc reviews and standups; a human
approves via `/engineer-agent review-queue` or remotely via ntfy before anything is posted.
`/engineer-agent uat-plan` is outside the queue (read-only, writes `uat-plans/`).

This repo IS the plugin. Dev: `claude --plugin-dir /path/to/engineer-agent`.

```
.claude-plugin/plugin.json  manifest
commands/                   slash commands
skills/                     skills by task type
references/                 shared specs skills Read at runtime (routing-ladder.md, ticket-kind.md,
                            queue-reconciliation.md); scripts/lib-routing.sh and
                            lib-ticket-kind.sh implement their deterministic tiers
hooks/hooks.json            turn-completion push hooks
scripts/                    cron poll, ntfy notify/listener, collectors, jobs, setup, credentials
tests/                      shell suites; bash tests/run-all.sh
config/engineer.example.yaml
docs/architecture/          detailed design rationale (read before changing that area)
```

## Architecture docs — read the relevant one before editing

| Area | Doc |
|---|---|
| Structure, runtime data layout | `docs/architecture/overview.md` |
| `engineer.yaml` schema, Slack backends, TypeSafe opt-ins | `docs/architecture/config.md` |
| Routing ladder, ticket kind, TypeSafe judges | `docs/architecture/routing-and-kind.md` |
| Queue file format, frontmatter fields, dedup/heal | `docs/architecture/queue.md` |
| ntfy, listener acks, turn-completion hook | `docs/architecture/notifications.md` |
| Writing headless `claude -p` runs, launchd/TCC/auth, budgets, watchdogs | `docs/architecture/headless-runs.md` |
| Confined ticket implementation/investigation, read-only poll invariant | `docs/architecture/confined-runs.md` |
| gh / Slack shim / Jira / Slite / ntfy integration details | `docs/architecture/integrations.md` |
| Scripted collectors (Phase A/B), Slack relevance, bash/awk gotchas | `docs/architecture/deterministic-polling.md` |
| Scheduled jobs, `implement-next`, claims, trust checks | `docs/architecture/scheduled-jobs.md` |

## Core invariants

- **Polling reads; only `execute-item` writes.** Poll allowlists contain read verbs only; posting
  verbs live behind the gate. New source ⇒ add its read verbs (and read-only preflights) only.
- **`execute-item` is the single definition of approval** for both `review-queue` and remote
  `execute`. Exceptions: `qa-test-plan` is interactive-only; remote `ticket-investigation` runs the
  listener's confined read-only investigation. `ticket` is NOT an exception.
- **Sandbox shape is decided in bash before `claude` starts** (worktree, allowlist, budget, env).
  Never `Bash(*)`, `Bash(git *)`, `Bash(gh *)`, or `bypassPermissions` in confined runs. Pushes go
  only through `scripts/confined-push.sh`.
- **At most one queue item per `(type, source_id)`**; `{ticket, ticket-investigation}` is one
  family. Terminal state (`completed/`, `rejected/`) is absorbing for pollers. See
  `references/queue-reconciliation.md`.
- **Only `drafts/` is reachable by the approval gate.** Anything that finishes a draft must land it
  in `drafts/` (or it is invisible).
- **Routing/kind outputs are config-derived**; untrusted text is only ever the left side of a
  comparison. Judgment tiers (TypeSafe or model) can only narrow a config-derived candidate set.
- **TypeSafe egress is per-feature, deny-by-default** (`slack` scripted source,
  `typesafe.ticket_kind.enabled`, `typesafe.routing.enabled`). A failed judgment abstains/falls back
  to the model; it never becomes a silent "no".
- **Credentials never in `engineer.yaml`**: config names where the secret is; `lib-secret.sh`
  resolves (env → file → Keychain). Pass to curl via `--config -` (stdin), never argv.
- **Unattended `implement-next` needs `implement` + claim tier + trusted authorship**, checked from
  one fetch; the confined run gets no tracker access. The listener trusts
  `state/autopilot-items.tsv`, never frontmatter.
- **`cr-qa` (`job-slack-cr-qa.sh`) keeps every external write in bash** behind `slack-react`,
  `pr-comment`, `jira-comment`, `jira-transition` and `security-review`. QA scripts run only from
  bash, from a nonce-checked run spec; model runs get `--setting-sources user --strict-mcp-config`
  and a credential-free env, and see only trusted ticket text.
- **The AC guard only narrows review findings against trusted ticket text**: a finding is skipped
  only when a nonce-checked judge verdict quotes one whole requirement of trust-checked ticket text
  (`ac_guard_split`), and only if `medium`/`low`; the judge sees bash-trimmed findings
  (`ac_guard_input`). No text or a failed judgment keeps every finding.
- **`after_pr` (`pr-pipeline.sh`) keeps every external write in bash**: PR from the bash-recorded
  branch, checks, logs, `gh pr ready`, the security adapter, Slite note, PR/Jira comments, Jira transition and
  Slack announce are bash, each behind its own tier (`pr-ready`, `security-review`, `qa-publish`,
  `jira-transition`, `slack-post`). Fix, browser and QA runs get no `gh`/tracker/network verb and
  pass only by side effect (branch moved; nonce-bearing verdict or plan). QA never re-fetches the
  ticket; its tests are data, not shell; model text leaves only via `_neutral`.

## Conventions

- Read config from `~/.local/share/engineer-agent/engineer.yaml`; if missing, tell the user to run
  `/engineer-agent setup` and stop. Source `scripts/lib-paths.sh` for paths (`EA_AGENT_DIR`
  override); never hardcode.
- **Never put runtime data under `~/.claude/`** — the sensitive-path guard silently blocks
  Edit/Write headlessly.
- Reference plugin files via `${CLAUDE_PLUGIN_ROOT}`, never a bare relative path (cron runs from
  `$HOME`). `references/` is plain markdown, not a skill: the cron allowlist has `Read` but not
  `Skill`/`Agent`.
- Headless `claude -p` rules (details in `headless-runs.md`): pin `--permission-mode`; pass
  `--allowedTools` including read-only preflights (`gh auth status`, `gh --version`, Slack `auth`,
  `echo:*`); don't put `--allowedTools` last; use `Edit(//abs)` not `Write(path)`; `</dev/null`;
  export `USER`; forbid memory writes (`NO_MEMORY_RULE`); never trust the exit code — verify a side
  effect or a script-minted run-id receipt.
- Every unattended network read needs a timeout (`with_timeout`, curl `--max-time`, stream stall
  timeout). Judge liveness by an advancing timestamp, not "process is up".
- Hooks (`turn-notify-hook.sh`) always `exit 0`, never write stdout, keep jq optional, and strip
  URLs before pushing.
- Pushes from a linked worktree use `--no-verify`; from the human's checkout they don't.
- Cron path is jq-free (`gh --jq`); Jira/Slite/Slack collectors soft-require jq (exit 3 ⇒ model
  fallback). Portable bash/BSD awk only — see the gotchas list in `deterministic-polling.md`.
- LaunchAgent env changes need `bootout` + `bootstrap`, not `kickstart`.
- ntfy pushes: push once per condition, never every poll; auto-heals send no push.

## Tests

`bash tests/run-all.sh` runs every suite (no CI). Each suite is self-isolating: `set -uo pipefail`,
`PASS`/`FAIL` counters, an `mktemp -d` sandbox, `export EA_AGENT_DIR=…`, PATH shims for external
binaries (`gh`, `claude`, `curl`, `security`). Follow that shape.

## Documentation Maintenance

When a command, skill, config option, queue format or integration changes, update `README.md`, the
relevant `docs/architecture/*.md`, and this file if an invariant or convention changed. Keep them in
sync with each other and with actual behavior. Put new design rationale and incident history in
`docs/architecture/`, not here.
