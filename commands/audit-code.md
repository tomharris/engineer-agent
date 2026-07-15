---
description: "Scan a project for bugs and security issues; verified findings enter the review queue"
model: sonnet
argument-hint: "[subdir] [--project <slug>]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion", "Agent"]
---

# Engineer Agent: Audit Code

Proactively scan a registered project (or a subdirectory of it) for bugs and security issues. Uses a Sonnet subagent to surface candidate findings, then an Opus subagent to verify each candidate. Only verified findings (medium or high confidence) become queue items. Each emitted item triggers a ntfy push with Approve/Reject buttons (if ntfy is configured). Approving a finding creates a tracker ticket via the existing `execute-item` flow.

## Arguments

- `$ARGUMENTS` may contain an optional positional `subdir` — a path relative to the project root to limit the scan to. Defaults to the project root.
- `$ARGUMENTS` may contain `--project <slug>` to pin the scan to a specific configured project. By default the project is inferred from the current working directory.

Examples:

```
/engineer-agent audit-code                       # full scan of the current project
/engineer-agent audit-code src/auth              # scan only src/auth
/engineer-agent audit-code --project my-api      # scan another configured project
```

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

### 2. Determine Project

If `--project <slug>` is provided in `$ARGUMENTS`, use that slug and verify it exists under `projects.<slug>` in config.

Otherwise, infer the project from the current working directory by matching against `projects.<slug>.path` values. If no match, list the configured project slugs and ask the user via AskUserQuestion which project this scan belongs to (or tell them to register the current directory via `/engineer-agent add-project`).

Resolve the project root from `projects.<slug>.path`.

### 3. Resolve Scan Root

If `$ARGUMENTS` contains a positional `subdir`, join it with the project root and verify the resulting directory exists. Reject paths that escape the project root (`..` segments resolving above the root). If no `subdir`, the scan root is the project root.

### 4. Invoke the audit-code Skill

Hand off to the `audit-code` skill with the resolved project slug and scan root. The skill is responsible for:
- File enumeration with gitignore + size caps
- Sonnet find pass
- Per-finding Opus verify pass
- Writing one queue item per verified finding
- Calling `scripts/notify.sh` per emitted item

### 5. Report

When the skill returns, print:

```
Audit complete for {slug} ({scan-root-relative}):
  files scanned: N
  candidates found: N
  verified findings queued: N

Run /engineer-agent review-queue audit to review.
```
