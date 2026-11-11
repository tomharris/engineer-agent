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
  a `gh` text read to the unattended allowlist, do not start QA from an unattended run, and do not
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
