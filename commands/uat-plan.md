---
description: "Generate a User Acceptance Testing (UAT) checklist from a list of GitHub issues / Jira tickets, grouped by feature area"
model: sonnet
argument-hint: "<ticket-or-issue> [more refs...] [--project <slug>]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion",
  "mcp__atlassian__getJiraIssue",
  "mcp__atlassian__searchJiraIssuesUsingJql",
  "mcp__plugin_github_github__issue_read"]
---

# Engineer Agent: UAT Plan

Turn a set of issues/tickets into a **User Acceptance Testing checklist** — a markdown table of
concrete, user-facing tests (each with an expected result) grouped by feature area. UAT is
*user-facing and code-agnostic*: derive tests purely from ticket intent (what a user should be able
to do, and what they should see), not from code or diffs.

This is a sibling to `/engineer-agent qa`, not a replacement. `qa` is single-ticket + branch-diff
and emits runnable curl/REPL scripts; `uat-plan` is multi-ticket and produces a manual acceptance
checklist. It does **not** touch the review queue — the table is printed and saved directly.

## Arguments

`$ARGUMENTS` is a space-separated list of ticket references. Classify each one independently:

- **Jira key** — matches `^[A-Z][A-Z0-9]+-\d+$` (e.g. `ENG-123`)
- **Jira URL** — `.../browse/ENG-123` → extract `ENG-123`
- **GitHub issue URL** — `https://github.com/{owner}/{repo}/issues/{n}` → `{owner}/{repo}#{n}`
- **`owner/repo#n`** — explicit GitHub issue ref
- **`#n` or bare `n`** — GitHub issue needing a repo resolved from config (see step 2)

Mixing trackers in a single invocation is allowed. `--project <slug>` pins a project (used only to
resolve bare GitHub refs and to name the saved file).

Examples:

```
/engineer-agent uat-plan ENG-123                          # single Jira ticket
/engineer-agent uat-plan ENG-100 ENG-205 PLAT-7           # mixed Jira keys
/engineer-agent uat-plan https://github.com/org/repo/issues/42
/engineer-agent uat-plan org/repo#42 #43 ENG-9            # mixed GitHub + Jira
/engineer-agent uat-plan EPIC-1                           # Jira epic → expands to all descendants
/engineer-agent uat-plan ENG-5 --project my-api           # pin project (bare #N / save naming)
```

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. If missing, tell the user to run
`/engineer-agent setup` and stop.

### 2. Resolve Project (best-effort, only when needed)

Config is needed only to (a) resolve a bare `#n`/`n` GitHub ref to an `owner/repo`, and (b) name the
saved file. Resolve the project in this order:

1. `--project <slug>` if provided (verify it exists under `projects.<slug>`).
2. Otherwise infer from the current working directory by matching against `projects.<slug>.path`.
3. Otherwise, if a bare GitHub ref (`#n`/`n`) is present and the repo is still ambiguous, use
   `AskUserQuestion` to ask which `owner/repo` it belongs to (offer configured `github.repos`).

Fully-qualified refs (Jira keys, Jira URLs, full GitHub URLs, `owner/repo#n`) need **no** project —
do not block on project resolution when every ref is already qualified.

### 3. Expand Jira Parents → Descendants

For each **Jira** ref, fetch it with `mcp__atlassian__getJiraIssue`. If it is an **Epic** or has
subtasks (issue type `Epic`, or a non-empty subtask list), expand it to all descendants:

```
mcp__atlassian__searchJiraIssuesUsingJql  with JQL:  parent = "KEY"
```

Modern Jira returns both subtasks and epic children for `parent = "KEY"`. If a returned child is
itself an epic or has subtasks, recurse one more level so grandchildren are included.

**Drop the parent itself** from the test set — keep its key/summary only as provenance (so its
descendants' rows can cite the parent in their Source). De-duplicate keys across the entire argument
list (a ticket named twice, or pulled in by two parents, is tested once).

GitHub issues are leaf units — no expansion.

### 4. Fetch Ticket Text (ticket text only — no repo/PR access)

For every resolved **leaf** ticket, fetch title, description, acceptance criteria, and status:

- **Jira:** `mcp__atlassian__getJiraIssue` → summary, description, status, and the acceptance
  criteria (a custom "Acceptance Criteria" field if present, else an `Acceptance Criteria` section
  in the description).
- **GitHub:** via Bash:
  ```bash
  gh issue view {n} --repo {owner}/{repo} --json title,body,labels,state
  ```
  Scan the body for an `## Acceptance Criteria` section. (`mcp__plugin_github_github__issue_read` is
  the MCP fallback if `gh` is unavailable.)

If one ref fails to fetch (not found, no access), **warn and skip it**, then continue — one bad ref
must not abort the whole run.

### 5. Derive User Tests & Cluster Into Feature Areas

For each ticket, translate its intent into **specific, user-observable tests**. Each test is a
single concrete user action/scenario phrased from the user's perspective, paired with a concrete
**expected result** (the user-visible outcome — never a code assertion). Cover happy paths,
meaningful edge cases, and error states implied by the acceptance criteria.

Then **cluster all tests across all tickets into emergent feature areas** (themes), regardless of
which ticket each test came from — e.g. several tickets touching sign-in collapse into one "Account
Login" area. Keep every test traceable to its originating ticket(s) via the Source column.

### 6. Emit the Table

Build the markdown below, **print it to the terminal**, and **save the same content** to
`~/.local/share/engineer-agent/uat-plans/{YYYYMMDD-HHmmss}-uat-plan-{first-ref}.md` (create the
`uat-plans/` directory if it does not exist; `{first-ref}` is a filename-safe form of the first
argument, e.g. `ENG-100` or `org-repo-42`).

A single flat checklist table, rows ordered so each feature area's rows are contiguous:

```markdown
# UAT Plan

_Generated {YYYY-MM-DD} from {comma-separated input refs}{; note expansions, e.g. "EPIC-1 (+4 descendants)"}._

| ☐ | Feature Area | Test | Expected Result | Source |
|---|--------------|------|-----------------|--------|
| ☐ | Account Login | Sign in with valid email + password | Redirected to dashboard; session persists on refresh | ENG-100 |
| ☐ | Account Login | Sign in with wrong password | Inline "Invalid credentials" error; no redirect | ENG-100 |
| ☐ | Invitations | Invite a teammate by email | Invitee receives email; appears as "Pending" in member list | ENG-205, EPIC-1 |
| ☐ | Invitations | Re-invite an already-invited user | "Already invited" notice; no duplicate email sent | EPIC-1 |
```

Column meanings:
- **☐** — an empty checkbox so the table doubles as a checklist.
- **Feature Area** — the inferred theme, repeated per row so the artifact is one flat, sortable table.
- **Test** — one concrete user action/scenario.
- **Expected Result** — the user-visible outcome.
- **Source** — comma-separated originating ticket key(s)/refs for traceability.

If any refs were skipped in step 4, append a short `_Skipped: {refs} ({reason})_` line below the
table so the gap is visible.

### 7. Report

After printing the table, print the saved file path as the final line:
`Saved to ~/.local/share/engineer-agent/uat-plans/{filename}`.
