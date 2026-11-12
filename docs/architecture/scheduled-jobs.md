# Scheduled jobs


`projects.<slug>.jobs` gives one project's integration its own interval, **alongside** the global
poll. Spec: `docs/superpowers/specs/2026-11-09-scheduled-jobs-design.md` (phased; phases 1–5 are built —
dispatcher, `slack`/`watch` with `channels`/`mentions`/`my-threads`, status reactions,
`jira`/`implement-next`, and `github-issues`/`implement-next` as phase 6a, plus `after_pr` below).

```
jobs-tick.sh (every 60s; install-jobs.sh)
  for each valid, unpaused, in-window, due job → detached run_job:
    job lock → handler → receipt → failure streak / pause
      slack:watch          job-slack-watch.sh → poll-slack.sh --project --sources <watch> → manifest → jobs-draft.sh
      jira:implement-next  job-jira-implement-next.sh: guards → ar_select → drafts/ item
                           → push for Approve, or (implement + jira-claim) claim → confined run
      github-issues:implement-next  job-github-implement-next.sh: same shape, gr_select,
                           gh-claim.sh, tier github-claim
      slack:cr-qa          job-slack-cr-qa.sh: tiers → Slack read → crqa_pick → ticket trust
                           → ledger + claim reaction → review → QA → comment / approve
```

Things a reader will otherwise "fix" back:
- **One tick + due-check, not one LaunchAgent per job.** Per-job plists multiply the launchd
  env-cache trap and the TCC re-grant. The plist sets `AbandonProcessGroup` because jobs run
  detached from the tick; without it launchd kills them when the tick exits.
- **Each job keeps its own cutoff file** (`EA_POLL_STATE_FILE` → `state/jobs/<key>.state.yaml`,
  honored by `lib-state.sh`). Sharing `last-poll.yaml` with the global poll would be two
  unsynchronized read-modify-writes. Overlap between the two paths is the queue's job: the
  `(type, source_id)` reconciliation dedups.
- **`jobs-draft.sh` takes the global poll's lock**, and a held lock means *deferred*, not failed.
  The poll's resume sweep re-emits every undrafted `incoming/` item, so drafting concurrently could
  put two models on one file. Deferral never strands: the job's next collector run re-emits them.
- **The drafting allowlist is the poll's**, via `lib-poll-allowlist.sh`. Do not fork a second copy;
  allowlist drift caused most past silent outages.
- **Drafting success is ground truth**: a row counts only if its file is in `drafts/` (or carries a
  draft while `_unrouted` in `incoming/`), never the model's report.
- **`exclusive: true` is honored only for a job that can run** (supported pair, not paused) and
  is computed in `ea-config.sh`'s `_source_state`, so the scripted path, the bash receipt and the
  model's `EXCLUSIVE:` prompt line all agree. A paused job claiming a source would make it silently
  unpolled. The job's own collector sets `EA_JOBS_IGNORE_EXCLUSIVE=1`.
- **`poll-slack.sh --project` reads only that project's channels.** A channel the project doesn't
  watch has no Tier 0 route to it, so reading it only buys messages the filter discards.
- **Failure pushes: first failure, then the pause** (`guards.pause_after_failures`, default 3) —
  not one per run, for the same reason the dedup warning is push-once.
- `JOBS_SUPPORTED` in `ea-config.sh` is the single list of runnable `integration:action` pairs.

**Slack watch sources and status reactions** — things a reader will otherwise "fix" back:
- **`poll-slack.sh` runs every source through one `consider_msg`.** `channels` keeps the keyword
  filter and `last_checked_ts`; `mentions` (search) and `my-threads` (re-read
  `state/watched-threads.tsv`) skip the keyword filter and keep their own cutoffs (`mentions_ts` in
  the job's state file; `last_seen_ts` per thread). Each cutoff holds on any error in its source.
- **`my-threads` does not threshold `directed_at_user`**: being in the thread is the direction.
  The other three judgments still apply.
- **Mention candidates are every project with a `mentions` watch**, so two of them give `_unrouted`
  rather than an arbitrary winner. `after:` is day-granular, so the search starts a day early and
  `mentions_ts` does the exact filtering.
- **`slack-event.sh` takes a queue item, never a channel/ts/emoji.** It reads the target from the
  item's frontmatter and the emoji from `agent.slack.reactions`, so a model running it (execute-item
  on `posted`/`rejected`) picks only which of its own items to signal. `posted` also records the
  thread for `my-threads`, regardless of the tier. Always exits 0.
- **`drafted` fires from bash** (cron-poll.sh and jobs-draft.sh), only for items that reached
  `drafts/`, never on the model's word.
- **Shim verbs are discovered, not assumed.** `slack-mcp.sh react`/`unreact`/`search` look the
  tool up in `tools/list` and map arguments from its `inputSchema`; a missing tool exits 64. The
  connector has no remove-reaction tool, so `unreact` is 64 under `mcp-proxy` and earlier status
  emoji stay. Callers log 64 and move on.

**Assignment rules (`lib-assign-rules.sh`)** decide which Jira ticket `implement-next` may pick.
Read-only: search + dev-panel reads, never an assign or transition. Four things not to undo:
- **`ea-config.sh` copies the `rules` subtree verbatim** and `ar_validate` rejects unknown keys at
  every level. A mistyped `requires:` or `label_none:` would otherwise be a rule with a safety
  predicate silently missing.
- **`require.assignee` is inferred as `empty` only when the JQL says `assignee is EMPTY`, else
  `me`; `any` is never inferred**, so a rule cannot take someone else's ticket by accident.
- **Every uncertain predicate fails closed**: no story-point estimate, an unparseable timestamp, an
  unreachable dev panel (`no_linked_pr`), a blocker link without a status category.
- **A failed search aborts selection rather than falling through** to the next rule, since rules
  are priority-ordered. A ticket with any queue item in its `(ticket, source_id)` family, terminal
  included, is never picked.

`lib-jira-api.sh` holds the curl helpers `poll-jira.sh` used inline (credential on stdin), so
`jira-claim.sh` shares them. `ar_jira_init` sets globals: call it directly, not in `$(…)`.

**`implement-next` (`job-jira-implement-next.sh`)** — things a reader will otherwise "fix" back:
- **Unattended needs `implement` AND `jira-claim` AND trusted authorship.** The ticket's
  `creator` (not `reporter`, which the creator can set to anyone) and the author of every
  changelog edit to a field written into the queue item (summary, description, labels,
  components) must be in the job's `trusted_authors` (Jira
  accountIds); empty list, truncated changelog or any other author ⇒ untrusted. Any condition
  missing ⇒ the pick is written to `drafts/` with the reason and pushed with Approve/Reject; the
  Approve tap then claims with `--approved` and implements. This is the control for the sandbox's
  honest limit: the confined run can execute code as the user. It holds only because the check
  and the queue item come from **one** fetch and the confined run has **no Jira access**, so the
  model reads exactly the text that was checked. Keep both true: do not add a Jira verb, `curl` or
  a `gh` text read to the unattended allowlist, do not start QA from the unattended implementation
  run (QA belongs to `after_pr`, which reads only the queue item), and do not
  re-fetch the ticket after the check. Reasons name
  accountIds only, never display names (attacker-chosen text reaching the push).
- **The listener trusts `state/autopilot-items.tsv`, never frontmatter.** Queue files can be
  written by a drafting model that read untrusted text; `autopilot: true` there is display only.
  Only an item this job wrote (bash) to the ledger triggers a Jira claim on Approve.
- **One sandbox, two callers.** `run_ticket_implementation` lives in `lib-confined-run.sh` and
  writes `state/implement-inflight/<item>` (`<pid>\t<project>`, dead pid ⇒ stale) for every run,
  whichever entry point started it, so `max_in_flight` (default 1) counts an Approve tap's run on
  the same project.
- **Guards before selection, all fail toward doing nothing**: in-flight ≥ max; a previous pick
  still in `drafts/` (awaiting a human, or left there by a failed run); picks today ≥ `daily_cap`
  (default 1, machine-local date, `state/jobs/<key>.picks`). A lost claim race moves the item to
  `rejected/` so it never blocks the job.
- **A ticket the kind ladder makes an investigation is skipped in selection** (the shipped
  `investigation.jira_types` default includes `Task`). `preview` applies the same skip.
- **The handler traps TERM** (the dispatcher's watchdog kill) and releases the claim, so a timeout
  never leaves a ticket claimed with nobody working on it. `EA_JOB_MAX_SECONDS` (default 3600)
  bounds the whole run, implementation included.
- **Validation mirrors the sandbox**: `exec.allowed_commands` is read with the same block-list
  reader and charset `run_ticket_implementation` uses, so a job that validates cannot be refused at
  run time for a missing build list. A flow-style `["make"]` list is not read by that reader.

**Claiming (`jira-claim.sh claim|release`)** writes to Jira, so its guards are the point:
- **Refused (exit 4) unless `jira-claim` ∈ `auto_execute` or `--approved`** (a human Approve).
- **Race checks on both sides of the write.** The rule's assignee mode is re-checked on a fresh GET
  before assigning, and the assignee re-read after; losing either way exits 3 (skip). After a lost
  race the caller must **not** release: the ticket is someone else's.
- **Intent is recorded in the queue item before each write** (`claimed_by_run`, `claimed_assign`,
  `claimed_transition`), so a crash mid-claim cannot leave a claim release refuses to undo.
- **Release undoes only its own changes that nobody has touched since**: `claimed_by_run` must match;
  it unassigns only if it assigned and the ticket is still mine; transitions back only if the
  status is still the one it moved to. A failed release pushes an urgent ntfy itself.
- **Transitions resolve by name** (target status first, then transition name); a missing one is a
  warning, since workflows differ. The key must match the item's `source_id`.

**GitHub `implement-next` (`job-github-implement-next.sh`, `lib-gh-assign-rules.sh`,
`gh-claim.sh`)** mirrors the Jira path; the differences a reader will otherwise "fix" back:
- **Repo containment is enforced in bash, twice.** `gr_eval` rejects any search hit outside the
  project's `github.repos` (a rule's `query` can name any repo or org), and `gh-claim.sh` refuses a
  key outside them. The query is config-authored; the containment is not left to it.
- **"Status" is a Projects (v2) single-select field on the job's `board`, not labels** (user
  decision). Claim adds the issue to the board if absent (`claimed_board_added`) and records
  `claimed_project_status`; release moves it back only if it still has that status and nobody else
  is assigned. A board without the named option is a warning, like a missing Jira transition.
- **The GraphQL selection set is built per job** (`_gr_fields`): `issueType`, `blockedBy`,
  linked-PR fields and `projectItems` are requested only when a rule uses them, so one unsupported
  field (GHES) breaks only the rules that need it. Truncated `blockedBy` or cross-reference lists
  read as `unknown` and fail the predicate.
- **Trust covers title, body and labels** — the fields written into the queue item: the author,
  every `userContentEdits` editor and every renamed/labeled/unlabeled actor must be in
  `trusted_authors` (logins, compared case-insensitively). More than 100 of either history is
  `truncated` ⇒ untrusted. Bots that label (`github-actions`) are editors.
- **A GitHub multi-assignee race.** For `assignee: empty`, the post-claim re-read must show me as
  the *only* assignee; otherwise the claim is lost, and only my own assignment is removed.
- **A title that only a Form B judgment could classify is skipped**, not implemented: an unattended
  pick never guesses the kind. `add-ticket --implement` is the override.
- **The ledger names the tracker.** `autopilot-items.tsv` gained a fifth column (`jira` |
  `github`; absent ⇒ `jira` for older rows) and `_autopilot_claim_cmd` picks the claim script from
  it, never from the item.


**`after_pr` (`scripts/pr-pipeline.sh`)** — CI wait, confined fix, browser test, mark ready. Things a
reader will otherwise "fix" back:
- **Detached, not inside the job.** `autopilot_implement` launches it with `nohup` once the item is in
  `completed/`, for both the unattended run and an Approve tap. Under the job's watchdog, a CI wait
  would push the run past `EA_JOB_MAX_SECONDS`, and the handler's TERM trap would release a claim
  whose PR already exists. It has its own `max_runtime` watchdog, which kills its children too: a
  TERM trap waits for the foreground command to finish.
- **Everything GitHub is bash.** The PR comes from the branch bash read off the worktree before
  teardown (`state/pr-pipeline/<item>/branch`, prefix-checked), never from the model. The repo is the
  project checkout's raw `remote.origin.url` (not `get-url`, which applies `insteadOf`), and it must
  be in `github.repos`. Checks, failed-run logs and `gh pr ready` are bash calls. Neither model run
  gets a `gh` verb.
- **Success is a side effect.** A fix counts only if `ls-remote` shows the branch moved. A browser
  pass needs a final `VERDICT: pass <nonce>` line with the nonce minted for that run, so a page or
  log that prints "VERDICT: pass" cannot pass it. No checks reported after a grace period means
  stop, not pass.
- **CI first, then the browser,** so the browser tests the head that will be reviewed, including
  any fix commit.
- **The browser run drives your real Chrome** (`--chrome`, your sign-ins). Its allowlist is Read/Grep,
  git read and a fixed list of Chrome tools (no uploads). With `browser.chrome_device` set it also
  gets `select_browser` and `javascript_tool` (to measure computed styles instead of judging
  screenshots). Both are gated on the pin because page text could otherwise steer the run onto
  another browser or run JS in a tab with your sign-ins; pin a dedicated Chrome with no other
  sign-ins. Every `navigate` call in the transcript must stay on `url`'s origin (or be back/forward),
  else the test fails. Clicked links don't appear in the transcript, so beyond that nothing
  enforces "only `url`" except the prompt and the extension's site permissions. The
  validator requires a localhost `url` so the app under test is the branch, not a shared
  environment. This is why it runs only after the same trust gate as the implementation.
  Claude in Chrome drives the browser that was "picked last" across every connected device, so a
  Chrome on another machine sees its own localhost. `browser.chrome_device` makes the run call
  `select_browser` first and fail if it can't. A wrong device still fails closed, because it can't
  reach the server.
- **`browser.setup` / `browser.serve` run branch code unconfined** (bash, your user, your env):
  `npm ci` runs dependency install scripts and `npm run dev` runs the model's code. This is the
  confined run's accepted residual (its `Bash(npm *)` rule already runs model-edited
  `package.json` scripts), not a new one, and it is bounded by the same trust gate. Not
  `--ignore-scripts`: it breaks packages that need postinstall. An OS sandbox would be the real fix.
- **`pr-ready` is its own tier**, since ready-for-review notifies reviewers. Without it the pipeline
  pushes that the PR passed and leaves it draft. It never moves the board status.
- **A stop leaves the claim.** Unlike a failed implementation, the PR exists, so `on_fail` does not
  apply.
- **A stop resumes on new commits.** A stop after the run has started writes two files under
  `state/pr-pipeline/<item>/`: `stopped_head` (the remote tip now) and `trusted_from` (the head
  the run started from). A run clears both once its start head is known. A stop before that point
  leaves them as they were. Each implement-next tick runs `pr_pipeline_resume_stopped` *before* its
  guards, since the guards only limit new picks. It relaunches the job's ledger items whose branch
  tip (`git ls-remote`) differs from `stopped_head`. That makes one push one resume, and a resumed
  run that stops again waits for the next push. A deleted branch ends the watch, and an
  unreachable remote skips the item for that tick. The pipeline's own lock covers a run already in
  progress.
- **Only your own pushes resume.** A resumed run executes branch code (fix-run builds,
  `browser.serve` unconfined), so new commits would otherwise bypass the trust gate the original
  implementation passed. `resume_push_verdict` walks the repository activity API (`before`/`after`
  pairs) from the tip back to `trusted_from`, not `stopped_head`. That way a push by someone else
  while the run was going is checked too, and the run's own fix pushes, made as the gh user, pass.
  Every push on the way must have the gh user as its `actor`. It checks the pusher, not commit
  authors, which anyone can forge. Any other pusher ends the watch with one urgent push and the
  manual command, even when your push sits on top of theirs. If the activity API fails, or the push
  isn't listed yet, the item waits a tick.
- **The relaunch runs only the checked tip.** The sweep passes `--expect-head <tip>`. If the PR
  head has moved when the pipeline starts, it exits without touching `stopped_head` or
  `trusted_from`, and the next sweep checks the new pushes. Someone else pushing *during* a run is
  the pipeline's existing residual, for first runs and resumed runs alike: the per-stage head
  checks and the next resume's `trusted_from` walk catch it, but a stage already running does not.

**`after_pr` handoff stages** (spec `docs/superpowers/specs/2026-11-10-after-pr-handoff-design.md`):
security → CI → browser → QA → ready → transition → announce. Things a reader will otherwise
"fix" back:
- **Security runs before CI, and both must pass on one head.** A CI fix is re-reviewed and a
  security fix re-runs CI, at most three passes. The adapter reviews the PR's head *at that moment*, so
  a head that moved during a review stops the pipeline: the verdict belongs to another commit.
- **The reviewer is a user-supplied adapter** (`security.command`, contract in README). The plugin
  names no vendor and parses no vendor-specific title format; the adapter maps its tool's output
  to `findings.json`.
- **"Introduced" is deliberately biased toward fixing.** Any finding whose file (minus `./`,
  `:line`, `#Lnn`) is in the diff counts, whatever the adapter says — reviewer output is model
  text that read the diff, so a planted "pre-existing" claim must not skip it (fail closed; this
  also fixes older issues in touched files). `introduced: true` adds findings outside the diff. Everything else is skipped by user decision (2026-11-10), even critical ones —
  they are counted in the QA comment, not gated on.
- **Every introduced finding is fixed, any severity.** Same user decision. `fix_attempts: 0` turns
  the stage into a gate.
- **The QA run's scripted tests are data.** A JSON list of `{method, path, body, expect_status,
  expect_contains}` run by `qa_checks` with curl: allowlisted methods, a path that must start with
  `/` and has no `..`, bodies on stdin (`@file` in a body is text). Model-written shell would run
  unconfined with your environment, a bigger residual than `browser.serve`.
- **The QA run reads only its worktree, its queue item and `change.diff`.** Whatever it reads can be
  published. Bash writes the diff; the run gets no git verb (`git diff --no-index` reads any file),
  no Glob/Grep (unscoped by path), no tracker, `gh` or network verb, and is told the queue item,
  never the live ticket.
- **Model text leaves only neutralized.** `_neutral` drops `[]()<>`, backticks and `|` (Markdown and
  Jira wiki link syntax) and any `scheme://` or `www.` address; the summary is capped at 2000
  bytes. The Slite note is rebuilt from validated parts, not uploaded as the plan file.
- **A missing `security-review`/`qa-publish` tier holds the PR in draft**; a missing
  `jira-transition`/`slack-post` tier only skips that step, since the PR is already in review.
- **The announce text is bash's**: PR URLs rebuilt from `gh` numbers in `github.repos` (fork PRs
  excluded; teammates' PRs for the ticket included, as the user asked), the ticket
  URL from `agent.jira.site` and the ledger key, never model text. The channel must be one of the
  project's `slack.channels`.

## `slack` / `cr-qa` (`job-slack-cr-qa.sh`, `lib-cr-qa.sh`)

Reviews and QAs other people's PRs on request. Spec:
`docs/superpowers/specs/2026-11-11-cr-qa-job-design.md`. A message in `channel` is a request when
it starts with `trigger_prefix` (default `CR/QA`), has no `reactions.claim` emoji (default `eyes`),
was posted by a `trusted_slack_users` id, holds exactly one PR URL and one Jira browse URL, the PR is
in one of the project's `github.repos`, and its ts is not in the job's ledger. One request per run,
oldest first.

Sequence: tiers (`slack-react`, `pr-comment`, `jira-comment`, `jira-transition`,
`security-review`; any missing ⇒ error before anything is claimed) → ticket fetch +
`jira_untrusted_reason` (untrusted ⇒ ledger `untrusted`, one ticket comment, no reaction, no model
run) → ledger `claimed`, claim reaction → worktree of the PR head (`refs/pull/<n>/head`, checked
against `headRefOid`) → review → QA → approve.

Things a reader will otherwise "fix" back:

- **The ledger (`state/jobs/<key>.requests.tsv`), not the reaction, is the dedup key.** The
  connector's add-reaction succeeds when the emoji is already there and reactions don't say who
  added them. A 👀 already present still means "someone else has it". On a stop the claim stays and
  nothing else is added; a human re-requests with a new message.
- **The poster is re-verified by ts.** The connector's channel read is a text blob, and a message
  body can imitate another message's `=== Message from … (U…)` header, so it only nominates a ts.
  That message is read alone (its real header comes first) and the job acts on what that read
  says; if it is not a trusted request for this project the ts is marked `untrusted` (safe: no
  trusted request lives there), so a forged header can neither inject nor suppress a request.
- **Pair it with `exclusive: true`.** The global poll's own "detected" status reaction defaults to
  `eyes`; without exclusivity it would mark requests claimed before cr-qa sees them.
- **Review.** One read-only model run (Read on the worktree and workdir only — `Read(...)` also
  scopes Grep/Glob, so neither is granted bare) writes nonce-bearing findings; an unmet AC is
  `high`. The `security.command` adapter runs as in `after_pr`, and only findings the PR introduced
  count (`security_introduced`). Severity is case-insensitive; unknown or missing counts as `high`.
  Anything `medium`+ ⇒ one PR comment, ledger `review-stopped`. A review that cannot complete is an
  error, never a pass.
- **QA scripts are run by bash, not the model.** A model-callable wrapper's log would be forgeable:
  the QA run is allowed `exec.allowed_commands` (e.g. `uv`), which can run arbitrary code. So a plan
  run writes a nonce-bearing run spec (`{runs: [{script, dir, argv}]}`); bash checks `argv[0]` is
  allowlisted, argv names the script and has no option-like argument (anything starting with `-`;
  a flag denylist misses bundled forms like `-cCODE`), `dir` resolves inside the worktree and the target path doesn't already exist (a PR
  symlink there would redirect the copy), then runs it under `qa.timeout` with a minimal env and
  records the exit code. A verify run then follows the written steps and judges each AC. Pass =
  every attached script exited 0 by bash's record **and** every AC `pass`.
- **Only trusted text and scripts.** Comments count only when a `trusted_authors` account wrote
  and last edited them; attachments only when one uploaded them (`.py`/`.sh`, plain file names).
- **Model runs start in an untrusted checkout.** `--setting-sources user --strict-mcp-config` keep
  the PR's `.claude/` hooks/settings and `.mcp.json` from loading, and `env -i` keeps tracker,
  GitHub and Slack credentials out of the run and of anything it executes.
- **Script output stays local** (`out/<script>.log` in the run's temp dir, logged path in
  `state/jobs.log`): it can hold secrets, so the Jira comment carries names and exit codes only.
