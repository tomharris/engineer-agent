# Confined runs and the approval invariants

### Confined headless ticket implementation

A `ticket` is the one item type whose *execution writes code* — approving it runs the full
`implement-ticket` flow (branch → inline iterative implementation → migrations/typecheck → self-review of the diff → draft PR → best-effort QA plan), not a single
`gh` call. That cannot run under the read/post allowlist the other types use, so the listener
gives `ticket` a **separate, deliberately confined execution path** (`run_ticket_implementation`
in `scripts/lib-confined-run.sh`, shared by the listener and the `implement-next` scheduled job). It is the one place untrusted issue text can steer code, so the two
things that define the sandbox are decided in **plain bash, before `claude` starts** — untrusted
text can influence code *inside* the sandbox but never the *shape* of it:

1. **Path isolation.** The listener creates a throwaway `git worktree` of the target repo
   (detached at the base branch) under `~/.local/share/engineer-agent/worktrees/` and runs the
   headless session with that as cwd, so the user's real checkout is never the target. `create_run_worktree()`
   is shared with the investigation path (like `reconcile_queue_move()`) and **names the commit it
   actually checked out, plus whether the fetch that resolved it succeeded**. The `git fetch` stays
   best-effort — a brief github outage must not strand the item in `drafts/` and fire a `⚠️ Failed`
   push inviting a retry — but it is no longer swallowed by a bare `|| true`: on failure the run
   proceeds from the **local** `origin/<base>` ref and the log says `base main @ <sha> (STALE: fetch
   failed…)`. Before this, two runs were implemented against a days-old release commit while the log
   reported a reassuring `base main`, giving the diff a base nobody could reproduce. The
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
   `Bash(<cmd> *)` rule, added to `Read/Edit/Write/Glob/Grep`, enumerated `git` verbs
   (`CONFINED_GIT_WRITE_RULES`), `gh pr create` plus read-only `gh` verbs, `Bash(mv *)`, and
   `notify.sh`. Never `Bash(git *)` / `Bash(gh *)`: those also grant `git -C /elsewhere`,
   `git -c alias.x='!cmd'` (arbitrary exec), `gh api -X POST` and `gh pr merge`. **The only push
   is `scripts/confined-push.sh`**: a `Bash(git push -u origin:*)` prefix rule still admits
   `HEAD:main`, `--force` and `--delete`, so the wrapper pushes one local branch under
   `agent.branch_prefix/` to the same name, never the base, never forced. Verbs that act on refs
   shared with the user's checkout (`git branch`, `stash`, `fetch`, plain `checkout`/`switch`) are
   absent; only `checkout -b`/`switch -c` create a branch. An **unattended** run
   (`implement-next` without an Approve) also loses `gh issue view` / `gh pr view` / `gh pr list`
   — they read text the trust check never saw — and gets no QA follow-on, whose Jira read and
   `curl` sit outside that check. The QA run gets read-only `git`/`gh` only. Unattended QA happens
   later, in `after_pr` (`pr-pipeline.sh`): a separate confined run over the same queue item, never
   a re-fetch, with Read scoped to its worktree, that item and a bash-written diff, no
   git/tracker/`gh`/network verb, and
   output that bash validates (nonce, JSON checks run by a fixed curl harness) and neutralizes
   before anything is published. **Deny-by-default:** a project with no (valid) list has remote
   ticket approval *refused* — the item stays in `drafts/`, a `⚠️ Failed` push tells the user to
   set the list, and no unconfined session ever runs. It is never `Bash(*)` / `bypassPermissions`.
3. **Draft-PR review gate** (downstream, unchanged): the output is a draft PR the human reviews.

**Which base, and what the worktree is missing.** The base is the *remote's* default branch
(`git ls-remote --symref origin HEAD`); the checkout's own `origin/HEAD` is only a fallback when
the remote can't be asked, because that symref is set at clone time and a plain fetch never
updates it. And only `origin/<base>` is checked out: the old fallback to a local branch of the
same name is gone. Observed 2026-11-11: a `main` checkout's `origin/HEAD` still named a deleted
`stage` branch, the fetch failed, and two autopilot runs detached at a local `stage` 22 months
behind `master` (one rebuilt its branch on `origin/master` by itself; the log said `base stage`).

A worktree has only tracked files, so a repo whose checks need installed dependencies or
generated files cannot run them there. The same day a run on `main` (PHP; no `php` on the host,
no `vendor/` in the worktree) reported `complete` with "`php -l` only", shipped an unescaped
apostrophe in a PHP string, and failed every CI job. Two per-project settings close that:

- **`exec.worktree_setup`** — a shell string the listener runs from plain bash in the fresh
  worktree before `claude` starts (and before each `after_pr` fix run), with `EA_PROJECT_PATH`
  set to the user's checkout. Trusted config, the same class as `after_pr.browser.setup`.
  A failure is logged, the run proceeds, and the prompt says the setup failed.
  On an `after_pr` fix run the worktree is the PR branch, whose content a confined run wrote, so
  the setup string must treat the tree as untrusted: it runs unconfined, as the user. That adds no
  capability the fix run lacks (its build rules already execute branch code), but the setup itself
  must not follow paths the branch controls — e.g. refuse when a target such as `vendor` is a
  symlink, which a branch can commit to redirect a copy outside the worktree.
- **`exec.validate`** — the one command the run must run green on its final commit to report the
  work `complete` (`validation_prompt` puts it in the prompt; the skill's "Running checks"
  section covers projects without one). It is validated in bash like the allowlist: its first
  word must be an `exec.allowed_commands` entry, and it must be one simple command (no
  `;` `&` `|` `<` `>` `$`, backtick or newline), since a `Bash(<cmd> *)` rule is matched per subcommand and a denied
  command in a headless run stalls silently. An invalid value is logged and dropped.

When the host has no runtime, the check must run in Docker **with the worktree mounted**
(`docker run -v "$PWD":…`, or a repo target that mounts `$(CURDIR)`). `docker compose exec` into a
long-running dev container is wrong in a confined run: that container mounts the user's own
checkout, so it tests different code and can pass for the wrong reason.

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

**And its success check asks "did THIS run touch a QA draft", not "does the queue contain one".**
`drafts/` accumulates `qa-test-plan` items until a human reviews them, so a bare
`drafts/*qa-test-plan*` glob is true in the steady state — it reported success whenever any older
plan was still pending, including on a run that produced nothing. The run is bracketed by a marker
file and the check is `find -newer`, which also catches the update-in-place case a before/after
filename snapshot would miss.

**Honest limit — this is "medium," not airtight.** Claude Code `Bash()` rules are command-prefix
matches, *not* cwd-scoped, and the build commands run files the model can edit (a `Makefile`, test
helpers, repo-tracked commit hooks), so ticket text that steers the model can run code as the user.
`git diff/log/show --output=<path>` can also write a file anywhere. The worktree bounds the
*default* target and the command *set* is curated, but that is the residual risk, and it is why the
`implement-next` job needs trusted authorship to run without a human (see "Scheduled jobs").
Mitigating it: the command set is small and build-only, the source is an issue routed to the
user's own project, and the output is draft-only. `implement-ticket` is worktree-aware (Step 2: it
creates the branch in place when already inside the repo checkout, and pushes before `gh pr
create` so the headless run never hits an interactive push prompt).

> **A push from a linked worktree uses `--no-verify`; a push from the human's own checkout does
> not.** A pre-push hook that runs tests/lint/typecheck cannot pass in the listener's worktree —
> it is outside the project's docker container, so the hook fails on its own setup rather than on
> the diff and git refuses the push outright, stranding a committed branch with no PR, which the
> listener's `drafts/`-existence check then reports as `⚠️ Failed`. CI runs the same checks after
> the push anyway, so nothing is skipped, only relocated. Both push sites apply it under the same
> guard — `git rev-parse --git-dir` differing from `--git-common-dir`, which is true only in a
> linked worktree — so the interactive path still runs the human's hooks on their own checkout:
> `implement-ticket` Step 6 (the pre-`gh pr create` push) and `execute-item`'s `ticket` case
> (its local-only-branch finisher push).

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
that exists. Same "medium, not airtight" admission as the implementation path's above.
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
**One named exception:** a scripted Slack collector runs `scripts/slack-event.sh detected` on an
item it creates, which adds an emoji reaction (with `slack-react` in `auto_execute`). It is allowed
because the emoji comes from a config-closed map and the target is the message just read, taken
from the item's frontmatter; no model is involved.

Key invariant: **`/engineer-agent review-queue` (terminal) and `/engineer-agent execute` (remote) both delegate to the shared `execute-item` skill** — the single source of truth for what approving an item does. Two typed exceptions: `qa-test-plan` is interactive-only and is refused on the remote path; and an approved `ticket-investigation` on the remote path is handled by the listener's confined **read-only** investigation (`run_ticket_investigation`) rather than by `execute-item` — `investigate-ticket` posts the ticket comment itself, while `execute-item`'s own `ticket-investigation` case is the *finisher* for the interactive path, posting an **already-written** `## Findings` section and refusing if there isn't one.

> **`ticket` is deliberately NOT a third exception — that is the fix for a real bug.** `execute-item`'s `ticket` case **implements the ticket** when it isn't implemented yet: it probes for the branch and either finishes a pushed one (`gh pr create --draft`), pushes a local-only one and finishes it, or delegates the whole coding session to `implement-ticket`. Previously this case was a pure finisher that assumed a pushed branch, and *only* the remote path ever ran the implementation — so the interactive path had **no implementation step at all**, and approving a freshly-polled ticket in `review-queue` could only report "it only opens a draft PR from an already-implemented, pushed branch" and fail. The listener still gives a headless `ticket` its own function (`run_ticket_implementation`), but that function now builds the **sandbox only** — worktree, `exec.allowed_commands` allowlist, `TICKET_BUDGET_USD`, turn-notify env, the QA follow-on, teardown and the queue-move reconcile — and then follows `execute-item` like every other type. Keep that split: *what approving a ticket means* belongs to `execute-item` (one definition, every entry point); *what a headless run may touch* belongs to the listener's plain bash, resolved before `claude` starts, because a skill runs **inside** the sandbox and so can never be the thing that builds it. Note the asymmetry with `ticket-investigation`, which remains finisher-only on purpose: an append-only ticket comment has no idempotent retry (see "Confined headless ticket investigation"), whereas a branch probe makes the implementation path re-entrant.

