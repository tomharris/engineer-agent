---
name: codify-learnings
description: "Scan recent completed/rejected queue work for recurring friction and discoveries, and draft candidate learnings (memory files, skill notes, or CLAUDE.md additions) into the review queue. Use this skill when processing an /engineer-agent codify invocation."
version: 1.0.0
model: sonnet
---

# Codify Learnings

Turn recurring in-session discoveries into compounding, reusable assets. This skill only
*drafts* candidates into the approval queue — nothing is written to a memory file, skill, or
CLAUDE.md until a human approves the candidate via `/engineer-agent review-queue` (which
delegates the write to `execute-item`).

## Tools Needed

- `Read` — read config and queue items
- `Glob` — find queue items by date
- `Grep` — scan item bodies for friction signals
- `Bash` — date math, aggregation
- `Write` — write candidate drafts

## Input

An `/engineer-agent codify` invocation, optionally with `--since <date>|last-week` (default:
last 7 days) and `--project <slug>`.

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract the `projects` map (each entry's
`path` and slug). If missing, stop and tell the user to run `/engineer-agent setup`.

### 2. Scan Recent Work

Determine the cutoff date from `--since` (default: 7 days ago). Using the same date-scan
approach as `generate-digest`, glob `~/.local/share/engineer-agent/queue/completed/` and
`~/.local/share/engineer-agent/queue/rejected/` for items created since the cutoff (filter by
`--project` if given). For each item, read the body — especially the
`### Findings & Disposition` ledger, `### Remaining Work`, rejection reasons, and any
debugging or environment notes.

### 3. Cluster into Candidate Learnings

Look for **recurring** signals worth codifying — the value is in things seen more than once or
that cost real time, not one-offs:

- The same class of bug or friction across multiple items (e.g. a repeated environment
  workaround, a debugging technique that keeps getting rediscovered).
- Rejection reasons that reveal a missing convention or a wrong default.
- A non-obvious procedure that worked and should be repeatable.

Discard anything already captured (check the target project's `CLAUDE.md`, its `memory/`
index, and existing skill notes before proposing a duplicate — update-in-place beats a new
duplicate).

### 4. Classify Each Candidate

For each surviving learning, choose exactly one target:

- **memory-file** — a durable fact, preference, or project constraint. Target the memory dir
  for the relevant project's cwd (Claude Code project memory:
  `~/.claude/projects/<encoded-project-path>/memory/`). Content follows the memory file
  convention: frontmatter (`name`, `description`, `metadata.type` of
  `user|feedback|project|reference`) + a one-fact body, plus a one-line pointer for
  `MEMORY.md`.
- **skill-note** — a reusable procedure or gotcha that belongs in an existing skill. Target
  the specific `skills/<name>/SKILL.md` and propose the exact text to append (e.g. a new
  edge-case bullet).
- **claude-md** — a team convention or architecture decision. Target the project's
  `CLAUDE.md` (`projects.<slug>.path`/CLAUDE.md) and propose the exact addition.

### 5. Draft One Candidate per Learning

Write each candidate as a queue item in `~/.local/share/engineer-agent/queue/drafts/`.

**Filename:** `{YYYYMMDD-HHmmss}-codify-{short-slug}.md`

```yaml
---
type: codify-candidate
source: internal
source_id: "codify-{short-slug}"
title: "{one-line summary of the learning}"
priority: low
created_at: "{current_iso_timestamp}"
status: drafted
project: "{slug or _global}"
codify_target: "memory-file | skill-note | claude-md"
codify_path: "{absolute target file path}"
---

## Context

Recurring signal observed across {N} items since {cutoff}:
- {item ref} — {what happened}
- {item ref} — {what happened}

Why it's worth codifying: {the compounding value}.

## Draft Response

### Proposed change to `{codify_path}` ({codify_target})

{The exact content to write:}
{- memory-file: the full file content (frontmatter + body) AND the MEMORY.md pointer line}
{- skill-note: the exact text to append and where (which section)}
{- claude-md: the exact addition and where it goes}
```

The `codify_target` + `codify_path` + `## Draft Response` are what `execute-item` uses to
perform the local file write on approval.

### 6. Report

Report: "Drafted {N} codify candidates ({X} memory-file, {Y} skill-note, {Z} claude-md).
Review with `/engineer-agent review-queue` before anything is written." If no recurring
signals were found, report that and write no drafts.
