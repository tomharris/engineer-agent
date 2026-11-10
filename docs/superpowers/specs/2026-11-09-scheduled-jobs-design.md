# Scheduled jobs: per-project, per-integration work on its own interval

**Date:** 2026-11-09
**Status:** Approved

## Problem

The poll runs every configured source of every project on one global interval, and it only ever
*discovers* work. Two things it cannot express:

1. **Different cadences per source.** A Slack mention wants minutes; a Slite review tag wants
   hours. Today both pay the same interval.
2. **Acting on a schedule.** "Every 30 minutes during work hours, take the next eligible ticket and
   implement it" has no home: polling is read-only by design, and starting an implementation always
   requires a human tap.

Slack is also discovery-only: nothing tracks threads engineer-agent has replied in, and nothing
signals progress back to the asker.

## Goals

- A `jobs` list per project: `(integration, action, every)` with its own state, lock, receipt,
  timeout and budget.
- **Sits alongside the existing poll.** No change to `cron-poll.sh`, `poll-*.sh`, or any existing
  config. An install with no `jobs` behaves exactly as before.
- Jira `implement-next`: select a ticket by config-defined **assignment rules** (assigned *or*
  unassigned), claim it, implement it in the existing confined sandbox.
- Slack `watch`: mentions, replies in threads engineer-agent participated in, and emoji reaction
  **status signals** (plus reaction **triggers**, later phase).

## Non-goals

- Replacing the global poll, or migrating existing installs.
- A general workflow engine. Two job types ship; the dispatcher is generic only in scheduling.
- Model-chosen targets. Every ticket key, channel, timestamp and emoji is decided in bash.

## Config

```yaml
projects:
  billing-api:
    jobs:
      - id: slack-watch                  # ^[a-z0-9-]+$, unique within the project
        integration: slack
        action: watch
        every: 5m                         # s|m|h; floor 1m
        hours: "8-18"                     # optional; local clock hours, inclusive start, exclusive end
        days: [mon, tue, wed, thu, fri]   # optional
        exclusive: false                  # true ⇒ global poll skips this (project, integration)
        watch: [mentions, my-threads]     # any of: mentions, my-threads, channels, reactions
        thread_ttl: 7d

      - id: jira-autopilot
        integration: jira
        action: implement-next
        every: 30m
        hours: "9-17"
        rules: [...]                      # see "Assignment rules"
        guards:
          max_in_flight: 1                # implementations running for THIS job
          daily_cap: 3                    # claims by this job per local calendar day
          pause_after_failures: 2         # consecutive failed runs ⇒ job paused
        budget_usd: 8.00                  # optional; default TICKET_BUDGET_USD

agent:
  autonomy:
    auto_execute: [draft-pr]              # existing; draft-pr = skip the gate between code and PR
    # new tiers, each deny-by-default:
    #   implement   — start implement-next without an approval tap
    #   jira-claim  — assign/transition the ticket without an approval tap
    #   slack-react — add/remove status reactions
  slack:
    reactions:                            # closed map: event → emoji name
      detected: eyes
      drafted: memo
      posted: white_check_mark
      rejected: no_entry_sign
      implementing: hammer_and_wrench
      pr_opened: rocket
    triggers:                             # phase 6
      - emoji: robot_face
        queue_as: slack-question          # slack-question | ticket
        allowed_reactors: [U012ABC]       # required; spy backend only (see Backends)
```

`ea-config.sh` normalizes `jobs` with the same flat-line output as the rest of the config;
`yaml_seq_len` / indexed sub-paths already handle a block sequence of mappings (`jira.sources`).

## Dispatcher

`scripts/jobs-tick.sh`, run by a new scheduler entry (`engineer-agent-jobs` LaunchAgent on macOS,
crontab on Linux) every 60s, installed by `scripts/install-jobs.sh` (mirrors `install-cron.sh`,
including `CLAUDE_BIN` capture and full bootout+bootstrap).

Each tick, in plain bash:

1. Parse `jobs` from config. No jobs ⇒ exit 0 (the tick costs one config read).
2. For each job: skip if paused, outside `hours`/`days`, or `now < last_run + every`.
3. Take `state/jobs/<project>.<id>.lock` (PID lock, stale-PID reclaim, as `cron-poll.sh`). Held ⇒
   skip this job, not the tick.
4. Run the job's handler **in the background** under `with_timeout`
   (`EA_JOB_MAX_SECONDS`, default 3600), so one hung job never delays another.
5. Handler writes `state/jobs/<project>.<id>.receipt` (run_id, started_at, finished_at, status
   `ok|partial|error|skipped`, items, errors) and updates `last_run`.

Scheduling is one tick + due-check rather than one LaunchAgent per job: per-job plists would
multiply the launchd env-cache trap (edit ⇒ bootout+bootstrap), the TCC re-grant on every `claude`
update, and the lockfile count, for no gain.

**Liveness.** Each receipt carries a dispatcher-minted run_id, same rule as the poll: success is a
side effect the script controls, never `claude`'s exit code. A job whose receipt is missing/stale
after its timeout gets one ntfy alert per failure streak.

**Circuit breaker.** `pause_after_failures` consecutive `error` receipts writes
`state/jobs/<project>.<id>.paused` and pushes one alert. Resume: `/engineer-agent jobs resume <id>`
(deletes the marker). A paused job is reported by `status`, never silently idle.

**Overlap with the global poll.** Items flow through `references/queue-reconciliation.md`, so the
`(type, source_id)` invariant dedups across both paths. `exclusive: true` additionally makes
`cron-poll.sh` skip that `(project, integration)` to avoid paying twice; this is the only change to
the existing poll, and it is a no-op unless set.

## Job: `jira` / `implement-next`

### Assignment rules

An ordered list; **first rule with an eligible ticket wins**, and within a rule the JQL `ORDER BY`
decides. One ticket per run.

```yaml
rules:
  - name: small-bugs
    jql: 'project = BILL AND type = Bug AND sprint in openSprints() AND assignee is EMPTY ORDER BY rank'
    require:
      assignee: empty               # empty | me | any
      issue_types: [Bug]
      priorities: [Highest, High, Medium]
      statuses: ["To Do"]
      max_story_points: 3           # tickets with no estimate fail this predicate
      components_any: [api]
      labels_any: []
      labels_none: [no-autopilot, needs-design, blocked]
      min_age: 2h                   # since created
      min_quiet: 30m                # since last updated (still being edited?)
      no_open_blockers: true        # no unresolved "is blocked by" links
      no_linked_pr: true            # no dev-panel PR / no branch already referencing the key
      has_acceptance_criteria: true # description contains an AC heading or checklist
      min_description_chars: 200
    ready_check: false              # optional TypeSafe judgment, see below
    claim:
      assign: self                  # self | none
      transition: "In Progress"     # optional
    on_fail:
      unassign: true                # only if this run assigned it
      transition: "To Do"           # optional

  - name: my-backlog
    jql: 'assignee = currentUser() AND status = "To Do" ORDER BY rank'
    require: { assignee: me }
    claim: { transition: "In Progress" }
```

- `jql` decides what is **fetched**; `require` is **re-checked in bash** against the fetched fields
  (`scripts/lib-assign-rules.sh`). JQL alone is not trusted as the decision: it is easy to write a
  query broader than intended, and the predicates are testable offline.
- Every rule's JQL is config-authored. Ticket text never contributes to selection; it is only the
  left side of `require` comparisons.
- A rule with no `require.assignee` defaults to `empty` **only if** its JQL contains
  `assignee is EMPTY`; otherwise `me`. `any` must be explicit, so a rule cannot take a ticket
  someone else already holds by accident.
- Story points field id is per-instance: `agent.jira.story_points_field` (e.g.
  `customfield_10016`). Unset + `max_story_points` set ⇒ config error, job refuses to run.

**`ready_check`** (optional): one TypeSafe yes/no — "is this ticket specified well enough to
implement without clarification?" — thresholded by `agent.typesafe.ready_check.min_ready` (default
0.70). Own opt-in `agent.typesafe.ready_check.enabled: true`, deny-by-default, same egress rule as
the other judgments (sends title + description, truncated). A failed judgment **skips the ticket**
this run; it never defaults to "ready". A not-ready verdict records the score in the job receipt so
a human can see why a ticket keeps being passed over.

### Run sequence

```
jobs-tick.sh → jobs/jira-implement-next.sh
  1. guards: in-flight < max_in_flight, claims today < daily_cap      else skipped
  2. for rule in rules: fetch (REST v2, lib-secret creds), filter by require, ready_check
  3. none eligible ⇒ receipt ok, items 0 (no model run)
  4. reconcile: existing non-terminal (ticket|ticket-investigation, source_id) ⇒ skip ticket
     (terminal stays absorbing — a completed ticket is never re-picked)
  5. write queue item to drafts/ as type ticket, autopilot: true, autopilot_rule: <name>
  6. if implement ∉ auto_execute ⇒ ntfy Approve/Reject push; stop. (Approve runs the normal
     listener path; claim happens there, step 7, before implementation.)
  7. claim (jira-claim.sh) — requires jira-claim ∈ auto_execute, else treated as step 6
  8. confined implementation (lib-confined-run.sh, below)
  9. success ⇒ completed/, ✅ push; failure ⇒ on_fail rollback, item stays in drafts/, ⚠️ push,
     failure counter++
```

Kind classification still applies: a ticket the kind ladder classifies as `ticket-investigation`
is **skipped** by `implement-next` (receipt notes it). Investigation autopilot is out of scope.

### Claiming: `scripts/jira-claim.sh`

Plain bash + curl, credentials via `--config -` on stdin (never argv), key from the Jira API
response, never from ticket text.

1. GET the issue; abort if `assignee` no longer satisfies the rule (race lost).
2. PUT assignee = self (accountId from `/myself`, cached in state).
3. POST transition, resolving the transition id by **name** from `/transitions`; a missing
   transition is a warning, not a failure (workflows differ).
4. GET again; if assignee ≠ self, abort and skip (someone else won the race).
5. Record `claimed_by_run: <run_id>` in the queue item so rollback only undoes **its own** claim.

Rollback (`jira-claim.sh release`) unassigns only if the current assignee is still self and the
item says this run claimed it; transitions back by name. Best-effort; a failed rollback is an
error in the receipt and an ntfy alert, so a ticket is never silently left claimed.

**Invariant change, stated explicitly:** "no collector may ever call a transition" remains true.
`jira-claim.sh` is not a collector; it runs after selection, only for a ticket the dispatcher is
about to implement, only under `jira-claim` autonomy or after a human Approve. CLAUDE.md gets a
paragraph saying so.

### Confined run: extract `scripts/lib-confined-run.sh`

The sandbox builder (worktree, `exec.allowed_commands` allowlist, budget, turn-notify env, QA
follow-on, teardown, queue-move reconcile) lives in `approval-listener.sh`'s
`run_ticket_implementation`. Extract it into a sourced library used by both the listener and the
job, so there is still one definition of what a headless ticket run may touch. No behavior change
for the listener; `tests/` pinning it must pass unmodified.

`max_in_flight` counts across **both** entry points via `state/implement-inflight/<item>` markers
(written before `claude` starts, removed on exit, stale-PID reclaim), so an Approve tap and a job
tick cannot run two implementations against one repo at once.

Deny-by-default is inherited: a project with no valid `exec.allowed_commands` cannot run
`implement-next` (the job refuses at config-parse time and reports it in `status`).

## Job: `slack` / `watch`

Scripted, same relevance judgment and composition as `poll-slack.sh` (`lib-typesafe.sh`), same
double opt-in. Sources, each selected by `watch`:

| Source | How | Notes |
|---|---|---|
| `mentions` | `<slack> search "<@USER_ID>" after:<date>` | both backends |
| `my-threads` | re-read each `(channel, thread_ts)` in `state/watched-threads.tsv` | new replies not from me ⇒ candidate; relevance still judged |
| `channels` | today's `poll-slack.sh` channel scan | for parity with the global poll |
| `reactions` | trigger emoji in `read` output | phase 6, spy only |

`watched-threads.tsv` (`channel\tthread_ts\tlast_seen_ts\tadded_at`) is appended by
`execute-item` after a successful Slack `send`, and pruned at `thread_ttl`. A reply in a watched
thread skips the `directed_at_user` threshold (being in the thread is the direction) but keeps
`is_question` / `already_answered` / `needs_engineer`.

### Reactions: status signals

`scripts/slack-react.sh <event> <channel> <ts>` maps the event through `agent.slack.reactions` and
calls the effective Slack binary's `react` / `unreact` verb. The model never chooses an emoji, a
channel or a timestamp: all three come from the queue item's frontmatter (`channel_id`,
`message_ts`) written by the collector.

| Event | Fired by | Replaces |
|---|---|---|
| `detected` | collector, on create | — |
| `drafted` | Phase B / job, on move to drafts/ | `detected` |
| `posted` | `execute-item` after `send` | `drafted` |
| `rejected` | `execute-item` reject | `drafted` |
| `implementing` / `pr_opened` | ticket items with a Slack origin | previous |

- Requires `slack-react` ∈ `auto_execute`. Absent ⇒ no reactions anywhere.
- Unmapped event ⇒ nothing. Emoji names validated `^[a-z0-9_+-]+$`.
- Best-effort and fail-open: a failed reaction is logged and never fails the step that fired it.
- **Invariant change, stated explicitly:** `detected` is a write from a polling path. It is
  permitted because the alphabet is a config-closed map and the target is the message just read;
  CLAUDE.md's "polling reads" section gets this as a named, single exception.

### Reactions: triggers (phase 6)

A message carrying a configured trigger emoji from an `allowed_reactors` user is queued as
`queue_as`, bypassing the relevance judgment (a human already decided). `allowed_reactors` is
required and non-empty, or the trigger is rejected at config parse — otherwise anyone in the
channel can queue work. Requires reaction user ids in `read` output, which only spy can provide.

## Backend changes

| Change | spy | mcp-proxy shim |
|---|---|---|
| `react <ch> <ts> <emoji>` | exists (`cmd/spy/react.go`, `reactions.add`) | add subcommand mapping to the connector's add-reaction tool (`EA_SLACK_TOOL_REACT`) |
| `unreact <ch> <ts> <emoji>` | add command; `reactions.remove` already in `internal/slack/methods.go` | add subcommand mapping to the connector's remove-reaction tool (`EA_SLACK_TOOL_UNREACT`) |
| `search <query> [count]` | exists | add subcommand mapping to the connector's search tool (`EA_SLACK_TOOL_SEARCH`); result is a text blob, parsed like `read` |
| reactions in `read`/`thread` JSON | add `reactions: [{name, count, users[]}]` | can emit `{name, count}` only — connector omits users; stop discarding the `Reactions:` line at `slack-mcp.sh:251` |

A verb the backend lacks exits `64` (unsupported) from the shim; callers treat it as "feature
unavailable on this backend" and log once per run, never retry.

## Allowlists

The scripted job paths run no model until the confined implementation, so their read-only
guarantee is structural in bash. The confined run's allowlist is exactly the listener's today
(shared via `lib-confined-run.sh`). Phase B drafting for Slack candidates reuses `cron-poll.sh`'s
read-only allowlist. No new MCP verbs are granted anywhere; Jira writes happen only in
`jira-claim.sh` (REST, bash).

## Observability

- `/engineer-agent status`: a jobs section — id, project, next due, last receipt status, paused,
  in-flight, claims today.
- `/engineer-agent jobs list|run <id>|pause <id>|resume <id>` — `run` forces a due job now
  (interactive testing, ignores `every` but not guards).
- Queue items carry `autopilot: true`, `autopilot_rule`, `autopilot_job` so `review-queue` shows
  why a ticket was picked.

## Testing

Same shape as existing suites (`tests/run-all.sh`, mktemp sandbox, PATH shims for `curl`, `spy`,
`claude`, frozen clock via `EA_NOW`).

- `jobs-tick.test.sh`: due/not-due at the boundary, `hours`/`days` windows, lock held ⇒ that job
  skipped and others run, paused marker honored, receipt written with the minted run_id, a hung
  handler killed at timeout with an error receipt.
- `assign-rules.test.sh`: each `require` predicate in both directions; first-match ordering;
  `assignee` default inference; missing story points fails `max_story_points`; unset field id is a
  config error.
- `jira-claim.test.sh`: race lost before claim, race lost after claim, transition missing by name,
  rollback only when `claimed_by_run` matches, secret never in argv.
- `implement-next.test.sh`: guards (`max_in_flight` across listener + job, `daily_cap` at local
  midnight), terminal item never re-picked, investigation-kind skipped, `implement` absent ⇒ push
  and no claim, failure streak ⇒ paused.
- `slack-react.test.sh`: closed map, unmapped event ⇒ no call, swap removes the previous emoji,
  tier absent ⇒ no call, backend exit 64 ⇒ logged once.
- `slack-watch.test.sh`: watched-thread reply from someone else queued, own reply ignored, TTL
  prune, mentions found via `search` on both backends (stubbed spy and shim).
- Existing listener suites pass unchanged after the `lib-confined-run.sh` extraction.

## Phasing

1. **Built.** Dispatcher, per-job state/receipts/locks/breaker, `install-jobs.sh`, `status` section,
   `exclusive` skip in `cron-poll.sh`. Slack `channels` watch as the first handler (parity).
2. **Built.** `lib-assign-rules.sh` + tests (no writes), plus read-only `jobs-ctl.sh preview`.
3. `jira-claim.sh` + `jira-claim` tier.
4. `lib-confined-run.sh` extraction, then `implement-next` + `implement` tier.
5. spy `unreact`; shim `react`/`unreact`/`search`; `slack-react.sh` +
   `slack-react` tier; `watched-threads.tsv` + `my-threads`; `mentions`.
6. Reaction triggers (spy: reactions in `read` output).
7. `ready_check`.

## Decisions

- **Slack connector:** exposes reaction add/remove and search tools, so phase 5 covers both
  backends. Exact tool names are pinned from `slack-mcp.sh list-tools` at implementation time and
  overridable via `EA_SLACK_TOOL_*`, like the existing three.
- **`daily_cap`:** per job. Two jobs in one project each get their own cap.
- **Failed implementation:** no Jira comment. A comment is append-only with no idempotent retry
  (see "Confined headless ticket investigation"); the rollback plus the ntfy push are the signal.
- **`hours` / `days` / `daily_cap` day boundary:** machine local timezone. No `agent.timezone`.
