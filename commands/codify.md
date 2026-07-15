---
description: "Capture recurring in-session learnings back into memory files, skill notes, or CLAUDE.md"
model: sonnet
argument-hint: "[--since <YYYY-MM-DD>|last-week] [--project <slug>]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep"]
---

# Engineer Agent: Codify Learnings

Scan recent completed/rejected work for recurring friction and discoveries, and draft
candidate learnings — memory files, skill notes, or CLAUDE.md additions — into the review
queue. This converts one-off in-session discoveries into compounding, reusable assets.

## Arguments

- `$ARGUMENTS` may contain `--since <YYYY-MM-DD>` or `--since last-week` to set the scan
  window. Default: the last 7 days.
- `$ARGUMENTS` may contain `--project <slug>` to restrict candidates to one project.

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. If missing, tell the user to run
`/engineer-agent setup` and stop.

### 2. Generate Candidates

Follow the `codify-learnings` skill behavior: scan the queue since the cutoff, cluster
recurring signals into candidate learnings, and draft each as a `codify-candidate` queue item
in `~/.local/share/engineer-agent/queue/drafts/`.

### 3. Report

Report how many candidates were drafted and remind the user to review them:
"Drafted {N} codify candidates. Review with `/engineer-agent review-queue` — approving one
writes the memory file / skill note / CLAUDE.md edit; rejecting writes nothing."
