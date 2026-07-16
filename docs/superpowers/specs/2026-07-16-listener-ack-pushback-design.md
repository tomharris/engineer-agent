# Design: acknowledgement push-back in the ntfy approval listener

**Date:** 2026-07-16
**Status:** Approved
**Component:** `scripts/approval-listener.sh`

## Problem

`scripts/approval-listener.sh` streams the ntfy `command_topic`, and when an
Approve/Reject button tap arrives it runs a headless `/engineer-agent execute`
via `claude -p`. The listener logs `done` / `WARN` locally but pushes nothing
back to the user's phone. From the user's side an ntfy button tap is
fire-and-forget: there is no confirmation the tap landed, no signal while the
10–60+ second execute run is in flight, and no report of whether the action
actually succeeded. The user is left guessing.

## Goal

When the listener receives a valid approve/reject command, push an
acknowledgement back to the user via ntfy at two moments:

1. **Receipt** — immediately when the tap lands, before the execute run.
2. **Outcome** — after the run completes, reporting success or failure.

## Non-goals

- No new outbound capability or topic. Acknowledgements go to the existing
  outbound `topic` (what the phone subscribes to), never to `command_topic`.
- No changes to `notify.sh` or `lib-ntfy.sh` — the needed building block
  (`notify.sh --fyi`, a button-less confirmation) already exists.
- No `Open` button on the outcome ack.
- No acknowledgement for invalid or already-seen messages.

## Mechanism

Reuse `notify.sh --fyi`, which publishes a button-less notification to the
outbound `topic`. The listener gains one small best-effort helper:

```
push_ack <priority> <title> <message>
```

`push_ack` shells out to `${PLUGIN_ROOT}/scripts/notify.sh --fyi` with the given
title/message/priority and is invoked so that a failed push never disturbs the
reconnect loop. `notify.sh` already exits 0 on publish failure and when no
outbound `topic` is configured, so installs without ntfy fully configured keep
working unchanged; the helper adds a `|| true`-style guard as belt-and-braces.

## Push points

Both wrap the existing execute call inside `handle_line`.

### 1. Receipt ack

- **Where:** right after validation passes and *before* the `claude -p` run —
  after the existing `log "executing: ${decision} ${item} …"` line, alongside
  the `SEEN_FILE` / `SINCE_FILE` writes.
- **Content:** title `engineer-agent`, message
  `📨 Received: ${decision} ${item} — working…`.
- **Priority:** `low` (transient reassurance).

### 2. Outcome ack

- **Where:** inside the authoritative post-run drafts/ check that already
  distinguishes done from failed.
- **Success branch** (item left `queue/drafts/`): message
  `✅ Done: ${decision} ${item}`, priority `normal`.
- **Failure branch** (item still in `queue/drafts/`): message
  `⚠️ Failed: ${decision} ${item} — still queued, re-run`, priority `urgent`
  so it stands out.

The outcome ack reads the same filesystem signal (file present in
`queue/drafts/`) that the existing `done` / `WARN` log lines trust, so the
notification can never disagree with the log.

## Deliberately not acknowledged

- **Invalid messages** — bad decision (`case` default at ~line 71–74) and
  filename-allowlist failures (~line 75–78). These originate from bugs or a
  prober poking the command topic; acking them is noise to the legitimate user
  and confirms a live listener to a prober. Existing `log` + `SEEN_FILE`
  handling is unchanged.
- **Already-seen dedup hits** (~line 65). Silent, as today.

## Security notes

- Acks are published to the outbound `topic`, a different secret than
  `command_topic`. An attacker posting garbage to `command_topic` cannot
  observe the outbound topic and gains nothing; declining to ack invalid
  messages avoids amplifying prober traffic into user-visible noise.
- No posting capability is added. An acknowledgement is an outbound
  notification only, so the "polling reads; only execute-item writes" invariant
  is untouched.

## Failure isolation

`push_ack` is best-effort: a curl/ntfy hiccup must never crash or stall the
listener's reconnect loop. This matches the posture of the rest of the notify
path (`notify.sh` never fails its caller).

## Testing

- **Receipt then outcome (happy path):** simulate a valid `approve|<id>`
  message; assert two `notify.sh` invocations occur in order (low-priority
  receipt, then normal-priority done) with the expected messages.
- **Failure path:** force the item to remain in `queue/drafts/`; assert the
  outcome ack is the urgent "Failed" variant.
- **Invalid message:** send a bad decision / bad item id; assert no `push_ack`
  fires and existing log + SEEN_FILE behavior is intact.
- **ntfy unavailable / topic unset:** assert the listener loop continues and
  the execute path is unaffected when `push_ack` / `notify.sh` cannot publish.

Because `push_ack` is a thin wrapper over `notify.sh`, tests can stub
`notify.sh` (or `PLUGIN_ROOT`) with a recording shim and assert on the captured
argument vectors.

## Documentation

Update the "Notifications & Remote Approval" section of `CLAUDE.md` and the
corresponding `README.md` section to note that the listener now pushes a
receipt ack and an outcome ack back to the outbound topic for each valid
approve/reject command.
