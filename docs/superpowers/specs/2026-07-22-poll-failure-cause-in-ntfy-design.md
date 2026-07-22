# Surface the poll-failure cause in the ntfy alert

**Date:** 2026-07-22
**Status:** Approved

## Problem

`cron-poll.sh` pushes an ntfy alert when a poll fails, but the alert says *that* it failed,
not *why*. Two gaps, one per failure path:

1. **Crash path** (no/stale receipt): the cause-grep pattern misses `API Error` lines
   (the actual cause of the 2026-07-20 `ENOTFOUND` and 2026-07-21 `connection closed`
   failures), so those pushes carried only the generic `WARN: claude exited 1`. The grep
   also scans the *entire* append-only log, so when the current run produced no matching
   line, `tail -1` reports a **previous** run's error as this run's cause.
2. **Receipt path** (`status != ok`): the push says only
   `Poll finished with status=error. Check state/last-poll-receipt.yaml.` — the receipt's
   `errors:` list (e.g. the 2026-07-22 "gh CLI invocation denied approval" entries) never
   reaches the phone.

## Design

Extract the cause in plain bash from what the run already leaves behind (no prompt
changes, no new dependencies, no model-authored summary field — the crash path has no
receipt at all, so the receipt can never be the sole source).

1. **This-run log slice.** Record `LOG_START_LINE=$(wc -l < "$LOG_FILE")` before invoking
   `claude`; all cause extraction reads only `tail -n +$((LOG_START_LINE+1))`. Fixes the
   stale-match bug.
2. **Crash path:** cause-grep over the slice with
   `'API Error|Not logged in|command not found|No such file|Execution error'`, `tail -1`;
   fall back to the `WARN: claude exited N` line, then `unknown (see log)`. Truncate to
   200 chars. Message shape otherwise unchanged (already embeds `Last error: …`).
3. **Receipt path:** awk (same dependency-free style as `receipt_field`) pulls the
   `- "…"` entries under the receipt's `errors:` block. Push includes the error count and
   the first entry truncated to 180 chars:
   `Poll finished with status=error — 8 configured source(s) failed. First: <entry>. See
   state/last-poll-receipt.yaml.` Empty errors list (defensive) falls back to the current
   wording.
4. **No other behavior changes** — priorities, tags, `--fyi`, and the
   ntfy-not-configured no-op stay as they are. No CLAUDE.md/README updates needed: they
   describe when alerts fire, not their body text.

Every `grep | tail` substitution is guarded with `|| true`: under `set -euo pipefail` a
no-match grep fails the pipeline and would abort the script *before* the notify —
a latent bug in the existing crash-path grep that this change also closes.

## Alternatives rejected

- **Model-written `error_summary:` receipt field** — only helps the receipt path; adds
  model-authored text where the script currently measures.
- **Push the raw log tail** — noisy on a phone; ships more content than necessary to a
  possibly-public ntfy topic.
