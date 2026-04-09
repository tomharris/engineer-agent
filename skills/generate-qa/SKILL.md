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

### 3. Write Draft Response

Combine the test script and manual checklist into the `## Draft Response`:

```markdown
## Draft Response

### QA Test Plan: {ticket-key} — {title}

**Branch:** {branch}
**Base:** {base}
**Ticket:** {ticket_url}
**PR:** {pr_url or "None"}
**Base URL:** {base_url}

### Test Script

{the complete bash script from step 2.5}

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
- {N} acceptance criteria need manual verification
- {N} acceptance criteria have no matching code change (possibly out of scope)
- {N} code changes not mapped to any acceptance criterion
- {N} existing tests cover related behavior
```

### 4. Finalize

1. Update the queue item's frontmatter `status` to `drafted`
2. Move from `~/.claude/engineer-agent/queue/incoming/` to `~/.claude/engineer-agent/queue/drafts/` (write to new location, delete from old)

### 5. Report

Report: "QA test plan drafted for {ticket-key}: {N} automated tests, {N} manual checks, {N} regression tests. Review with `/engineer-agent review-queue qa`."
