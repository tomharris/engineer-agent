---
name: audit-code
description: "Scan a project (or subdirectory) for bugs and security issues. Uses a Sonnet subagent to surface candidate findings, then an Opus subagent to verify each candidate. Verified findings become code-audit-finding queue items and trigger a ntfy push if configured. Use this skill when processing an /engineer-agent audit-code invocation."
version: 1.0.0
---

# Audit a Project for Bugs and Security Issues

Orchestrate a two-pass code audit:

1. **Find pass (Sonnet):** broad scan of the scan root, emitting candidate findings across security, correctness, hardcoded secrets, and known dependency vulnerabilities.
2. **Verify pass (Opus):** per-candidate verification with the actual file content. Drops false positives and low-confidence findings.

Each surviving finding becomes a `code-audit-finding` queue item in `~/.local/share/engineer-agent/queue/incoming/`, and a ntfy push is sent (no-op if ntfy is not configured).

## Inputs

- **project_slug** — a key in `projects.<slug>` from `~/.local/share/engineer-agent/engineer.yaml`.
- **scan_root** — an absolute path inside that project's `path` (the project root by default, or a user-supplied subdir).

## Tools Needed

- `Bash` — file enumeration (`git ls-files`, `find`, `wc`), invoking `scripts/notify.sh`, computing timestamps and short ids.
- `Read` — read config, read file contents for the verify pass.
- `Write` — write queue items.
- `Glob`, `Grep` — fallback enumeration when not in a git repo.
- `Agent` — dispatch the Sonnet find pass and the Opus verify passes.

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract:
- `projects.<project_slug>.path` — required.
- `projects.<project_slug>.tracker` (or infer: `jira` section ⇒ `jira`, `github.issues` ⇒ `github-issues`, else `none`).
- `agent.notify.ntfy` — used only to know whether ntfy is configured; `scripts/notify.sh` reads the actual values itself.

If the project entry is missing, stop and report.

### 2. Enumerate Files

Build the candidate file list under **scan_root** with these rules:

- Prefer `git ls-files` when **scan_root** is inside a git working tree — it already respects `.gitignore`:
  ```bash
  cd "{scan_root}" && git ls-files
  ```
  Fall back to `find . -type f` when not in a git repo, manually excluding `node_modules`, `dist`, `build`, `.venv`, `venv`, `target`, `.git`, `__pycache__`, `.next`, `.nuxt`, `.cache`, `coverage`.
- Drop files matching binary/asset extensions: `.png .jpg .jpeg .gif .ico .pdf .zip .tar .gz .bz2 .xz .7z .mp3 .mp4 .mov .wav .woff .woff2 .ttf .otf .eot .lock .min.js .min.css .map`.
- Drop files larger than 200KB (`wc -c` per file or `find -size`).
- Cap the total enumerated set at **400** files; if the list is larger, prefer code-extension files first (`.ts .tsx .js .jsx .py .go .rb .java .kt .rs .php .cs .swift .m .mm .scala .sh .bash .yaml .yml .toml .json .sql` and the dependency manifests below) and truncate. If truncation happened, record `files_truncated: true` for the report.

Always include any dependency manifests present in the scan root: `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `requirements.txt`, `Pipfile`, `Pipfile.lock`, `poetry.lock`, `pyproject.toml`, `go.mod`, `go.sum`, `Cargo.toml`, `Cargo.lock`, `Gemfile`, `Gemfile.lock`, `composer.json`, `composer.lock`. Even if they would have been truncated, keep them in the list — the find pass needs them for the dependency-vulnerability scope.

### 3. Find Pass (Sonnet)

Dispatch a single subagent via the `Agent` tool with `subagent_type: "general-purpose"` and `model: "sonnet"`. Give it the absolute scan root, the enumerated file list (paths only), and the project's `CLAUDE.md` path (if any) for additional context.

Prompt the agent to:

- Read each file as needed (it has `Read`/`Grep`/`Glob`).
- Look for issues in four scopes:
  - **security** — OWASP-style: injection (SQL, command, template), unsafe deserialization, path traversal, SSRF, XSS, broken auth/authorization, unsafe redirects, weak crypto, insecure randomness, missing input validation at trust boundaries.
  - **correctness** — null/undefined handling, off-by-one, race conditions, unhandled errors, resource leaks (file handles, sockets, db connections), incorrect concurrency, dead code paths that mask bugs.
  - **secret** — hardcoded API keys, tokens, passwords, private keys committed to the repo (only flag values that look real — high entropy strings, recognizable token prefixes; do not flag placeholders like `"your-api-key-here"`).
  - **dependency** — packages in the dependency manifests with publicly-known CVEs or well-known abandoned/insecure versions. Be conservative: only flag when the version is unambiguously vulnerable.
- Skip stylistic issues, performance micro-optimizations, missing tests, and anything that is not a clear defect or risk.
- Return **only** a JSON array on stdout (no prose around it). Each element:
  ```json
  {
    "file": "relative/path/from/scan_root",
    "line_range": "42-58",
    "category": "security|correctness|secret|dependency",
    "severity": "critical|high|medium|low",
    "title": "Short imperative title",
    "description": "1-3 sentence explanation of the issue",
    "evidence_snippet": "the offending code lines, verbatim"
  }
  ```
- Hard cap: emit at most **30** candidates total. If more were found, keep the highest severity ones.

Parse the JSON. If parsing fails, log the raw output to `~/.local/share/engineer-agent/state/audit-code.log` and stop with an error — do not proceed to the verify pass on garbage input.

### 4. Verify Pass (Opus)

For each candidate (in parallel where possible — up to 4 concurrent `Agent` tool calls per message):

Dispatch a subagent via the `Agent` tool with `subagent_type: "general-purpose"` and `model: "opus"`. Provide:
- The full candidate JSON.
- The path to the file referenced.
- The project root and `CLAUDE.md` path (so it can read framework/library context if needed).

Prompt the agent to:

- Read the cited file and surrounding code as needed.
- Decide whether the issue is real. Specifically reject:
  - Issues already mitigated by surrounding code (e.g., the value is sanitized upstream, the path is constructed from a constant).
  - Issues in code that is clearly test fixtures, example/sample code, or documentation snippets.
  - Issues where the "secret" is obviously a placeholder, environment-variable reference, or test-only value.
  - Dependency findings where the actual installed version is not in fact vulnerable.
- Return **only** a JSON object on stdout:
  ```json
  {
    "verified": true,
    "confidence": "high|medium|low",
    "reasoning": "Why this is (or isn't) a real issue",
    "refined_title": "Improved short title",
    "refined_description": "Cleaner description, 1-3 sentences",
    "suggested_fix": "Concrete remediation steps"
  }
  ```

Drop any result where `verified` is `false` **or** `confidence` is `low`. Survivors carry their Opus-refined title/description/fix forward.

### 5. Emit Queue Items

For each verified finding, write a file to `~/.local/share/engineer-agent/queue/incoming/` named:

```
{YYYYMMDD-HHmmss}-code-audit-finding-{shortid}.md
```

Where `{shortid}` is the first 7 characters of `sha1(file + ":" + line_range + ":" + title)`.

File contents:

```markdown
---
type: code-audit-finding
source: audit
source_url: ""
source_id: "{file}:{line_range}"
title: "{refined_title}"
priority: "{urgent if severity=critical, normal if high/medium, low if low}"
created_at: "{ISO 8601 UTC}"
status: incoming
project: "{project_slug}"
audit_category: "{security|correctness|secret|dependency}"
audit_severity: "{critical|high|medium|low}"
audit_confidence: "{medium|high}"
audit_file: "{file}"
audit_line_range: "{line_range}"
---

## Context

**File:** `{file}:{line_range}`
**Category:** {audit_category}
**Severity:** {audit_severity}
**Confidence:** {audit_confidence}

### Why this is an issue

{refined_description}

### Verifier reasoning

{reasoning}

### Evidence

```
{evidence_snippet}
```

## Draft Response

### Proposed ticket

**Title:** [{audit_category}/{audit_severity}] {refined_title}

**Body:**

{refined_description}

**Location:** `{file}:{line_range}`

**Suggested fix:**

{suggested_fix}

**Source:** Generated by `/engineer-agent audit-code` (Sonnet candidate, Opus verified, confidence {audit_confidence}).
```

`source_url` is intentionally empty — there is no upstream URL for an audit finding. `execute-item` uses the `## Draft Response` body verbatim when creating the tracker ticket.

### 6. Notify

For each emitted queue file, invoke `scripts/notify.sh`. Resolve the plugin scripts directory from `${CLAUDE_PLUGIN_ROOT}` (set by the harness when this skill runs) — fall back to the directory containing this skill if the env var is unset (`{this-skill-dir}/../../scripts/notify.sh`).

```bash
${PLUGIN_ROOT}/scripts/notify.sh \
  --title "code-audit-finding: {refined_title}" \
  --message "{project_slug} — {audit_category}/{audit_severity} in {file}" \
  --priority "{priority from frontmatter}" \
  --item-id "{queue filename, with .md}" \
  --source-url "" \
  --tags "mag,warning"
```

`notify.sh` no-ops safely when ntfy is unconfigured, so always call it. Pass `--source-url ""` — the script then omits the Open button but still publishes the Approve/Reject actions.

### 7. Return Summary

Return to the caller a structured summary the command can format:

```
files scanned: N
candidates found: N
verified findings queued: N (dropped: not-verified=A, low-confidence=B)
files_truncated: true|false
```

Also append a one-line entry to `~/.local/share/engineer-agent/state/audit-code.log` with timestamp, project, scan root, and counts.

## Error handling

- If the Sonnet pass returns invalid JSON: stop, log, surface the error. Don't fabricate candidates.
- If an Opus verify call fails for a single candidate: skip that candidate (treat as "not verified"), log the failure, continue with the rest.
- If `scripts/notify.sh` fails: continue — `notify.sh` already swallows its own ntfy failures. Only abort if the script itself is missing/unexecutable, in which case warn and keep emitting queue items.
