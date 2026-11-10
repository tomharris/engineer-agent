# Headless claude -p runs (cron poll and listener)

**Writing a headless `claude -p` run** (both scripts do this; the rules below were each learned
from a run that failed silently):
- **Pin `--permission-mode`.** Otherwise the run inherits `permissions.defaultMode`; in `plan` mode
  `claude -p` prints a plan and exits 0 without doing anything.
- **`--permission-mode` is not enough on its own — pass `--allowedTools`.** Only a built-in set of
  Bash commands (`ls`, `cat`, `grep`, read-only `git`, …) is auto-approved. `gh` and `spy` are not
  in it, so they prompt in every mode, and a prompt in `-p` is a denial.
- **Allowlist a CLI's read-only *preflight* verbs, not just its data verbs.** The model routinely
  probes a tool's health before using it (`gh auth status`, `gh --version`, `slack-mcp.sh auth`);
  when the probe is denied it concludes the **whole CLI is unavailable** and abandons every source
  *without ever trying the verbs that are allowed*. This has now broken two integrations the same
  way: the Slack `auth` preflight (fixed in `162a4bb`, which cascaded to a doomed direct-connector
  fallback) and `gh` — where five consecutive polls on 2026-07-24 reported `status: error` with all
  8 GitHub sources in `errors:` while `gh pr list` was allowlisted and working the entire time; the
  transcripts show only `gh auth status`/`gh --version` were ever issued. It presents as
  *intermittent*, not deterministic, because a run that happens to skip the probe (or shrug it off)
  still succeeds — the 2026-07-23 run hit the identical denial and recovered. Preflights are
  read-only, so listing them costs nothing against the read-only invariant.
- **Never let an unattended run write memory.** A receipt is a fact about **one** run; a memory is a
  belief applied to **all future** runs. The 2026-07-24 `gh` outage went from one flake to five
  identical failures because the second failing poll wrote a project memory asserting `gh` was
  permanently blocked — including "Do not treat this as transient and just rerun" — which every
  later poll then loaded, re-read, and confirmed **instead of retesting**. That converts an
  independent transient into a correlated, self-citing, permanent outage, and it defeats the
  receipt-based liveness design (which assumes failures are independent). Every headless prompt
  in `cron-poll.sh` and `approval-listener.sh` (the shared `NO_MEMORY_RULE`, applied to the
  generic execute, ticket implementation, and QA runs alike) therefore forbids creating/updating
  memory files and forbids treating an existing memory as evidence about the current run.
  **Memory is keyed by CWD, not by which script launched the run** — the poll and the listener's
  `run_generic_execute` both run from `$HOME`, so they share
  `~/.claude/projects/-home-tom/memory/` and can cross-contaminate; the ticket/QA runs `cd` into
  a per-run worktree and so get a throwaway namespace, but only as a side effect of the path
  sandbox, which is why the rule is applied uniformly rather than relying on that accident. If an
  unattended run ever misdiagnoses itself again, check that memory directory before believing the
  diagnosis.
- **Don't put `--allowedTools` last before the prompt.** It takes a variable number of values and
  will swallow the prompt as another rule (`Input must be provided … when using --print`). Keep a
  single-value flag in between.
- **Hook commands are NOT subject to `--allowedTools`.** A plugin's `hooks/hooks.json` runs
  whatever it registered regardless of the allowlist, because hooks are operator-configured rather
  than model-requested. So an `allowed_tools` array is not an exhaustive statement of what a
  headless run can cause to happen — `hooks/hooks.json` is the other half. Today that grants
  nothing new (`turn-notify-hook.sh` only shells out to `notify.sh`, which the confined ticket
  allowlist already carries), but keep hooks outbound-only and fail-open so it stays that way.
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
- **macOS privacy (TCC) grants are keyed to the RESOLVED binary, so every `claude` auto-update
  revokes them — and an unattended run has nobody to click Allow.** `claude` updates by writing a
  **new** `~/.local/share/claude/versions/<ver>` file and repointing the `~/.local/bin/claude`
  symlink. Pointing `CLAUDE_BIN` at that stable symlink does **not** help: macOS resolves the
  symlink and records the *target*, so the new version starts with zero grants. Confirmed by
  reading the user TCC database on 2026-08-31 — one full set of `Desktop`/`Documents`/`Downloads`/
  `NetworkVolumes` grants per version (`2.1.245` … `2.1.248`, each set being a human clicking Allow
  after that update) and **none** for the freshly-installed `2.1.251`. Interactively this is a
  dialog; under launchd the access is simply refused, and — unlike a denied `--allowedTools` rule —
  nothing lands in the receipt, so the poll reports `status: ok` on a run that could not read.
  `claude_bin_changed()` in `lib-paths.sh` is the preflight, shared by **both** unattended entry
  points: it records the resolved path in `state/claude-bin.path` and pushes one low-priority ntfy
  warning when it changes. `cron-poll.sh` calls it only when a model run will actually start (a
  scripted-only poll never launches `claude`, so it cannot raise a dialog); `approval-listener.sh`
  calls it at startup **and** before each dispatch, because the service runs for days and the mtime
  self-reexec cannot catch this staleness — the script file is unchanged, it is the binary that
  moved. The record is deliberately **shared** between the two: they run as the same user against
  the same grants, so whichever notices first warns, and the user normally gets one push per
  update (the two jobs are unsynchronized, so a poll and a dispatch landing in the same instant
  can both warn once — accepted, since the alternative is a lock on the notification path).
  `resolve_real_path()` resolves a **bare** command name through `PATH` before following
  symlinks: `CLAUDE_BIN` is usually already absolute, but the installers bake in whatever it held
  at install time, and a bare name returned verbatim would make the record constant and the
  preflight a silent no-op. Two deliberate
  choices: it warns **once** per new binary (the record updates as it reports) because a push on
  every 15-minute fire trains you to ignore the topic you approve queue items on; and it
  **never reads `TCC.db`** to check the grants directly — that database is itself privacy-protected,
  so probing it from the unattended run is a plausible way to raise the very dialog this warns
  about. A changed path is sufficient evidence the grants are stale. The durable fix is to grant
  **Full Disk Access** to the versioned path (it supersedes the individual folder services, so one
  grant replaces four dialogs), or to pin the version and update deliberately.
- **`forceLoginOrgUUID` blocks *environment* credentials only — it does NOT block a keychain
  credential, so it is not a headless dead end.** When an org deploys a root-owned
  `/Library/Application Support/ClaudeCode/managed-settings.json` with `forceLoginMethod: claudeai`
  + `forceLoginOrgUUID: <uuid>`, Claude Code restricts login to that org, **exits at startup if the
  active credential isn't a verified member**, and per the official docs *blocks all environment
  credentials* (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `apiKeyHelper`,
  `CLAUDE_CODE_OAUTH_TOKEN`) "since organization membership can't be verified for an environment
  credential." It surfaces as `Unable to verify organization for the current authentication token.
  This machine requires organization <uuid> but the token could not be validated` and `claude`
  exits 1 — a **freshly-minted, org-valid `claude setup-token` still fails identically** (verified
  2026-07-16), because it is an environment credential regardless of which org minted it.
  **But the login-keychain credential is not an environment credential.** When it belongs to a
  verified member of the named org it passes under the policy, and a `gui/$UID` LaunchAgent can read
  it — so the in-session scheduler above is sufficient *with the policy in force*. **Verified
  2026-08-25** on a machine where the policy was present and Jamf-re-enforced: pristine `claude -p`
  under `env -i` (HOME/USER/PATH only) authenticated, then a full poll ran `status: ok` /
  `errors: []` across 21 sources. This corrects an earlier claim here that the policy "blocks *all*
  headless auth … no scheduler choice helps", and a companion claim that the policy had been
  *removed* from this machine on 2026-07-17 — it returned 2026-07-24 via Jamf and is active now.
  Wall A (policy) and Wall B (out-of-session keychain) were never stacked: **clearing B was
  sufficient.** Practical consequence: **the two walls fail differently, so read the error.**
  `Unable to verify organization…` = an environment credential is in play (remove it; don't add
  one). Plain `Not logged in` = the keychain isn't reachable — an out-of-session scheduler, a
  missing `USER`, or a GUI session that isn't logged in. Only if a keychain credential is genuinely
  unavailable (no interactive login possible, e.g. a headless build box) do the fallbacks apply:
  (a) a cloud-provider inference path (Bedrock/Vertex/Foundry, via
  `CLAUDE_CODE_USE_BEDROCK`/`_VERTEX`/`_FOUNDRY`), which the docs exempt, or (b) an org/IT exemption
  or org-scoped headless credential. Do **not** re-add an `auth.env`/`CLAUDE_CODE_OAUTH_TOKEN`
  loader — that is precisely the credential class the policy rejects. If a root-owned
  `managed-settings.json` is present, do **not** delete, truncate, or shim around it (and do not
  patch the `claude` binary's `managed/settings` string to make it unreadable) — it is an
  intentional corporate security control, and MDM restores it anyway.

Both `cron-poll.sh` and `approval-listener.sh` resolve the Claude Code binary from `PATH` by default, but honor a `CLAUDE_BIN` env var override (a specific shim/wrapper/install path). Because cron, systemd, and launchd do not inherit the interactive shell environment, `install-cron.sh` and `install-listener.sh` capture `CLAUDE_BIN` when set at install time and bake it into the launchd `EnvironmentVariables` (macOS) / systemd `Environment=` (Linux listener) / crontab entry (Linux poll) so the supervised runs use the same binary. On macOS `install-cron.sh` also accepts `EA_POLL_HOURS` (comma-separated clock hours) + `EA_POLL_MINUTE` to emit a `StartCalendarInterval` schedule confined to business hours instead of the default `StartInterval` every-N-minutes; this caps how much a first poll on a large assigned backlog can spend.

> **Changing `CLAUDE_BIN` (or any `EnvironmentVariables` entry) in a LaunchAgent plist does not
> affect the running job — you must `bootout` + `bootstrap`, not `kickstart`.** launchd caches a
> job's environment block when the job is loaded, so an edited plist is inert until the job
> definition is re-read. `launchctl kickstart -k` restarts the *process* but reuses the *cached
> definition*, so it silently does not pick up the change. This burned a real migration: both
> `engineer-agent-poll` and `engineer-agent-listener` ran for hours with a live
> `CLAUDE_BIN` pointing at a wrapper whose target binary had been moved away, while the plists on
> disk had already been corrected — the poll wrote no receipt and the listener failed every
> approval with `No such file or directory` and left the item in `drafts/`. Note the
> `approval-listener.sh` mtime self-reexec **cannot** catch this class of staleness: the script file
> is unchanged, it is the job environment that is stale. So always verify with
> `launchctl print gui/$UID/<job> | grep CLAUDE_BIN` — reading the plist proves nothing about what
> is running. `install-cron.sh` / `install-listener.sh` do a full bootout+bootstrap, so a
> re-install is also a valid fix; a hand-edited plist is not.

The poll's own per-run budget is capped with `--max-budget-usd`, default **`6.00`**, overridable via
`EA_POLL_BUDGET_USD` (captured at install time and baked into launchd/crontab like `CLAUDE_BIN`). A
full 6-project × 4-source poll that reads live Slack channels and may draft a PR review / ticket
intent inline can exceed a low cap; when it does, `claude -p` aborts mid-run, writes no receipt, and
the next fire re-attempts the same work — a flat `2.00` did exactly this once mcp-proxy Slack reads
started succeeding. `cron-poll.sh` also takes a **PID lockfile** (`state/cron-poll.lock`) and exits
early if another poll is already running (a stale lock from a dead PID is reclaimed): two concurrent
polls thrash the same state/receipt files and each burns its full budget racing the other.

> **The lockfile cannot catch a hung poll under launchd — launchd never starts a second instance of
> a job that is still running, so the next fire never reaches the lock check.** Observed
> 2026-09-22: one `gh pr list` blocked for 24h, every later fire was silently swallowed, and
> `launchctl print` still said `running` / `last exit code = 0`. Three guards, all in plain bash:
> - **Per-command timeout.** Every `gh` call in the GitHub collectors and every Slack CLI call in
>   `poll-slack.sh` runs under `with_timeout` (`lib-paths.sh`; macOS ships no `timeout(1)`),
>   `EA_POLL_CMD_TIMEOUT` seconds, default 120. The curl-based collectors already carry
>   `--max-time`.
> - **Whole-run watchdog.** `cron-poll.sh` kills its own process tree after `EA_POLL_MAX_SECONDS`
>   (default 3600) and pushes an urgent ntfy alert first, since a killed run never reaches the
>   receipt check.
> - **Phase A errors reach the receipt.** The GitHub collectors log a failed repo and carry on
>   (exit 0), so neither receipt writer saw the failure and the receipt said `ok`. Collectors now
>   call `phase_a_error`, which appends to `state/poll-phase-a-errors.txt` (truncated per run);
>   `cron-poll.sh` merges each line into `errors:` and downgrades `ok` to `partial`.

> **A supervised daemon runs whatever it parsed at launch — editing the script on disk
> does not reload it.** `install-listener.sh`'s `systemctl --user enable --now` is a no-op on an
> already-running unit, so before this was fixed a code deploy could leave the *old* listener
> running silently (it once ran ~28h past a commit and never emitted the newly-added acks). Two
> guards: `install-listener.sh` now `systemctl --user restart`s on every re-install (matching the
> macOS `kickstart -k` path), **and** `approval-listener.sh` re-execs itself at the top of its
> reconnect loop when its own mtime changes — the one point guaranteed to be *between* executes,
> so no in-flight approval is interrupted.

> **The subscribe stream needs a stall timeout, or a dead connection wedges remote approval
> forever — silently.** The reconnect loop above only runs when `curl` *returns*, and a TCP
> connection that dies without a FIN (dropped NAT mapping, laptop sleep, a silent middlebox)
> never gives it one: `curl` blocks in `read()` indefinitely, the loop never reaches its
> `stream closed` log line, and every Approve/Reject tap from that moment on is dropped on the
> floor. It is the worst shape of failure this plugin has: the *outbound* leg is unaffected, so
> pushes keep arriving on the phone with working-looking buttons, the log says nothing at all
> (it only writes when the stream closes), and `launchctl print` reports the job `running`.
> Observed in the wild: one `curl` alive **4h56m** having read zero bytes while five ticket
> pushes went out, `state/ntfy-listener.since` frozen nine days earlier, and no command executed
> in over a week. So the stream carries `--speed-limit 1 --speed-time ${EA_NTFY_STALL_TIMEOUT}`
> (default 300s — ntfy emits a keepalive frame about every 45s, so a healthy stream is never
> quiet that long) plus `--max-time ${EA_NTFY_STREAM_MAX_TIME}` (default 3600s) as a backstop for
> a stream that stays open but stops delivering. Tearing down a *healthy* stream is free: the
> reconnect replays from `since` and every replayed message id is deduped through
> `state/ntfy-seen.yaml`. `tests/listener-stream-stall.test.sh` pins it by serving HTTP headers
> and then going permanently silent — it hangs the unfixed listener and passes the fixed one.
> **Corollary: never add a network read to an unattended path without a stall timeout**, and
> judge liveness by a *timestamp that advances* (`ntfy-listener.since`, the poll's run-id
> receipt), never by "the process is up".

**Which copy of the plugin the service supervises (`EA_LISTENER_FROM_CACHE`).**
`install-listener.sh` defaults to supervising **its own checkout**, which is right on a
`--plugin-dir` dev box but means the listener and the interactive skills can resolve *different*
`${CLAUDE_PLUGIN_ROOT}`s — the dev repo vs. the marketplace cache — and so drift apart whenever you
commit without pushing, or push without `/plugin update`. Setting `EA_LISTENER_FROM_CACHE=1` at
install time supervises the **installed cache** copy instead, putting both on the same root.

It cannot do that by naming the cache dir in the plist/unit: that path is **version-pinned**
(`…/plugins/cache/engineer-agent/engineer-agent/<ver>`) and old versions are **retained**, so a
service naming `1.10.0` would keep running `1.10.0` forever after the next `/plugin update` —
and *silently*, because the mtime self-reexec above sees an unchanged file at an unchanged path,
which is exactly the stale-daemon failure that guard exists to prevent. So the installer generates
a **stable launcher** at `~/.local/bin/engineer-agent-listener` that resolves the highest installed
version at each launch and `exec`s it (so it leaves no wrapper process). Consequence: a new version
is picked up on the next service **restart** (`launchctl kickstart -k` / `systemctl --user restart`),
not on `/plugin update` alone and not by re-running the installer. The launcher duplicates
`resolve_installed_plugin_root()`'s few lines rather than sourcing `lib-paths.sh` — that library
lives *inside* the versioned dir being resolved; keep the two in sync.

The listener's headless execute is capped with `--max-budget-usd`, chosen **per item type** from
the draft's `type:` frontmatter: `ticket` items (which run the full `implement-ticket` coding session)
get `TICKET_BUDGET_USD` (default `8.00`); `ticket-investigation` items (a read-only research session
— pricier than a single post, cheaper than writing code) get `INVESTIGATE_BUDGET_USD` (default
`3.00`); everything else gets `DEFAULT_BUDGET_USD` (default `2.00`). Override via the
`EA_TICKET_BUDGET_USD` / `EA_INVESTIGATE_BUDGET_USD` / `EA_EXECUTE_BUDGET_USD` env vars (note none of
these are baked into the launchd plist / systemd unit, so a *supervised* listener ignores them —
only `CLAUDE_BIN` is captured at install time). A flat
`0.50` used to abort every ticket approval with "Exceeded USD budget", stranding it in `drafts/`.
Only the two exact strings `ticket` and `ticket-investigation` unlock a different cap, so untrusted
frontmatter can at worst pick among three fixed constants — never inflate spend. The comparisons are
exact (`case` globs, not prefixes), so a near-miss type like `ticket-plan` correctly gets the
default; there is a regression test pinning that. The best-effort QA generation that follows a ticket implementation
(see below) is a *separate* `claude -p` run with its own cap, `QA_BUDGET_USD` (default `2.00`,
override `EA_QA_BUDGET_USD`).

