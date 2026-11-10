---
description: "List, run, pause, or resume scheduled jobs (per-project, per-integration work on its own interval)"
argument-hint: "[list | run <project>.<id> | pause <project>.<id> | resume <project>.<id>]"
allowed-tools: ["Bash", "Read"]
---

# Engineer Agent: Scheduled Jobs

Scheduled jobs are defined under `projects.<slug>.jobs` in `~/.local/share/engineer-agent/engineer.yaml`
and dispatched every minute by `scripts/jobs-tick.sh` (installed with `scripts/install-jobs.sh`). They
run alongside the global poll, not instead of it.

If the config file is missing, tell the user to run `/engineer-agent setup` and stop.

## Steps

Parse `$ARGUMENTS`. With no arguments, use `list`.

Run exactly one of:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/jobs-ctl.sh list
${CLAUDE_PLUGIN_ROOT}/scripts/jobs-ctl.sh run <project>.<id>
${CLAUDE_PLUGIN_ROOT}/scripts/jobs-ctl.sh pause <project>.<id>
${CLAUDE_PLUGIN_ROOT}/scripts/jobs-ctl.sh resume <project>.<id>
```

Print the output. **Do not recompute any of it.**

- `list`: each job's kind, interval, state (`idle` / `running` / `paused` / `invalid`), last run with
  its receipt status, and next due time. An `invalid` job prints its reason; a job whose last receipt
  is not `ok` prints its first error. Both are worth pointing out.
- `run`: runs the job now in the foreground, ignoring `every` and `hours`/`days` but not pause,
  validation or the lock, and prints the receipt. A `slack` / `watch` run may start a drafting model
  session if it finds anything.
- `pause` / `resume`: `resume` also clears the failure streak. A job pauses itself after
  `guards.pause_after_failures` consecutive failed runs (default 3) and pushes one alert.

If `list` shows no jobs, point the user at the `jobs:` example in `config/engineer.example.yaml` and
at `scripts/install-jobs.sh`.
