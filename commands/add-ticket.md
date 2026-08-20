---
description: "Manually add a Jira ticket or GitHub issue to the implementation queue"
model: haiku
argument-hint: "<jira-key|jira-url|github-url|owner/repo#N> [--project <slug>] [--no-draft] [--investigate|--implement]"
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion", "mcp__atlassian__getJiraIssue"]
---

# Engineer Agent: Add Ticket

Manually add a single Jira ticket or GitHub issue to the implementation queue, bypassing the poll filters. Use this when you want to work on a ticket that doesn't match your configured poll criteria (different assignee, outside your components/labels, picked up from a teammate, etc.).

## Arguments

`$ARGUMENTS` should contain a ticket reference and optional flags:

- **Jira key** — e.g. `ENG-789`
- **Jira URL** — e.g. `https://example.atlassian.net/browse/ENG-789`
- **GitHub issue URL** — e.g. `https://github.com/owner/repo/issues/45`
- **GitHub `owner/repo#N`** — e.g. `myorg/my-app#45`
- **Bare issue number** — e.g. `#45` or `45` (requires `--project <slug>`; resolves against that project's first repo)

Flags:
- `--project <slug>` — explicitly route to a project; bypasses interactive prompting.
- `--no-draft` — queue the item in `incoming/` only, don't generate a draft.
- `--investigate` — force the findings-document deliverable (`type: ticket-investigation`,
  `ticket_kind_method: manual`). Tier 0 of `references/ticket-kind.md`; nothing below it runs.
- `--implement` — force code work (`type: ticket`). This is the escape hatch for a wrong
  title-keyword hit; without it the only remedy for a title the ladder misreads is editing the
  ticket in the tracker. Both directions exist for the same reason `routing_method: manual` does —
  a human said so.

`--investigate` and `--implement` are **mutually exclusive**: supplying both is an error, not a
preference. Do not guess and do not silently prefer one.

## Steps

### 1. Load Config

Read `~/.local/share/engineer-agent/engineer.yaml`. If missing, tell the user to run `/engineer-agent setup` and stop.

### 2. Parse Arguments

Extract the ticket reference and any flags from `$ARGUMENTS`. **Strip and record every flag
(`--project`, `--no-draft`, `--investigate`, `--implement`) BEFORE detecting the reference** —
otherwise a leading `--implement` is fed to the ref detectors below, falls through every pattern,
and the command dies on "usage" for a perfectly good ticket. Error out if both `--investigate` and
`--implement` are present. If no reference is supplied, ask the user for one and stop.

Detect the source type from the reference:

- Matches `^[A-Z][A-Z0-9]+-\d+$` → **Jira key**. Use as-is.
- Contains `/browse/` → **Jira URL**. Extract the trailing key (the last path segment).
- Contains `github.com/` and `/issues/` → **GitHub issue URL**. Extract `owner`, `repo`, and `number` from the path.
- Matches `^[\w.-]+/[\w.-]+#\d+$` → **GitHub `owner/repo#N`**. Split on `#` then `/`.
- Matches `^#?\d+$` → **bare issue number**. Require `--project <slug>` — if missing, error with usage hint and stop. With `--project`, resolve to `projects.<slug>.github.owner` + `projects.<slug>.github.repos[0]`.
- Anything else → error with usage hint and stop.

For Jira refs, `ticket_key = <KEY>` and `source_id = <KEY>`. For GitHub refs, `ticket_key = #<number>` and `source_id = <owner>/<repo>#<number>`.

### 3. Active-Queue Dedup Check

Glob `~/.local/share/engineer-agent/queue/incoming/*.md` and `~/.local/share/engineer-agent/queue/drafts/*.md`. For each match, read the YAML frontmatter and check `source_id`. Match on `source_id` **regardless of which ticket type the existing item carries** — `ticket` and `ticket-investigation` are one namespace, so `add-ticket ENG-789 --investigate` must not mint a rival live item next to an existing `ticket` for the same key. That is precisely what this check exists to prevent, just through the `type` half of the key. If any file has the same `source_id`, abort with:

```
{ticket_key} is already in the queue: {path/to/file}
Run `/engineer-agent review-queue` to act on it, or remove the file first.
```

Do **not** consult `completed/`, `rejected/`, or the `seen_tickets`/`seen_issues` state — manual add is the user's explicit override for re-queueing.

This is the deliberate exception to `references/queue-reconciliation.md`, which the **pollers** follow: for them terminal state is absorbing, precisely so a completed ticket cannot be re-queued by later activity (including engineer-agent's own comments). This command is how a human re-opens one on purpose. It still must not create a *second live* item, which is what the incoming/ + drafts/ check above enforces.

### 4. Resolve Project

**If `--project <slug>` was supplied:** validate that the slug exists in the `projects` map. If not, error and list available slugs. Otherwise use it.

**Otherwise:** fetch the ticket first (Step 5) so title/body/components/labels are known, then read the routing ladder and apply it. Resolve its path from `${CLAUDE_PLUGIN_ROOT}/references/routing-ladder.md`, falling back to `{plugin-root}/references/routing-ladder.md` if that env var is unset — not a bare relative path, which won't resolve unless the cwd happens to be the plugin root. Inputs per tracker:

- **Jira:** `ticket.title` = summary, `ticket.body` = description, `ticket.labels`, `ticket.components`, `ticket.jira_key` = the ticket's Jira project key. Tier 0 candidates = every `(slug, source)` where `source.project == ticket.jira_key`.
- **GitHub:** `ticket.title` = issue title, `ticket.body` = issue body, `ticket.labels` = the issue's label names, `ticket.components` = empty, `ticket.owner` / `ticket.repo` from the parsed ref. Tier 0 candidates = every slug where `github.owner == owner` AND `github.repos` contains `repo`.

Then:

- **Ladder routed it:** use that slug. Record the `routing_method` (and `routing_rationale` when `inferred`) in the queue item, same as a polled item.
- **Ladder returned `_unrouted` (Tier 4):** this command is interactive, so ask instead of parking the item. Call `AskUserQuestion` with one question listing all configured project slugs whose tracker resolves to the ticket's tracker (`jira` or `github-issues`) as options. If the ladder's `matched_projects` is non-empty, prefix those slugs with `(matched) ` in the option label so the user can see which candidates it considered. Use the user's selection and set `routing_method: manual`.

Because the ladder now resolves prefixes, filters, keywords, and inference before giving up, the prompt only appears when it genuinely cannot tell — which should be rare.

The resolved `project` is always a real slug from config — this command never writes `_unrouted`.

### 5. Fetch Ticket Details

**Jira:** call `mcp__atlassian__getJiraIssue` with the ticket key. Extract:
- `summary` (used as `title`)
- `description`
- `status`
- `issuetype` — the type **NAME** (e.g. `Spike`), not its id → `jira_issue_type`. Tier 1 of the
  ticket-kind ladder matches names, and ids are per-instance; without this field the highest-trust
  kind tier is silently unreachable.
- `priority`
- `components` (list of names) → `jira_components`
- `labels` (list) → `jira_labels`
- recent comments (last 3–5)
- the ticket URL → `source_url`

Map Jira priority to queue priority: Highest/High → `urgent`, Medium → `normal`, Low/Lowest → `low`.

**GitHub:** run via Bash:

```
gh issue view {number} --repo {owner}/{repo} --json number,title,body,labels,url,assignees,milestone,createdAt,updatedAt
```

Extract `number`, `title`, `body`, `labels`, `url`. GitHub Issues have no built-in priority — default to `normal`. If a label matches `priority:high` or equals `urgent`, use `urgent`. If a label matches `priority:low`, use `low`.

If the fetch fails, report the error and stop.

### 5b. Classify the Deliverable

If `--investigate` or `--implement` was supplied, that is Tier 0 of the ladder — the answer is
already decided (`ticket_kind_method: manual`) and nothing below runs.

Otherwise read `${CLAUDE_PLUGIN_ROOT}/references/ticket-kind.md` (same path resolution as the
routing ladder in Step 4) and apply it with the `issuetype` / labels / title fetched in Step 5 and
the slug resolved in Step 4.

This is its own step, deliberately **after** both the fetch and the routing: Tier 1 needs the Jira
issue type, and the kind lists are per-project overridable so they need a slug. It cannot be folded
into Step 4.

Output: `type` (`ticket` | `ticket-investigation`), `ticket_kind_method`, and
`ticket_kind_rationale` when the method is `title-keyword`.

### 6. Write Queue Item

Compute the current timestamp `YYYYMMDD-HHmmss` (local time, same as polling skills). Write a new file in `~/.local/share/engineer-agent/queue/incoming/` with frontmatter and `## Context` matching the polling skill output exactly, so downstream skills see no difference between a manually-added and a polled item.

#### Jira ticket

**Filename:** `{YYYYMMDD-HHmmss}-{type}-{ticket_key}.md` (so an investigation is
`…-ticket-investigation-ENG-789.md`)

**Content:** Use the "Queue Item Format" block from `skills/poll-jira/SKILL.md`:

```yaml
---
type: "{ticket|ticket-investigation}"
source: jira
source_url: "{ticket_url}"
source_id: "{ticket_key}"
title: "{ticket_summary}"
priority: "{mapped_priority}"
created_at: "{current_iso_timestamp}"
status: incoming
project: "{resolved_slug}"
ticket_key: "{ticket_key}"
jira_status: "{ticket_status}"
jira_issue_type: "{issue type name}"
jira_components: ["{component1}", "..."]
jira_labels: ["{label1}", "..."]
routing_method: "{single-candidate|prefix|filters|keyword|inferred|manual}"
routing_rationale: "{one line}"   # only when routing_method is "inferred"
ticket_kind_method: "{manual|jira-issuetype|github-label|title-keyword|default}"
ticket_kind_rationale: "{one line}"   # only when ticket_kind_method is "title-keyword"
---

## Context

**Ticket:** {ticket_key} — {ticket_summary}
**Status:** {ticket_status}
**Type:** {jira issue type name}
**Priority:** {ticket_priority}
**Components:** {comma-separated or "none"}
**Labels:** {comma-separated or "none"}
**Project:** {resolved_slug}
**Routing:** {routing_method}{" — " + routing_rationale if inferred}
**Deliverable:** {code change + draft PR | findings document posted as a comment on the ticket} ({ticket_kind_method}{" — " + ticket_kind_rationale if title-keyword})

### Description
{ticket_description}

### Acceptance Criteria
{extract from description if present, otherwise "No explicit acceptance criteria"}

### Recent Comments
{last 3-5 comments if any}
```

Do NOT include `matched_projects` — that field is only for `_unrouted` items.

#### GitHub issue

**Filename:** `{YYYYMMDD-HHmmss}-{type}-gh-{number}.md`

**Content:** Use the "Queue Item Format" block from `skills/poll-github-issues/SKILL.md`:

```yaml
---
type: "{ticket|ticket-investigation}"
source: github
source_url: "{issue_url}"
source_id: "{owner}/{repo}#{number}"
title: "{issue_title}"
priority: "{mapped_priority}"
created_at: "{current_iso_timestamp}"
status: incoming
project: "{resolved_slug}"
ticket_key: "#{number}"
github_labels: ["{label1}", "..."]
routing_method: "{single-candidate|prefix|filters|keyword|inferred|manual}"
routing_rationale: "{one line}"   # only when routing_method is "inferred"
ticket_kind_method: "{manual|github-label|title-keyword|default}"
ticket_kind_rationale: "{one line}"   # only when ticket_kind_method is "title-keyword"
---

## Context

**Ticket:** #{number} — {issue_title}
**Status:** Open
**Priority:** {mapped_priority}
**Project:** {resolved_slug}
**Labels:** {comma-separated label names or "none"}
**Routing:** {routing_method}{" — " + routing_rationale if inferred}
**Deliverable:** {code change + draft PR | findings document posted as a comment on the issue} ({ticket_kind_method}{" — " + ticket_kind_rationale if title-keyword})
**URL:** {issue_url}

### Description
{issue_body}

### Acceptance Criteria
{extract from body if present, otherwise "No explicit acceptance criteria"}

### Labels
{comma-separated label names}
```

### 7. Generate Draft

If `--no-draft` was passed, skip this step entirely (the file stays in `incoming/` with `status: incoming`).

Otherwise, follow the draft-generation step from the matching poll skill, and pick the template
matching the item's `type` — the **Implementation Plan** block for `ticket`, the **Investigation
Plan** block for `ticket-investigation`. Never emit the implementation template for an
investigation: its "opens a draft PR" line is what the human reads at the gate.
- Jira: `skills/poll-jira/SKILL.md` Step 6
- GitHub: `skills/poll-github-issues/SKILL.md` Step 6 (for `ticket` only, derive a branch slug from the title: lowercase, replace non-alphanumeric with `-`, truncate to 40 chars, strip trailing hyphens — skip it for an investigation, which has no branch)

Append a `## Draft Response` section with the implementation plan, then move the file from `incoming/` to `drafts/` and update `status: drafted` in the frontmatter.

### 8. Update Dedup State

Read `~/.local/share/engineer-agent/state/last-poll.yaml`. Append to the relevant list under the resolved project so the next poll cycle won't re-queue:

- **Jira:** append `ticket_key` to `projects.<slug>.jira.seen_tickets` (create the list if missing).
- **GitHub:** append `source_id` (i.e. `owner/repo#N`) to `projects.<slug>.github_issues.seen_issues` (create the list if missing).

Do **not** modify any `last_checked` timestamps — those should keep tracking real poll boundaries.

Write the file back.

### 9. Report

Print a one-line confirmation. **Name the deliverable** — the line reads identically for both shapes otherwise, so a wrong classification would be invisible at exactly the moment a human could cheaply fix it:

```
Queued {ticket_key} for project {slug} as {code work|investigation} ({drafted|incoming}). Run `/engineer-agent review-queue` to review.
```
