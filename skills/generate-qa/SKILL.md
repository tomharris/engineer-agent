---
name: generate-qa
description: "Generate a QA test plan from a queue item containing ticket acceptance criteria and branch code changes. Use this skill when processing a qa-test-plan queue item."
version: 1.0.0
model: sonnet
---

# Generate QA Test Plan

Generate a hybrid QA test plan (runnable script + manual checklist) from ticket acceptance criteria and branch code changes using a two-pass analysis.

## Tools Needed

- `Read`, `Write` — read/write queue items and project files
- `Grep`, `Glob` — search codebase for route definitions and project structure
- `Bash` — run `git diff` and other git commands

## Input

A queue item file in `~/.claude/engineer-agent/queue/incoming/` with `type: qa-test-plan`. The `## Context` section contains:
- Ticket details (acceptance criteria, testing notes, description)
- PR description and testing notes (if a PR exists)
- Full git diff of the branch changes
- Changed file list

## Steps

### Pass 1 — Mechanical Extraction

#### 1.1. Read Queue Item

Read the queue item file. Extract from `## Context`:
- `### Acceptance Criteria` — the testable requirements from the ticket
- `### Testing Notes` — any testing guidance from the ticket or PR
- `### PR Testing Notes` — testing notes from the PR description (if present)
- `### Changed Files` — the `git diff --name-status` output
- `### Diff` — the full `git diff` output
- `branch` and `base` from frontmatter

#### 1.2. Read Project Config

Read `~/.claude/engineer-agent/engineer.yaml`. Extract for the queue item's `project`:
- `projects.<project>.qa.base_url` (required — if missing, use `http://localhost:3000` and flag a warning)
- `projects.<project>.qa.console_command` (optional)
- `projects.<project>.path` (project root path)

#### 1.3. Classify Changed Files

For each file in the changed files list, classify by path patterns. Use `Glob` against the project root to discover the project's directory structure and refine classification.

Categories:
- **api** — files matching patterns like `app/controllers/**`, `src/controllers/**`, `routes/**`, `src/api/**`, `src/routes/**`, `app/api/**`, `**/endpoints/**`
- **service** — files matching `app/services/**`, `src/services/**`, `lib/**`, `src/lib/**`, `app/workers/**`, `app/jobs/**`
- **model** — files matching `app/models/**`, `src/models/**`, `db/migrate/**`, `prisma/**`, `**/migrations/**`, `**/schema*`
- **view** — files matching `app/views/**`, `src/components/**`, `templates/**`, `app/assets/**`, `src/pages/**`, `public/**`
- **config** — files matching `config/**`, `.env*`, `docker-compose*`, `Dockerfile*`, `*.config.*`
- **test** — files matching `test/**`, `spec/**`, `__tests__/**`, `*_test.*`, `*_spec.*`, `*.test.*`, `*.spec.*`

If a file doesn't match any pattern, classify as `service` (conservative default — it will get a REPL test suggestion rather than being silently ignored).

#### 1.4. Extract Routes from API File Diffs

For each file classified as `api`, scan the diff for added or modified route definitions. Look for framework-specific patterns:

- **Rails:** `get`, `post`, `put`, `patch`, `delete`, `resources`, `resource` calls in routes; action methods in controllers
- **Express/Fastify:** `router.get()`, `router.post()`, `app.get()`, etc.
- **Django:** `path()`, `url()` patterns in urls.py; view function/class definitions
- **FastAPI:** `@app.get()`, `@router.post()`, etc.
- **Phoenix:** `get`, `post`, `put`, `patch`, `delete`, `resources` in router
- **Spring:** `@GetMapping`, `@PostMapping`, `@RequestMapping`, etc.

For each extracted route, record: `{http_method, path, controller/handler, is_new (added vs modified)}`.

#### 1.5. Validate Routes

Read the project's route definition file(s) to confirm extracted routes exist. Look for:
- `config/routes.rb` (Rails)
- `src/routes/**`, `routes/**`, `app/routes/**` (Express/Fastify)
- `**/urls.py` (Django)
- Files containing `@app.get`, `@router` (FastAPI)
- `lib/*_web/router.ex` (Phoenix)

For each extracted route:
- If found in route definitions → mark as **validated**
- If the route was added in the current diff (new route) → mark as **validated** (it exists in the diff itself)
- If not found → mark as **unvalidated** and add a `# VERIFY: route may not exist at this path` comment to the generated curl command

#### 1.6. Extract Method Signatures from Service Diffs

For each file classified as `service`, scan the diff for added or modified public method signatures:
- **Ruby:** `def method_name` (not starting with `_`)
- **Python:** `def method_name` (not starting with `_`)
- **JavaScript/TypeScript:** `function name()`, `async function name()`, `name()`, `async name()`, exported functions
- **Java/Kotlin:** `public` method declarations
- **Go:** exported functions (uppercase first letter)

Record: `{class_or_module, method_name, parameters, is_new}`.

#### 1.7. Read Existing Test Changes

For each file classified as `test`, read the diff to extract:
- New or modified test names (e.g., `it "should ..."`, `test("...")`, `def test_...`)
- What behavior they appear to cover

These become "Already Covered by Tests" items — the reviewer should confirm they pass rather than duplicating test effort.

#### 1.8. Build Inventory

Compile the Pass 1 results into a structured inventory:

```
inventory = [
  { category: "api", file: "app/controllers/users_controller.rb", items: [
    { type: "route", method: "POST", path: "/api/users", handler: "create", is_new: true, validated: true }
  ]},
  { category: "service", file: "app/services/user_service.rb", items: [
    { type: "method", class: "UserService", name: "create_with_invite", params: "(email, role)", is_new: true }
  ]},
  { category: "test", file: "spec/services/user_service_spec.rb", items: [
    { type: "test", name: "creates user and sends invite email", covers: "UserService#create_with_invite" }
  ]},
  ...
]
```

### Pass 2 — Semantic Organization & Gap-Filling

#### 2.1. Parse Acceptance Criteria

Split the acceptance criteria from the ticket into individual testable items. Each AC should be a discrete, verifiable statement. Number them sequentially (AC1, AC2, ...).

If the ticket has no explicit acceptance criteria, derive them from:
1. The ticket description (look for "should", "must", "can", "will")
2. The PR description
3. As a last resort, infer from the code changes themselves — but flag these as "inferred, not from ticket"

#### 2.2. Map ACs to Inventory

For each acceptance criterion, find the matching items in the Pass 1 inventory:

- **AC maps to API route(s):** Generate curl test cases:
  - One **happy path** curl command with realistic sample data
  - One **edge case** curl command derived from the AC wording (e.g., if AC says "validate email", test with an invalid email)
  - Include appropriate headers (Content-Type, Authorization placeholder)
  - Use `$BASE_URL` variable
  - Add `-w "\n%{http_code}"` for status code checking
  - Include `# Expected: {status_code}` comment after each curl

- **AC maps to service method(s) only (no API route):** Generate REPL/console snippet:
  - Use the project's `console_command` if configured
  - Show the method call with sample arguments
  - Include `# Expected: {expected_result}` comment

- **AC maps to view/UI changes only:** Add to manual checklist:
  - What page/component to navigate to
  - What to look for or verify
  - Any specific interactions to try

**Principle — never punt scripted tests to manual.** An AC that maps to an API route or service method gets a *scripted* test. If generating or running that scripted test is hard (unvalidated route, a failure on first run, etc.), it is resolved in the Pass 3 run-and-fix loop below — it is **never** relocated into the manual checklist to avoid dealing with it. The manual checklist is only for ACs that are genuinely UI/judgment-only.

- **AC maps to nothing in inventory:** Flag as:
  - `**AC {N}: {text}** — untested: no matching code change found. This may be out of scope for this branch, or the implementation may be missing.`

#### 2.3. Flag Unmapped Changes

For any inventory items (files, routes, methods) that no AC covers, add them to an "Unmapped Changes" section:
- `**{file}** — {description of change}. Verify: {what to check}`

This catches scope creep or missing acceptance criteria.

#### 2.4. Generate Regression Section

For routes that were **modified** (not new) — the `is_new: false` items from Pass 1:
- Generate a basic curl command confirming the endpoint still responds with expected status
- These go in a "Regression" section at the end of the test script

#### 2.5. Compose Test Script

Build the `qa-test.sh` script content:

```bash
#!/usr/bin/env bash
# QA Test Plan for {ticket-key}: {title}
# Generated: {timestamp}
# Branch: {branch}
# Base: {base}

set -o pipefail

BASE_URL="${BASE_URL:-{base_url}}"
PASS=0
FAIL=0

check() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $description (got $actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description (expected $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "=== AC1: {acceptance criterion text} ==="
echo ""

echo "Test 1.1: {happy path description}"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" {curl_args} "$BASE_URL/api/...")
check "{happy path description}" "200" "$STATUS"

echo "Test 1.2: {edge case description}"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" {curl_args} "$BASE_URL/api/...")
check "{edge case description}" "422" "$STATUS"

# ... repeat for each AC with automatable tests ...

echo ""
echo "=== Regression ==="
echo ""

echo "Regression 1: {existing endpoint still works}"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/...")
check "{existing endpoint still works}" "200" "$STATUS"

echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

#### 2.6. Compose Manual Checklist

Build the manual checklist markdown:

```markdown
### Manual Checklist

#### Acceptance Criteria Checks
- [ ] **AC {N}: {text}** — {what to verify and where}

#### Unmapped Changes (not covered by acceptance criteria)
- [ ] **{file}** — {description of change}. Verify: {what to check}

#### Already Covered by Tests
- [x] {test name} in {test file} — covers {what}

#### Regression Checks
- [ ] {existing behavior} — still works after changes
```

### Pass 3 — Execute & Fix Loop

Run the scripted tests and fix failing ones in place. The goal: every scripted (curl) test either passes or is left failing for a deliberate, recorded reason — never abandoned, never demoted to the manual checklist.

**Scope:** this loop runs the bash/curl script from step 2.5 only. The REPL/console snippets (service-only ACs) stay as guidance the reviewer runs by hand — the console is interactive and not reliably scriptable.

#### 3.1. Materialize the Script

Write the composed `qa-test.sh` to a temp file under the session scratchpad directory so it can be executed. Keep this file in sync with any fixes you make in the loop — the final, corrected version is what goes into the Draft Response (step 4).

#### 3.2. Reachability Precheck

If the script contains no executable curl tests (everything is UI/manual or REPL-only), skip the rest of Pass 3 and record execution status `not executed — no scripted tests`.

Otherwise probe the host once:

```bash
curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BASE_URL"
```

If the connection is refused or the host is unresolvable (curl exits non-zero / no HTTP code), **abort the loop**: leave the generated script unchanged, record execution status `not executed — app unreachable at {base_url}`, and skip to step 4. Do not attempt to "fix" tests against a dead endpoint, and do not move anything to the manual checklist.

> The loop cannot start the app or obtain credentials itself — there is no config or convention for that. It is strictly best-effort against whatever is already running at `base_url`.

#### 3.3. Run

Execute the script and capture the per-test `PASS`/`FAIL` lines and the summary:

```bash
bash {scratchpad}/qa-test.sh
```

The script already exits non-zero on any failure via its `check`/`[ "$FAIL" -eq 0 ]` harness. If every test passes, record `ran — {N} passed / 0 failed` and go to step 4.

#### 3.4. Diagnose Each Failure

Classify each failing test into **exactly one** of these, and act accordingly:

- **Test defect → fix the test, then re-run.** The test itself is wrong. Examples:
  - Wrong path (404 because the route path is off) — correct it against the validated route definitions from step 1.5.
  - Placeholder/missing auth producing 401/403 — supply a real token only if one is plainly derivable from the project; otherwise treat as an env limitation (below).
  - Expected status disagrees with the AC — correct the expectation to what the **AC** specifies.
  - Invalid happy-path sample data triggering an unintended validation error — fix the request body.
  - Malformed curl (quoting, headers, Content-Type) — fix the command.

- **Real code bug → do NOT touch the test.** The request is correct and the AC says behavior X but the app does Y. Leave the test failing and record a finding: which AC/file, expected vs. actual, and why this is a code issue rather than a test issue.

- **Env limitation → leave the test in place, mark not-executed.** The test can't run meaningfully because auth is required and no token is configured or derivable (or a dependency is missing). Don't demote it to manual, and don't fix it against a dead path. Record it as `not executed — {reason}`.

**Hard guardrail:** never rewrite an `expected` value to match the observed `actual` just to make a test go green. Expectations come from the acceptance criteria, not from the app's current behavior. "Make it pass" is only valid when the *test* was wrong, never when the *app* is wrong.

#### 3.5. Loop

After fixing the test-defect failures, re-run the full script (step 3.3). Repeat until one of:
- all tests pass,
- every remaining failure is classified as a real code bug or an env limitation, or
- an iteration cap of **5** fix-and-rerun cycles is reached (prevents infinite loops).

On hitting the cap, record the remaining failures with their last diagnosis.

#### 3.6. Result

The corrected `qa-test.sh` (with all test-defect fixes applied) is the version that flows into the Draft Response. Record for step 4:
- execution status: `ran` | `not executed — {reason}`
- `{N} passed / {M} failed`
- for each remaining failure: its classification (`real code bug` | `not executed — {reason}`) and detail.

### 4. Write Draft Response

Combine the (fixed) test script, execution results, and manual checklist into the `## Draft Response`:

```markdown
## Draft Response

### QA Test Plan: {ticket-key} — {title}

**Branch:** {branch}
**Base:** {base}
**Ticket:** {ticket_url}
**PR:** {pr_url or "None"}
**Base URL:** {base_url}

### Test Script

{the complete, fixed bash script — the version produced by the Pass 3 loop, not the original from step 2.5}

### Execution Results

**Status:** {ran | not executed — {reason}}
**Result:** {N} passed / {M} failed

{for each remaining failure:}
- **{test description}** — {real code bug | not executed — {reason}}: {expected vs. actual / detail}

{if status is "not executed", briefly state what's needed to run it (start app at {base_url}, provide auth, etc.).}

### REPL/Console Tests

{if any service-layer-only ACs exist:}

Run in `{console_command or "your project's REPL/console"}`:

{for each service-only AC:}
#### AC {N}: {text}
```
{ServiceClass}.new.{method}({sample_args})
# Expected: {expected_result}
```

### Manual Checklist

{the complete checklist from step 2.6}

### Coverage Summary
- {N}/{M} acceptance criteria have automated tests
- {N} automated tests executed and passing
- {N} potential code bugs surfaced by execution
- {N} automated tests not executed (env: app unreachable / auth required)
- {N} acceptance criteria need manual verification
- {N} acceptance criteria have no matching code change (possibly out of scope)
- {N} code changes not mapped to any acceptance criterion
- {N} existing tests cover related behavior
```

### 5. Finalize

1. Update the queue item's frontmatter `status` to `drafted`
2. Move from `~/.claude/engineer-agent/queue/incoming/` to `~/.claude/engineer-agent/queue/drafts/` (write to new location, delete from old)

### 6. Report

Report: "QA test plan drafted for {ticket-key}: {N} automated tests ({P} passed / {F} failed on run), {B} potential bugs surfaced, {N} manual checks, {N} regression tests. Review with `/engineer-agent review-queue qa`."

If the loop aborted, report execution status instead, e.g.: "... automated tests not executed: app unreachable at {base_url}. ..."
