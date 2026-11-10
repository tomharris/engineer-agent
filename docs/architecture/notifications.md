# Notifications and remote approval

## Notifications & Remote Approval

ntfy turns the approval gate into a remote, async one without a custom server. Both directions are ntfy topics:

- **Outbound** (`topic`): after a poll, `cron-poll.sh` calls `scripts/notify.sh` to push each new draft with **Approve / Reject / Open** action buttons.
- **Inbound** (`command_topic`): the Approve/Reject buttons are ntfy `http` actions that POST `approve|<item-id>` / `reject|<item-id>` back to the command topic. `scripts/approval-listener.sh` (a long-running service installed by `scripts/install-listener.sh`) streams that topic and runs `/engineer-agent execute <item-id> <decision>` headlessly (an approved `ticket` takes the separate confined-implementation path instead — see "Confined headless ticket implementation"). After validating a command the listener also pushes two best-effort acknowledgements back to the outbound `topic` via `notify.sh --fyi`: a **receipt** ack (low priority, "📨 Received…") the moment the tap lands, and an **outcome** ack after the run — "✅ Done…" (normal) when the item leaves `queue/drafts/`, or "⚠️ Failed…" (urgent) when it did not. Invalid or already-seen commands are not acknowledged (avoids noise and confirming a live listener to a prober). The ack adds no posting capability — it is an outbound notification only, so the "polling reads; only execute-item writes" invariant is untouched.

> **`handle_line` dispatches SYNCHRONOUSLY, so a long run makes the listener look dead — the
> receipt has to say so.** The dispatch happens inside the stream read loop, so for the whole
> duration of an approved `ticket` / `ticket-investigation` session (minutes) nothing is read off
> the command topic: a second tap gets no response of any kind, not even a 📨. Every outward sign
> matches a wedged stream (the job prints `running`, outbound pushes keep arriving with working
> buttons, the log is quiet), which is the one failure shape this plugin has most trained itself to
> fear — so it gets misdiagnosed as the stall bug. The receipt for those two types therefore names
> the expected duration *and* what happens to a tap sent meanwhile: it sits in the stream and is
> replayed from `since` on the next reconnect, deduped through `state/ntfy-seen.yaml`, so it is
> delayed rather than lost. This is a *legibility* fix, not a concurrency one — the queueing
> behavior is unchanged.

### Turn-completion pushes (opt-in)

`implement-ticket` is the longest thing this plugin runs, and until you approve it nothing tells
you how it is going: the headless path sends one ✅/⚠️ after the *whole* run, and the interactive
path (`/engineer-agent:implement-ticket`) sent nothing at all. Setting
`agent.notify.turn_completions: true` pushes an FYI at the **end of every turn** — done, blocked,
pausing to ask you something, or dead on an API error.

It is a **Claude Code hook**, not a `notify.sh` line in the skill, and that distinction is the
whole point. This repo has learned twice over that a model's own report is not a completion signal
(hence the run-id receipt in `cron-poll.sh` and the `drafts/` existence check in the listener). A
prompt instruction fires only when the model chooses to — so it would go quiet on exactly the turns
worth hearing about: budget abort, API error, an early bail. `hooks/hooks.json` registers
`scripts/turn-notify-hook.sh` on five events and the harness fires them regardless.

**Arm → fire → disarm**, because a plugin-wide `Stop` hook otherwise runs on every turn of every
project of everyone who has the plugin enabled:

| | Armed by | Disarmed by |
|---|---|---|
| Interactive | `UserPromptSubmit` matching `^/engineer-agent[: ]implement-ticket` (primary — the literal text typed), or `PreToolUse:Skill` where `tool_input.skill` is `engineer-agent:implement-ticket` (backstop). Writes `state/turn-notify/<session_id>` | `SessionEnd`; plus a 24h prune on the arm path for sessions that crashed |
| Headless | `EA_TURN_NOTIFY=1`, set **inline** on the one `claude -p` in `run_ticket_implementation` — no file, no session correlation, nothing orphaned | process exit |

Two independent interactive arms exist because the namespaced `engineer-agent:implement-ticket`
form is only *guaranteed* while a same-named user-level skill forces disambiguation. Delete that
skill and the plugin's could be invoked bare, silently killing the `PreToolUse` arm — the prompt
matcher still catches it. Deliberately **out of scope:** a bare `implement-ticket`, which is
somebody else's skill.

**Default OFF, and the gate is checked at *arm* time only.** `hooks/hooks.json` registers
unconditionally on the next `/plugin update`, so the behavior change has to be consented to even
though the registration isn't — the same deny-by-default posture as `agent.autonomy.auto_execute`
and `exec.allowed_commands`. Checking the config only when arming is also what keeps the fire path
free: an unarmed session costs one `cat`, one `test -d` and one glob, with no config read, no awk,
no jq, no network.

**Three invariants in `turn-notify-hook.sh`, each guarding a different foot-gun:**
- **Always `exit 0`, never write stdout.** Exit 2 on `Stop` *blocks the turn from ending* and
  forces the model to continue; on `PreToolUse` it denies the tool; on `UserPromptSubmit` it blocks
  the prompt — and `UserPromptSubmit` stdout on exit 0 is **injected into the model's context**. So
  no `set -e`, no stray `echo`; diagnostics go to `state/turn-notify.log` under
  `EA_TURN_NOTIFY_DEBUG=1`.
- **jq is a soft dependency.** `cron-poll.sh` makes "deliberately NOT jq" policy for anything
  outside the separately-installed listener, and a plugin-wide hook is even more exposed. Every
  field used to *decide whether to push* is escape-free by construction (uuid / enum / skill slug /
  anchored raw-JSON prefix) and is read with `sed`. jq is used for exactly one thing — decoding
  `last_assistant_message` for the excerpt — so no jq means a label-only push, never a broken hook.
- **Nothing tappable reaches the phone.** No `--source-url` is passed, so there are no action
  buttons and no Open link, and `sanitize_text` replaces every `scheme://` URL, `www.` host and
  `mailto:` with `(link)` before anything hits the wire. The excerpt is model-authored text
  ultimately derived from untrusted ticket/PR/Slack bodies, and ntfy's mobile clients autolink URLs
  in the message body — so without this an injected line could render a tappable link inside a
  notification arriving on the very topic you have trained yourself to trust for Approve/Reject,
  aimed at you while you are away from your desk. *Residual, accepted:* a bare `evil.tld` with no
  scheme can still be autolinked by some clients; neutralizing that would also destroy `notify.sh`
  and `SKILL.md`, and the excerpt is the model's own summary rather than a quote.

Capped at `EA_TURN_NOTIFY_MAX` (40) pushes per session, with one "🔕 muted" push at the boundary so
the silence is explained. `EA_TURN_NOTIFY_ENABLED` overrides the config key either way — set it to
`0` in the listener's environment to disable just the headless leg. Hook registrations are read at
session start, so an existing install needs `/plugin update engineer-agent` (or a new session);
the listener's own mtime self-reexec covers `approval-listener.sh` but not this.


(The `generate-qa` skill, when the app is reachable at `qa.base_url`, also runs its generated script and fixes failing scripted tests in place — fixing test defects but leaving genuine code-bug failures as reported findings, never demoting them to the manual checklist; best-effort, it skips execution and reports when the app is unreachable.) `scripts/lib-ntfy.sh` is the shared config reader sourced by `notify.sh` and `approval-listener.sh`.

**Security:** on public `ntfy.sh` a topic name is effectively a password (the `command_topic` can trigger Slack posts / PR creation). Use high-entropy names, set `auth_token`, and/or self-host via `server`. The listener also defends in depth: it only accepts `approve`/`reject`, only item ids matching `^[A-Za-z0-9._-]+$`, and only acts on items still in `queue/drafts/` (idempotent via `state/ntfy-seen.yaml`).

