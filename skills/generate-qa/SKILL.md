---
name: generate-qa
description: "Generate a QA test plan from a queue item containing ticket acceptance criteria and branch code changes. Use this skill when processing a qa-test-plan queue item."
version: 1.0.0
model: sonnet
---

# Generate QA Test Plan

Generate a hybrid QA test plan from ticket acceptance criteria and branch code changes using a two-pass analysis, then run it. Three kinds of scripted test, plus a manual checklist:

- **curl** — HTTP checks against the running app (`qa-test.sh`)
- **unit** — test files in the project's own framework (pytest, RSpec, Jest, ...), run by `test_command`
- **REPL** — short self-checking scripts piped to `repl_command`, for behavior that needs the app's runtime (a Rails console with a database, a configured Django shell)

## Tools Needed

- `Read`, `Write` — read/write queue items and project files
- `Grep`, `Glob` — search codebase for route definitions and project structure
- `Bash` — `git diff`, `git worktree`, `curl`, and the project's test and REPL commands

## Input

A queue item file in `~/.local/share/engineer-agent/queue/incoming/` with `type: qa-test-plan`. The `## Context` section contains:
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

Read `~/.local/share/engineer-agent/engineer.yaml`. Extract for the queue item's `project`:
- `projects.<project>.qa.base_url` (required — if missing, use `http://localhost:3000` and flag a warning)
- `projects.<project>.qa.test_command` (optional) — runs unit test files; the test directory is appended as its last argument, e.g. `uv run pytest -q`, `bundle exec rspec`, `npx jest`
- `projects.<project>.qa.repl_command` (optional) — runs a REPL script read from stdin, non-interactively, e.g. `uv run python -`, `bin/rails runner -`, `node -`
- `projects.<project>.qa.console_command` (optional, legacy) — used as `repl_command` when that is absent
- `projects.<project>.path` (project root path)

If `test_command` or `repl_command` (and `console_command`) is absent, infer it from the project: `uv.lock` → `uv run pytest -q` / `uv run python -`; `poetry.lock` → `poetry run pytest -q` / `poetry run python -`; other Python (`pyproject.toml`, `setup.py`) → `python -m pytest -q` / `python -`; `Gemfile` with `rspec` → `bundle exec rspec` / `bin/rails runner -` (Rails) or `bundle exec ruby -`; `package.json` → its test runner (`npx jest`, `npx vitest run`) / `node -`. Note each inferred command in the plan as "inferred".

#### 1.3. Classify Changed Files

For each file in the changed files list, classify by path patterns. Use `Glob` against the project root to discover the project's directory structure and refine classification.

Categories:
- **api** — files matching patterns like `app/controllers/**`, `src/controllers/**`, `routes/**`, `src/api/**`, `src/routes/**`, `app/api/**`, `**/endpoints/**`
- **service** — files matching `app/services/**`, `src/services/**`, `lib/**`, `src/lib/**`, `app/workers/**`, `app/jobs/**`
- **model** — files matching `app/models/**`, `src/models/**`, `db/migrate/**`, `prisma/**`, `**/migrations/**`, `**/schema*`
- **view** — files matching `app/views/**`, `src/components/**`, `templates/**`, `app/assets/**`, `src/pages/**`, `public/**`
- **config** — files matching `config/**`, `.env*`, `docker-compose*`, `Dockerfile*`, `*.config.*`
- **test** — files matching `test/**`, `spec/**`, `__tests__/**`, `*_test.*`, `*_spec.*`, `*.test.*`, `*.spec.*`

If a file doesn't match any pattern, classify as `service` (conservative default — it gets a unit test rather than being silently ignored). Library packages (e.g. `packages/*/src/**`, `src/<pkg>/**`) are `service` or `model`, never left unclassified.

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

- **AC maps to service/model/library code (no API route):** Generate a **unit test** (step 2.6):
  - Written in the project's test framework, following the style of the project's existing tests (read one nearby test file first)
  - One **happy path** test and one **edge/failure** test per AC (invalid input, boundary, rejected value), with exact expected values and exact error classes/messages
  - Call the public API the diff adds or changes; never private helpers
  - Named after the behavior (`test_rejects_unknown_duration_part`)

- **AC needs the app's runtime (database, configured framework, background services) and no route reaches it:** Generate a **REPL test** (step 2.7) instead of a unit test.

- **AC maps to view/UI changes only:** Add to manual checklist:
  - What page/component to navigate to
  - What to look for or verify
  - Any specific interactions to try

**Principle — never punt scripted tests to manual.** An AC that maps to an API route, service method, model or library function gets a *scripted* test: curl, unit or REPL. If generating or running that scripted test is hard (unvalidated route, a failure on first run, a missing fixture, etc.), it is resolved in the Pass 3 run-and-fix loop below — it is **never** relocated into the manual checklist to avoid dealing with it. "Run the unit tests" or "parse X and check Y" are never manual items. The manual checklist is only for ACs that are genuinely UI/judgment-only, or work in another repo or after merge (release tags, downstream pin bumps).

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

#### 2.6. Compose Unit Tests

Write one test file per changed module (or per AC group) for the unit-test ACs from step 2.2. Files live in an `ea_qa/` directory at the repo root, named for the framework's discovery (`test_*.py`, `*_spec.rb`, `*.test.ts`). Keep them self-contained: no edits to the project's own tests, fixtures or `conftest.py`; build what each test needs inline. For each test, put the AC it covers in a one-line comment above it (`# AC2`).

```python
# ea_qa/test_wait_step.py
import pytest
from pkg.definition import ResolvedWaitStep, parse_step


# AC1
def test_parses_a_wait_step_as_resolved_wait():
    step = parse_step({"waitTwoDays": {"wait": {"days": 2}}})
    assert isinstance(step, ResolvedWaitStep)
    assert step.call is None


# AC1
def test_rejects_an_unknown_duration_part():
    with pytest.raises(ValueError, match="weeks"):
        parse_step({"w": {"wait": {"weeks": 1}}})
```

#### 2.7. Compose REPL Tests

For each REPL-test AC, write a script for `repl_command` (stdin, non-interactive) that sets up what it needs, exercises the behavior, and checks the result itself: print `PASS: {description}` or `FAIL: {description} (expected X, got Y)` per check, and exit non-zero if any check failed. A REPL test that only prints a value for a person to read is not a test.

```ruby
# AC3 — run with: bin/rails runner -
user = UserService.new.create_with_invite("a@example.com", :admin)
ok = user.persisted? && user.invites.count == 1
puts ok ? "PASS: creates user and one invite" : "FAIL: creates user and one invite (got #{user.invites.count} invites)"
exit(ok ? 0 : 1)
```

#### 2.8. Compose Manual Checklist

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

Run every scripted test — curl, unit and REPL — and fix failing ones in place. The goal: every scripted test either passes or is left failing for a deliberate, recorded reason — never abandoned, never demoted to the manual checklist.

#### 3.1. Materialize the Tests

Write the composed `qa-test.sh` to a temp file under the session scratchpad directory.

Unit and REPL tests must run against the **branch**, not whatever the project checkout has on disk:
- If the current directory is already a checkout of `branch` (the headless run's worktree), use it.
- Otherwise create a worktree: `git -C {project_path} worktree add {scratchpad}/qa-wt {branch}` (fetch `origin {branch}` first if the branch is not local).

Write the unit test files into `{worktree}/ea_qa/` and each REPL script to `{scratchpad}/repl-{N}.txt`. Keep these files in sync with any fixes you make in the loop — the final, corrected versions go into the Draft Response (step 4).

#### 3.2. Preconditions (per kind)

Each kind runs or is marked not-executed on its own; one kind being blocked never stops the others.

- **curl:** if there are no curl tests, record `not executed — none generated`. Otherwise probe the host once:

  ```bash
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BASE_URL"
  ```

  If the connection is refused or the host is unresolvable, record `not executed — app unreachable at {base_url}` for the curl tests and skip their loop. Do not "fix" tests against a dead endpoint.
- **unit / REPL:** if there are none of that kind, record `not executed — none generated`. If its command cannot run here (the tool call is denied in a confined run, or the command is not installed), record `not executed — {reason}` and leave the tests in the plan.

> The loop cannot start the app or obtain credentials itself. curl tests are best-effort against whatever is already running at `base_url`.

#### 3.3. Run

From the worktree root:

```bash
bash {scratchpad}/qa-test.sh                         # curl
{test_command} ea_qa                                 # unit
{repl_command} < {scratchpad}/repl-{N}.txt           # REPL, one script at a time
```

Give each command a timeout (10 minutes for the unit run, 2 minutes per REPL script). Capture each test's pass/fail from the output: the curl `PASS`/`FAIL` lines, the test runner's per-test results, the REPL `PASS:`/`FAIL:` lines plus its exit status. If every test passes, record `ran — {N} passed / 0 failed` per kind and go to step 3.6.

#### 3.4. Diagnose Each Failure

Classify each failing test into **exactly one** of these, and act accordingly:

- **Test defect → fix the test, then re-run.** The test itself is wrong. Examples:
  - Wrong path (404 because the route path is off) — correct it against the validated route definitions from step 1.5.
  - Placeholder/missing auth producing 401/403 — supply a real token only if one is plainly derivable from the project; otherwise treat as an env limitation (below).
  - Expected status disagrees with the AC — correct the expectation to what the **AC** specifies.
  - Invalid happy-path sample data triggering an unintended validation error — fix the request body or test input.
  - Malformed curl (quoting, headers, Content-Type) — fix the command.
  - Wrong import, name or call signature in a unit or REPL test — fix it against the code in the diff.
  - Collection or setup error (missing fixture, wrong file name for discovery) — fix the test file.

- **Real code bug → do NOT touch the test.** The test is correct and the AC says behavior X but the code does Y. Leave the test failing and record a finding: which AC/file, expected vs. actual, and why this is a code issue rather than a test issue.

- **Env limitation → leave the test in place, mark not-executed.** The test can't run meaningfully because auth is required and no token is configured or derivable, a service (database, queue) it needs is not running, or a dependency is missing. Don't demote it to manual, and don't fix it against a dead path. Record it as `not executed — {reason}`.

**Hard guardrail:** never rewrite an `expected` value or assertion to match the observed `actual` just to make a test go green. Expectations come from the acceptance criteria, not from the code's current behavior. "Make it pass" is only valid when the *test* was wrong, never when the *code* is wrong.

#### 3.5. Loop

After fixing the test-defect failures, re-run the affected kind (step 3.3). Repeat until one of:
- all tests pass,
- every remaining failure is classified as a real code bug or an env limitation, or
- an iteration cap of **5** fix-and-rerun cycles is reached (prevents infinite loops).

On hitting the cap, record the remaining failures with their last diagnosis.

#### 3.6. Result and Cleanup

Remove the worktree if you created one (`git -C {project_path} worktree remove --force {scratchpad}/qa-wt`). The corrected tests (with all test-defect fixes applied) are the versions that flow into the Draft Response. Record for step 4, **per kind** (curl, unit, REPL):
- execution status: `ran` | `not executed — {reason}`
- `{N} passed / {M} failed`
- for each remaining failure: its classification (`real code bug` | `not executed — {reason}`) and detail.

### 4. Write Draft Response

Combine the (fixed) curl script, unit tests, REPL tests, execution results, and manual checklist into the `## Draft Response`:

```markdown
## Draft Response

### QA Test Plan: {ticket-key} — {title}

**Branch:** {branch}
**Base:** {base}
**Ticket:** {ticket_url}
**PR:** {pr_url or "None"}
**Base URL:** {base_url}
**Test command:** `{test_command}` {"(inferred)" if inferred}
**REPL command:** `{repl_command}` {"(inferred)" if inferred}

### Test Script

{the complete, fixed bash script — the version produced by the Pass 3 loop, not the original from step 2.5}

### Unit Tests

Run from the branch root with `{test_command} ea_qa`.

{for each file, the fixed version:}
#### ea_qa/{file}
```{language}
{file contents}
```

### REPL Tests

{for each REPL test, the fixed version:}
#### AC {N}: {text}
Run with `{repl_command}` from the branch root, script on stdin:
```{language}
{script}
```

### Execution Results

| Kind | Status | Result |
|---|---|---|
| curl | {ran \| not executed — {reason}} | {N} passed / {M} failed |
| unit | {ran \| not executed — {reason}} | {N} passed / {M} failed |
| REPL | {ran \| not executed — {reason}} | {N} passed / {M} failed |

{for each remaining failure:}
- **{kind}: {test description}** — {real code bug | not executed — {reason}}: {expected vs. actual / detail}

{for each kind not executed, briefly state what's needed to run it (start app at {base_url}, provide auth, install deps, allow the test command, etc.).}

### Findings & Disposition

{The shared ledger — one row per finding surfaced by the run. The Pass 3 loop already
classifies each failure; map its classification into a disposition so QA reads identically to
`review-pr` and `implement-ticket`: test-defect-fixed → `fixed`, real-code-bug → `real-bug-filed`,
env-limitation → `not-executed`. Include the passing-after-fix tests as `fixed`.}

| Source | Finding | Disposition | Note |
|---|---|---|---|
| qa | {failing AC / test} | fixed / real-bug-filed / not-executed | {expected vs. actual / reason} |

### Manual Checklist

{the complete checklist from step 2.8}

### Coverage Summary
- {N}/{M} acceptance criteria have automated tests ({C} curl, {U} unit, {R} REPL)
- {N} automated tests executed and passing
- {N} potential code bugs surfaced by execution
- {N} automated tests not executed (env: app unreachable / auth required / command unavailable)
- {N} acceptance criteria need manual verification
- {N} acceptance criteria have no matching code change (possibly out of scope)
- {N} code changes not mapped to any acceptance criterion
- {N} existing tests cover related behavior
```

### 5. Finalize

1. Update the queue item's frontmatter `status` to `drafted`
2. Move from `~/.local/share/engineer-agent/queue/incoming/` to `~/.local/share/engineer-agent/queue/drafts/` (write to new location, delete from old)

### 6. Report

Report: "QA test plan drafted for {ticket-key}: {N} automated tests ({C} curl, {U} unit, {R} REPL; {P} passed / {F} failed on run), {B} potential bugs surfaced, {N} manual checks, {N} regression tests. Review with `/engineer-agent review-queue qa`."

For a kind that did not run, report its status instead, e.g.: "... curl tests not executed: app unreachable at {base_url}. ..."
