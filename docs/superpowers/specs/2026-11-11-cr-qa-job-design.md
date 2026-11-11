# cr-qa job: review and QA a PR on a Slack request

## Intent

Teammates ask for review by posting a request in a team channel, e.g.

```
CR/QA request for: <https://github.com/acme/web/pull/253> - <https://acme.atlassian.net/browse/ENG-495>
```

A reviewer claims it with 👀, reviews the PR (code review, the PR against the ticket's acceptance
criteria, a security review), then QAs it: follows the ticket's written QA steps, downloads the QA
script attached to the ticket and runs it on the PR branch. If everything passes the reviewer
reacts `:approve:`, comments a QA summary on the ticket, and moves it on.

This job does that unattended for each configured project. It is the counterpart of `after_pr`:
`after_pr` announces "CR+QA: …" for our own PRs; `cr-qa` picks up other people's "CR/QA" requests.

## Goals

- Pick up each eligible request once, act on it end to end, and leave a visible outcome in Slack,
  on the PR or on the ticket.
- Stop at the first failing gate with one comment saying why.
- Run a teammate's QA script only when a trusted person wrote both the request and the script.

## Non-goals

- Fixing what it finds. It reports; it never pushes to the PR branch.
- Approving the PR on GitHub, or merging.
- Requests for repos other than the project's own.

## Anti-goals (failure even if it "works")

- Executing a script or following instructions that an untrusted person could have planted
  (in Slack, the ticket, or an attachment).
- Approving when a gate did not actually run (no script executed, review produced nothing,
  adapter errored). Absence of evidence is a stop, never a pass.
- Re-processing the same request, or two projects both taking it.
- Anything vendor- or employer-specific in this repo; the security reviewer stays behind the
  existing pluggable `security.command` adapter.

## Workflow

Per project, a scheduled job `integration: slack`, `action: cr-qa`:

1. **Find.** Read the job's channel. A message is eligible when all hold:
   - its text starts with the trigger prefix (default `CR/QA`, after trimming whitespace);
   - it has no claim reaction (default `eyes`);
   - its poster's Slack user id is in the job's `trusted_slack_users`;
   - it contains exactly one GitHub PR URL and one Jira browse URL;
   - the PR's `owner/repo` is one of the project's repos (`gr_project_repos`). Different repo ⇒
     skip silently and do **not** react — another project's job owns it;
   - its ts is not already in this job's local ledger (`state/jobs/<key>.requests.tsv`).
   Oldest first; one request per run (`max_in_flight: 1`).
2. **Claim.** Bash writes the ledger row (`claimed`) first, then adds the claim reaction. The
   ledger is the dedup key (the connector's add-reaction succeeds even if the emoji is already
   there, and reactions don't say who added them); the reaction is the human-visible signal, and
   any 👀 already present means someone else has it. If adding the reaction fails, the ledger row
   becomes `error` and nothing else happens.
3. **Review** (stop gate 1), in a fresh worktree of the PR head:
   - Code review + AC check: a confined, read-only model run over the worktree, the diff, and the
     ticket's ACs (as data). It must write a nonce-bearing findings file:
     JSON array of `{title, severity: critical|high|medium|low, file?, detail}`. An AC the change
     does not meet is a finding of severity `high`. It should use the built-in `/code-review`
     skill if that runs headlessly under a read-only allowlist; otherwise the plugin's own
     `review-pr` instructions.
   - Security review: the existing `security.command` adapter contract
     (`<owner/repo> <pr> <outdir>` → `findings.json`, exit 0/3/other), unchanged. Only findings
     the PR introduced count, by `pr-pipeline.sh`'s fail-closed `security_introduced` rule.
   - Severity is compared case-insensitively; a missing or unrecognised severity counts as
     `high` (fail closed).
   - Any counted finding with severity `medium` or higher, from either review ⇒ bash posts **one PR
     comment** listing those findings (title, severity, file, one-line detail; model text passed
     through `_neutral`) and stops.
   - Either review failing to produce its file, an adapter exit ≠ 0, or an unreadable file ⇒ stop
     with a PR comment saying the review could not complete (not a pass).
4. **QA** (stop gate 2):
   - Bash fetches the ticket over Jira REST: description, comments, attachments, changelog. The
     ACs live in the description. The ticket is untrusted unless `implement-next`'s authorship
     check passes (reporter, and every description edit in the changelog, by `trusted_authors`);
     an untrusted ticket ⇒ stop with a ticket comment, before **both** the review's AC check and
     QA see its text. Comments count as QA procedure only when authored by `trusted_authors`;
     others are dropped before the model sees anything. (The fetch happens before step 3.)
   - Bash downloads every attachment that is a QA script (`*.py`, `*.sh`; name or MIME) **whose
     uploader is in `trusted_authors`** via the Jira attachment content API with curl
     (credential via `lib-secret.sh`, `--config -`). No browser needed.
   - A confined model run in a fresh worktree of the PR head follows the written QA steps and
     verifies each AC. Its allowlist: read the worktree; the project's `exec.allowed_commands`;
     and `qa-exec.sh` (below). No `gh`, tracker, Slack, `git push`, or network verbs.
   - QA runs locally: scripts start what they need themselves (e.g. a local dev server) and may
     reach the network (package installs). No credentials are passed into the run's env. If the
     project has after_pr `browser`/`serve` config, the run may reuse it for written steps that
     need the app; otherwise steps needing staging or a human ⇒ that AC is `fail`, and the
     verdict says why.
   - **Scripts run only through `scripts/qa-exec.sh <script> [args…]`**: it copies the script
     to the location the steps say (default: worktree root), runs it with a timeout, and appends
     `<script>\t<exit>` to a bash-owned log the model cannot write. The run's verdict file
     (nonce-bearing) lists per-AC pass/fail and a summary.
   - Pass requires: every downloaded script appears in the bash log with exit 0, the verdict file
     is valid, and every AC is `pass`. With **no** attached script, pass requires the written
     steps and every AC verified (`pass`), with the run's command evidence in the verdict.
   - Fail ⇒ bash posts **one ticket comment** (what failed: script name + exit + tail of its
     output, or the failing ACs) and stops.
5. **Approve.** Bash, in order: posts a QA summary comment on the ticket (PR URL, script results
   e.g. "ENG-495-qa.py: exit 0", per-AC result, review finding counts below medium); adds the
   approve reaction (default `approve`); transitions the ticket to the job's `transition`.

Every external write is bash, each behind its own autonomy tier: `slack-react` (claim and
approve reactions, reusing the existing tier), `pr-comment` and `jira-comment` (new),
`jira-transition`, `security-review`. Tiers are checked at run time before the claim, as
`implement-next` does; a missing tier ⇒ the run ends `error` without claiming.

## Config

```yaml
projects:
  web:
    path: ~/repos/web
    exec:
      allowed_commands: [make, uv]
    jobs:
      - id: cr-qa
        integration: slack
        action: cr-qa
        every: 5m
        days: [mon, tue, wed, thu, fri]
        channel: C0123456789
        exclusive: true                          # the global poll skips this project's Slack source
        trusted_slack_users: [U04ABCDEF]
        trusted_authors: ["5b10ac8d82e05b22cc7d4ef5"]            # Jira account ids (ticket text + attachments)
        trigger_prefix: "CR/QA"                  # default
        reactions: { claim: eyes, approve: approve }   # defaults
        transition: "Ready for Upload"
        security:
          command: ~/.local/share/engineer-agent/adapters/security-review/review.sh
          timeout: 30m
        qa:
          timeout: 30m                           # per script
        guards: { max_in_flight: 1, daily_cap: 10, pause_after_failures: 2 }
```

Validation (in `lib-jobs.sh`, same style as `implement-next`): channel, `trusted_slack_users`,
`trusted_authors`, `transition` required; `security.command` absolute or `~/`; project must have `tracker: jira` and
at least one GitHub repo (`gr_project_repos`).

## Outcomes and receipts

Each run writes the usual job receipt plus a per-request record
`state/jobs/<key>.requests.tsv`: `<slack ts>\t<pr url>\t<ticket>\t<outcome>`, outcome one of
`claimed` (in progress), `approved`, `review-stopped`, `qa-stopped`, `untrusted`, `error`. `error` (infra failure: worktree, auth,
timeout) pushes ntfy once and counts toward `pause_after_failures`; review/QA stops are normal
outcomes, not job failures.

## Invariants touched

- Polling reads; only gated paths write — the Slack read is a read verb; all writes are bash
  behind tiers above.
- Untrusted text is data: Slack text is only parsed for two URLs; ticket text reaches the model
  only from trusted authors; PR content is reviewed, never obeyed.
- Model runs pass only by side effect: nonce-bearing files and the `qa-exec.sh` log.
- Never `Bash(*)`; `qa-exec.sh` is the only way a script executes.

## Builder's discretion

- Whether `/code-review` is usable headlessly; fallback as above.
- File layout (likely `scripts/job-slack-cr-qa.sh` + a `lib-cr-qa.sh`), reuse of `pr-pipeline.sh`
  helpers (`_neutral`, worktree, adapter call) by extraction into a shared lib.
- Comment wording; keep each to one comment.

## Calls made without the user (flag if wrong)

- On a stop, 👀 stays and nothing else is reacted; a human re-requests by posting a new message.
- An AC not met counts as `high` (a stop).
- Review failing to run is a stop, not a pass.
- One request per run, oldest first.
- The local ledger, not the reaction, is the dedup key; any pre-existing 👀 still means "skip".
- Security findings count only if the PR introduced them (the after_pr rule); unknown severity
  counts as `high`.
- Ticket trust reuses `implement-next`'s authorship check; an untrusted ticket stops before any
  model sees its text.
- QA scripts may use the network (package installs, local servers); no credentials in their env.
- Reactions reuse the `slack-react` tier; `pr-comment` and `jira-comment` are new tiers.
- `exclusive: true` on the job makes the global poll skip the project's Slack source, so the
  poll's own 👀 "detected" status reaction never lands on requests first. Requires adding
  `slack:cr-qa` to `JOBS_SUPPORTED` (`ea-config.sh`). While the job is paused the poll reads the
  channel again (the existing no-silent-outage rule), and requests it reacts to are skipped by
  cr-qa afterwards.
