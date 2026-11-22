# Retire the global poll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every discovery path the global poll (`cron-poll.sh`) owns runs as a per-project scheduled job, so `install-cron.sh` / `cron-poll.sh` can be deleted with no feature loss beyond the rulings below.

**Architecture:** One generic `<integration>:watch` handler (`scripts/job-watch.sh`) wraps the existing Phase A collectors with `--project` and a per-job state file, exactly as `job-slack-watch.sh` does today. `jobs-draft.sh` stays the only drafting path. Queue hygiene (heal, dedup) moves into `jobs-tick.sh`. `status`, `add-ticket` and `add-project` read/write job state instead of `last-poll.yaml`. Removal happens last, behind a migration that converts the global poll's config into jobs.

**Tech Stack:** bash (3.2-portable), BSD/GNU awk, `gh --jq`, curl + jq (Jira/Slite/Slack collectors), `claude -p` (drafting only).

## Rulings (decided here; flag if wrong)

- **No model-driven discovery.** Jobs require the scripted collector. `jobs_validate` rejects a `watch` job whose collector's dependencies are missing (jq, credential, `agent.jira.site`, TypeSafe for Slack) with a reason shown in `/engineer-agent status`. Cost: Slack without TypeSafe, and any install without jq, loses Slack/Jira/Slite discovery. The `poll-*` skills become manual-only (`/engineer-agent poll`) and are no longer part of any headless run.
- **Per-project collection, accept the repeated fetches.** Each project's job runs its collector with `--project`. A source shared by N projects is fetched N times. `_unrouted` items still form: `--project` keeps unrouted hits (already true in all five collectors), and `queue_disposition` coalesces them by `(type, source_id)`. Slite's "every project uses `needs-review`" case becomes N searches producing one `_unrouted` item. If the API cost matters later, add a short-TTL per-source fetch cache in a follow-up; it is not part of this plan.
- **`/engineer-agent poll` stays** as the interactive, manual path. It just stops being scheduled.

## Global Constraints

- Polling reads; only `execute-item` writes. `job-watch.sh` gets no write verb; drafting keeps `lib-poll-allowlist.sh`.
- Every unattended network read has a timeout (collectors already use `with_timeout` / `--max-time`; keep it).
- Portable bash 3.2 / BSD awk; see `docs/architecture/deterministic-polling.md` gotchas.
- ntfy: push once per condition, never every tick.
- Tests follow the suite shape in `CLAUDE.md`. `bash tests/run-all.sh` green at every commit.

## Review Focus

1. Two jobs for different projects draft concurrently: no queue file is edited by two models (Task 3).
2. A stranded `incoming/` item is re-emitted by exactly one job, the one that owns its project, or, for `_unrouted`, exactly one designated job (Task 3).
3. A manually added ticket is not re-queued by the job that owns its source (Task 6).
4. Heal/dedup run at most once per tick under contention and push at most once per unchanged condition (Task 4).
5. Migration produces jobs equivalent to the old poll's coverage and is idempotent (Task 7).

---

## Task 1: Generic `watch` handler for the four unscripted-by-jobs sources

**Files:** create `scripts/job-watch.sh`; modify `scripts/ea-config.sh` (`JOBS_SUPPORTED`, `_job_source`), `scripts/lib-jobs.sh` (`jobs_validate`), `scripts/jobs-tick.sh` (`job_body`); test `tests/jobs.test.sh`.

- [x] Add `github:watch` (PR reviews), `github-issues:watch`, `jira:watch`, `slite:watch` to `JOBS_SUPPORTED`. Map `github` → `github` in `_job_source` (receipt name for PR review).
- [x] `job-watch.sh --integration <i> --project <slug> --job <key> --manifest <f> --errors <f> --run-ts <iso>`: resolves `poll-github-prs.sh` / `poll-github-issues.sh` / `poll-jira.sh` / `poll-slite.sh`, runs it with `EA_POLL_STATE_FILE=state/jobs/<key>.state.yaml`, `EA_JOBS_IGNORE_EXCLUSIVE=1`, `EA_PHASE_A_ERRORS=<errors>`, `--project`. Passes the collector's exit code through.
- [x] Fold `slack:watch` into the same handler (keep `job-slack-watch.sh` as a thin wrapper, or delete it and move `--sources` / `--thread-ttl` handling in). One code path.
- [x] `jobs_validate`: `github-issues:watch` / `jira:watch` only when the project's `tracker` resolves to that integration; `github:watch` needs `projects.<slug>.github`; `slite:watch` needs `projects.<slug>.slite`. (Done differently: the dependency preflight runs per job run and in `jobs-ctl list`, not in `jobs_validate`; see Task 2.)
- [x] `job_body`: dispatch the new kinds to `job-watch.sh`; generalise the `slack:watch:3` error text to `<kind>:3` using the collector's `--check` reason.
- [x] Tests (red first): each new kind runs its collector with `--project` and the per-job state path (PATH-shimmed `gh`/`curl`, assert the queue file and state file written); a `jira:watch` job on a `github-issues` tracker project is invalid with an exact reason; a collector exiting 3 yields receipt `status: error` with the `--check` reason.

## Task 2: Collector `--check` (dependency preflight)

**Files:** modify `scripts/poll-{github-prs,github-issues,jira,slite,slack}.sh`; tests in each `tests/poll-*.test.sh`.

- [x] `--check` prints nothing and exits 0 when the collector could run, or prints one reason line and exits 3 (no jq / no credential / no `agent.jira.site` / no TypeSafe). No network.
- [x] Reuse the existing exit-3 branches. Don't duplicate the conditions.
- [x] `job-watch.sh` runs `--check` first and records `collector unavailable: <reason>` in the run's errors; `jobs-ctl list` shows `unavailable: <reason>`. Not in `jobs_validate`: credential resolution (Keychain on macOS) per job per tick costs too much.
- [x] Tests: one per exit-3 cause per collector, asserting the exact reason; `gh` collectors always exit 0 when `gh` is on PATH.

## Task 3: Safe concurrent drafting and project-scoped resume sweep

**Files:** modify `scripts/lib-queue.sh` (`poll_resume_candidates`), `scripts/poll-*.sh` (resume phase), `scripts/jobs-draft.sh`; tests `tests/queue-ops.test.sh`, `tests/jobs.test.sh`.

The resume sweep emits every undrafted `incoming/` item regardless of project or type. Today only the global poll and one Slack job run it. With N jobs, N manifests would claim the same stranded file.

- [x] `poll_resume_candidates [--project <slug>] [--type <t>]`: filter by frontmatter. Under `--project`, collectors pass their project and their own item types (`pr-review`; `ticket`+`ticket-investigation`; `doc-review`; `slack-question`).
- [x] `_unrouted` stranded items: re-emitted only by the job whose key sorts first among jobs of that integration (deterministic owner, computed from `jobs_enumerate`). Otherwise they would be re-emitted by every project's job or by none.
- [x] Rename the lock `jobs-draft.sh` takes from `state/cron-poll.lock` to `state/drafting.lock` (one drafter at a time, across all jobs). Keep exit 4 (deferred) semantics. Until Task 8, `cron-poll.sh` takes the same new lock.
- [x] Tests: two projects' stranded items, each job's manifest has only its own; one `_unrouted` stranded item appears in exactly one job's manifest; held `drafting.lock` makes `jobs-draft.sh` exit 4 with items left in `incoming/`.

## Task 4: Queue hygiene in the tick

**Files:** create `scripts/queue-hygiene.sh`; modify `scripts/jobs-tick.sh`, `scripts/cron-poll.sh` (call the new script, delete the inline copy); test `tests/queue-dedup.test.sh` or new `tests/queue-hygiene.test.sh`.

- [x] Move `cron-poll.sh`'s post-run block into `queue-hygiene.sh`: `queue-heal-stranded.sh --heal`, `queue-dedup-check.sh --heal`, and the "duplicates unchanged since last push" ntfy suppression (state file stays the same path).
- [x] `jobs-tick.sh` runs it after dispatch, detached, at most every `EA_HYGIENE_EVERY` (default `15m`, tracked in `state/jobs/_hygiene.last-run`), under `drafting.lock` (skip if held: a draft in progress would race the heal).
- [x] Tests: a stranded drafted `incoming/` item moves to `drafts/` after one tick; a duplicate pushes once across two ticks with an unchanged dup set and again when it changes; a held `drafting.lock` skips hygiene without updating `last-run`.

## Task 5: Status reads job state

**Files:** modify `scripts/queue-status.sh`, `commands/status.md`; test `tests/queue-ops.test.sh` (or the status suite).

- [ ] Per project × source, "last checked" = the newest `last_checked` across that source's job state files (`state/jobs/*.state.yaml`) and receipts. Show the owning job key.
- [ ] Replace the single poll-receipt health line with an aggregate: count of jobs `ok`/`partial`/`error`/`paused`/`invalid`, listing the non-ok ones with their first error.
- [ ] Flag **uncovered sources**: a configured project source with no valid `watch` job. Without the global poll this is now silent loss, so make it visible.
- [ ] Keep reading `last-poll.yaml` / `last-poll-receipt.yaml` while they exist (until Task 8), labelled "global poll (legacy)".
- [ ] Tests: uncovered source listed; paused job listed with its error; newest timestamp wins across two jobs of one source.

## Task 6: `add-ticket` / `add-project` stop writing `last-poll.yaml`

**Files:** modify `commands/add-ticket.md`, `commands/add-project.md`; add `scripts/state-seed.sh`; test `tests/state-seed.test.sh`.

- [ ] Verify first: does queue reconciliation alone stop a manually added ticket from being re-queued? (`queue_disposition` returns `unchanged`/`skip` for any existing item in a non-terminal or terminal dir.) If yes, delete add-ticket step 8 and add a regression test proving a `jira:watch` run over the same key produces no new file. If no, continue below.
- [ ] `state-seed.sh seen --project <slug> --source <src> --id <source_id>`: appends to every job state file owning that project/source (via `state_list_add`), creating the job state file if missing. `add-ticket` calls it instead of editing YAML by hand (deterministic, no model-authored state).
- [ ] `add-project`: drop the `last-poll.yaml` seeding step. Instead offer to append default `watch` jobs for each configured source (Task 7's generator for one project).
- [ ] Tests: seeded id is skipped by the next job run; seeding with no job configured creates no stray file and exits 0 with a message.

## Task 7: Migration from global poll to jobs

**Files:** create `scripts/migrate-poll-to-jobs.sh`; modify `commands/setup.md`, `config/engineer.example.yaml`; test `tests/migrate-poll-to-jobs.test.sh`.

- [ ] For each project and each configured source with no existing `watch` job, emit a job: `id: <source>-watch`, `integration`, `action: watch`, `every` = the old poll interval (read from the installed launchd plist / crontab, else `15m`), and `hours` copied from `EA_POLL_HOURS` when it was a contiguous range.
- [ ] Seed each new job's state file from `last-poll.yaml` (copy that project/source subtree) so the first job run does not re-discover the whole backlog.
- [ ] Dry run by default (prints the YAML diff); `--apply` writes `engineer.yaml` (backup first) and the state files. Idempotent.
- [ ] Remove `exclusive:` from migrated config and from `config/engineer.example.yaml` (meaningless once there is no poll to exclude).
- [ ] `setup`: install `install-jobs.sh` instead of `install-cron.sh`; offer the migration when a poll is installed.
- [ ] Tests: two-project config produces exactly the expected jobs; a project already having `slack:watch` gets no duplicate; state subtree copied; second `--apply` is a no-op.

## Task 8: Remove the global poll

**Files:** delete `scripts/cron-poll.sh`, `scripts/install-cron.sh`, `tests/cron-poll-scripted.test.sh`; modify `scripts/ea-config.sh` (drop `_exclusive_owner`, `EA_JOBS_IGNORE_EXCLUSIVE`), `scripts/job-*.sh` (drop `EA_JOBS_IGNORE_EXCLUSIVE`), `scripts/queue-status.sh` (drop legacy branch), `scripts/claude-bin` preflight users (`approval-listener.sh` comment re: shared record), `references/routing-ladder.md`, `references/ticket-kind.md` (the "cron-poll allowlists `Read` but not `Skill`" rationale now refers to `jobs-draft.sh`).

- [ ] `install-cron.sh --uninstall` logic moves into `migrate-poll-to-jobs.sh --apply` (bootout + remove plist / crontab line) so existing installs are cleaned up.
- [ ] Port any `cron-poll-scripted.test.sh` cases still meaningful (scripted-note, skip-model-when-empty) to `jobs.test.sh` before deleting; delete the rest.
- [ ] `grep -rn "cron-poll\|last-poll\|install-cron\|exclusive" scripts commands skills references tests` is empty apart from intentional history notes.

## Task 9: Docs

- [ ] `README.md`: replace the polling/install-cron section with jobs as the only scheduler; document the rulings (no model fallback, per-project fetch cost).
- [ ] `docs/architecture/scheduled-jobs.md`: `watch` for all sources, drafting lock, project-scoped resume sweep, hygiene cadence.
- [ ] `docs/architecture/deterministic-polling.md`, `overview.md`, `headless-runs.md`, `notifications.md`, `queue.md`, `integrations.md`: remove/redirect global-poll references.
- [ ] `CLAUDE.md`: core invariant "Polling reads" now names `jobs-draft.sh` / `job-watch.sh`; remove `cron-poll` mentions in conventions; update the jq note ("Cron path is jq-free" applies only to the GitHub collectors).
- [ ] Bump plugin version (`.claude-plugin/plugin.json`, marketplace).

## Order and checkpoints

Tasks 1–3 make jobs a complete replacement while the poll still runs (safe to ship; both paths dedup by `(type, source_id)`). Task 4 removes the poll's last unique duty. Tasks 5–7 make the switch visible and automatic. Task 8 is the only destructive step. Run it after at least a few days of jobs-only operation with `status` showing no uncovered sources.
