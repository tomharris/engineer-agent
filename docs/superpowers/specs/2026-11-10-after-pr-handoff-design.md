# after_pr handoff: security review, QA, publish, transition, announce

Extends `scripts/pr-pipeline.sh` (scheduled-jobs phase 6b) so an unattended `implement-next` pick
goes all the way to "in code review, announced", with no human tap. User decision (2026-11-10):
fully unattended, each write behind its own `auto_execute` tier.

## Target workflow

| # | Step | Where |
|---|---|---|
| 1 | Next unblocked "To Do" ticket in an epic, unassigned or mine | config: two `rules` (mine first), `no_open_blockers` |
| 2 | Assign to me, move to In Progress | config: `claim` (exists) |
| 3–4 | Implement, commit, push, draft PR | exists (confined run) |
| 5 | CI wait + fix | exists (`after_pr.ci`) |
| 6 | Security review (pluggable adapter) | **new** `after_pr.security` |
| 7–8 | QA plan, auto-approved, manual items skipped | **new** `after_pr.qa` |
| 9 | QA summary comment on PR + Jira, with Slite link | **new** `after_pr.qa` publish |
| 10 | Mark ready | exists (`mark_ready`, `pr-ready`) |
| 11 | Move ticket to Code Review | **new** `after_pr.transition` |
| 12 | `CR+QA: <PR urls> <ticket url>` to a team channel | **new** `after_pr.announce` |

Order: security (+ fix) → CI (+ fix) → browser (if configured) → QA (+ publish) → ready →
transition → announce.
Any stage failing stops the pipeline with one urgent push; earlier side effects stay (no undo).
A stage whose tier is missing is skipped with one push naming the tier, and the pipeline stops
before `ready` — skipping a review stage must not let a PR reach reviewers unreviewed. Later
stages (transition, announce) with a missing tier are skipped and the pipeline still ends `ready`.

## Config

```yaml
after_pr:
  security:                    # tier security-review
    command: ~/bin/pr-security-review   # adapter: <cmd> <owner/repo> <pr> <outdir>
    fix_attempts: 1            # 0-3 fix + re-review rounds for findings the PR introduced
    timeout: 30m               # per review
  qa:                          # tier qa-publish
    document: true             # Slite note under projects.<slug>.qa.document_parent; comment links it
  transition: "Code Review"    # tier jira-transition; jira jobs only
  announce:                    # tier slack-post
    channel: C0123456789       # must be one of projects.<slug>.slack.channels
```

Validation (`jobs_validate_after_pr`): unknown keys are errors at every level; `security.command` required, absolute or `~/`;
`security.fix_attempts` 0–3; `transition` only on `jira` integration;
`announce.channel` ∈ the project's `slack.channels`; `qa.document: true` needs
`projects.<slug>.qa.document_to: slite` and `document_parent`.

## Stages

**security** — bash runs the user-supplied adapter `security.command <owner/repo> <pr> <outdir>`
(stdin closed, output to `<outdir>/run.log`). The plugin ships no reviewer: the adapter wraps
whatever security review tool the team uses. Contract: write `<outdir>/report.md` and
`<outdir>/findings.json`, a JSON array of `{title, severity, file, cwe?, impact?, evidence?,
remediation?, introduced?}` (`file` may carry `:line` or `#Lnn`). Exit 0 done, 3 authentication
required, other = error. Each review is bounded by `security.timeout` via `with_timeout`.

User decision: **every finding introduced by the PR is addressed, whatever its severity; all
others are skipped.** Classification, in bash:
- its `file` (minus `./`, `:line`, `#Lnn`) is in `git diff --name-only origin/<base>...<head>` ⇒
  introduced, whatever the adapter says (fail closed: reviewer output is model text that read the
  diff, so it must not be able to talk a finding out of the fix run);
- `introduced: true` ⇒ introduced, even outside the diff;
- anything else ⇒ skipped, listed in the QA/PR
  comment as "pre-existing, skipped".

Introduced findings ⇒ a confined **security fix run** (the CI fix run's sandbox: worktree on the
branch, build rules, git write, `confined-push.sh`) with the introduced findings written to
`$D/security/introduced.md` (title, severity, file, evidence, remediation, CWE). It must fix the
code and add a regression test where the finding's remediation names one; it may not suppress,
weaken tests, or edit CI. Success = remote branch moved. Then the review runs again on the new head.
Up to `security.fix_attempts` (default 1, 0–3) fix+re-review rounds; introduced findings left
after the last round ⇒ stop (PR stays draft), push lists their titles and the report path.

Placement: security runs **before** the CI loop, so a security fix commit goes through the same
CI wait/fix as the implementation (one CI pass instead of two). This differs from the user's
listed order (CI, then security review) only in sequencing; both gate `ready`.

**qa** — one confined model run, the browser run's shape: `Read Glob Grep` + git read rules +
`Edit(//$D/qa/plan.md)`, no gh, no Jira, no network verb. Inputs: the completed queue item (the
trust-checked text — never re-fetched) and `git diff origin/<base>...HEAD`. It writes `plan.md`
with fixed sections `## Summary`, `## Scripted Tests` (one bash block), `## Manual Checklist`.
Success = `plan.md` exists with all three headings and ends with `QA-NONCE: <nonce>` minted by
bash. Manual items are recorded "skipped (unattended)". If `after_pr.browser` is configured, bash
runs the scripted block against the already-validated localhost server before teardown, with
`BASE_URL` set, under `with_timeout 600`; else "not executed — no local server". Running a
model-written script unconfined is the same accepted residual as `browser.serve`, under the same
trust gate.

**publish** (part of qa) — bash only:
1. Slite: `POST /notes {title, parentNoteId, markdown}` via the shared `slite_api` (credential on
   stdin). Title `QA Plan: <KEY> (<branch>)`. Body: header (ticket URL, PR URL, branch, time),
   plan, test output.
2. Comment text, composed by bash: `QA summary for <KEY>` + the model's `## Summary` (stripped of
   URLs, capped at 2000 chars) + `Automated: <P> passed, <F> failed` or the not-executed reason +
   `Manual checks: <N> skipped (unattended)` + `Full plan: <slite url>`.
3. `gh pr comment <pr> --repo <repo> --body-file`, and for jira: `POST /issue/<KEY>/comment`
   (`agent.jira.api_base`, default v2, plain body).
Each write's success is the HTTP status / gh exit; a failure stops.

**transition** — `jira_transition_by_name <KEY> <name>` (moved from `jira-claim.sh` into
`lib-jira-api.sh`): resolve by target status, then transition name. Missing transition ⇒ warning
push, not a stop (workflows differ, as with claim).

**announce** — text is bash-built, never model text:
`CR+QA: <pr urls space-separated> <ticket url>`. PR urls: the pipeline PR first, then every other
open PR in the project's `github.repos` whose title or head branch contains the key
(case-insensitive, key bounded by non-alphanumerics), deduped. Ticket url:
`https://<agent.jira.site>/browse/<KEY>` (jira) or `https://github.com/<owner>/<repo>/issues/<n>`.
Sent with the Slack backend `slack-event.sh` uses (`ea_slack_bin`), `send <channel> <text>`;
exit 0 required.

## Invariants touched

- "Do not start QA from an unattended run" becomes "QA in an unattended run is the pipeline's
  confined QA run over the already-checked queue item; it never re-fetches the ticket and gets no
  tracker or gh verb". Update `confined-runs.md`, `scheduled-jobs.md`, CLAUDE.md.
- `pr-pipeline.sh` now writes Jira (comment, transition), Slite and Slack. All are bash, all
  config-derived targets, all tiered. Model text reaches the outside only as the URL-stripped,
  capped QA summary.
- New tiers: `security-review`, `qa-publish`, `jira-transition`, `slack-post`.

## Out of scope

Reviewer authentication; undoing published comments on a later failure; GitHub-issue
comments for `github-issues` jobs (PR comment only).
