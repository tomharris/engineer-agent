# Deterministic polling (scripted collectors)


A poll used to be one `claude -p` session that read ~87KB of instructions (`commands/poll.md`, five
`skills/poll-*/SKILL.md`, three `references/*.md`) plus every raw API response, on **every fire,
every 15 minutes**, to do work that is almost entirely string comparison and file writing. The
steady state of a healthy queue is `items_queued: 0`, so most of that spend bought the answer
"nothing new".

`agent.poll.scripted_sources` moves the mechanical half into bash. The run becomes two phases:

```
cron-poll.sh
  ├─ PHASE A  scripts/poll-{github-issues,github-prs,jira,slite,slack}.sh   (no model)
  │           fetch → filter → reconcile → route → classify → write queue file → state + receipt
  │           emits queue/incoming/*.md + state/poll-manifest.tsv
  └─ PHASE B  claude -p, ONLY if the manifest is non-empty
              drafts each manifest item and moves it to drafts/
```

**When Phase A finds nothing and every configured source is scripted, `claude` is never started.**
A full 5-repo poll of a real config takes ~6s and writes a receipt byte-identical to the model's.

### What is scripted and what is not

| Work | Where |
|---|---|
| Config parse, tracker inference, per-source configured/skipped decision | bash (`ea-config.sh`) |
| Fetch (`gh issue list`/`pr list`; Jira + Slite REST via curl), all filters, priority mapping | bash |
| Reconciliation table (skip / unchanged / update-in-place / create) | bash (`lib-queue.sh`) |
| Routing ladder **tiers 0–3a**, for GitHub, Jira, Slite *and* Slack | bash (`lib-routing.sh`) |
| Jira JQL construction, quoting, and the account-timezone conversion | bash (`poll-jira.sh`) |
| Credential resolution (env → file → Keychain), read-only | bash (`lib-secret.sh`) |
| Ticket-kind **tiers 0–2, 3 Form A, and the Form B precondition** | bash (`lib-ticket-kind.sh`) |
| Filename, frontmatter, `## Context`, branch slug | bash (`lib-queue-write.sh`) |
| State + receipt | bash (`lib-state.sh`, `cron-poll.sh`) |
| Slack **relevance** — is this a question aimed at me? | **System One** (`lib-typesafe.sh`), composed in bash |
| Kind **Form B** (imperative-vs-noun), when opted in | **System One** (`lib-ticket-kind-judge.sh`), thresholded in bash |
| Routing **tier 3b** (which project), when opted in | **System One** (`lib-routing-judge.sh`), a Choice over the candidate set, thresholded in bash |
| Routing **tier 3b** and kind **Form B** when not opted in | **model** |
| **All draft prose** | **model** |

The remaining judgment tiers are **flagged in the manifest**, never guessed. `needs_routing=1` writes
the item as `project: _unrouted` with `matched_projects`, which the model finishes through the
already-documented `incoming/` + `_unrouted` → update-in-place branch of
`references/queue-reconciliation.md` — no new state, no new code path. `needs_kind_check=1` is the
same socket for Form B, and it is the **fallback the judgment degrades to**, not a path it replaces:
every install that does not set `agent.typesafe.ticket_kind.enabled` — and every run where the
judgment cannot be made — takes it, exactly as before. `needs_routing` works the same way for
routing Tier 3b (`agent.typesafe.routing.enabled`), with one asymmetry worth knowing: a routing
judgment that *was made* and abstained clears the flag, because an abstention is a correct answer
and re-asking Phase B would pay twice to re-litigate it.

### The scripts

| File | Role |
|---|---|
| `lib-yaml.sh` | one generic indent-stack YAML reader (`yaml_get`/`yaml_get_list`/`yaml_keys`/`yaml_seq_len`), including block sequences of mappings (`jira.sources`) and block scalars (`routing.description`) |
| `ea-config.sh` | normalizes `engineer.yaml` to flat greppable lines, applying defaults, tracker inference and the `investigation.*` replace-not-merge rule **once** |
| `lib-queue.sh` | frontmatter access + `queue_disposition` (the reconciliation table) + `poll_resume_candidates` |
| `lib-queue-write.sh` | queue-item construction, with real YAML escaping |
| `lib-routing.sh` / `lib-ticket-kind.sh` | the deterministic ladder tiers |
| `lib-ticket-kind-judge.sh` | kind Tier 3 Form B as one typed judgment; inert unless opted in, and degrades to the model on any failure |
| `lib-routing-judge.sh` | routing Tier 3b as one typed Choice over the config-derived candidate set; same opt-in and same degradation |
| `lib-state.sh` | round-trips `state/last-poll.yaml`, preserving model-written sections |
| `lib-time.sh` | GNU/BSD-portable timestamp helpers |
| `poll-github-issues.sh` / `poll-github-prs.sh` / `poll-jira.sh` / `poll-slite.sh` / `poll-slack.sh` | the collectors |
| `lib-typesafe.sh` | a minimal System One client: fixed yes/no questions in, floats out. NOT a general LLM client |
| `lib-secret.sh` / `setup-credentials.sh` | resolve (read-only) and store the Jira / Slite / TypeSafe API credentials |
| `queue-status.sh` / `queue-list.sh` | the data behind `status` / `review-queue` |

> **`ea-config.sh dump` emits a CURATED view and deliberately omits `agent.notify.ntfy.*`.** On
> public ntfy.sh the `command_topic` is effectively a password for remote approval, and a poller
> has no use for it. Keeping it out means the normalized config can be logged or cached while
> debugging without leaking the credential.

### Invariants that survive the move

- **Polling still only reads.** The collectors call `gh issue list` / `gh pr list`, and — for Jira
  and Slite — `GET`/`POST /search` REST endpoints that return data only. No posting verb is
  reachable from Phase A at all; the read-only guarantee is structural in bash rather than enforced
  by an `--allowedTools` allowlist. The Jira credential is an API token whose scope is the account's
  own permissions, so this is the one place where "read-only" is a property of the *verbs used*
  rather than of the *capability held* — keep it that way: no collector may ever call
  `POST /issue/{key}/comment` or a transition. `scripts/jira-claim.sh` does assign and transition,
  and is deliberately **not** a collector: it runs only after selection, for one ticket, under the
  `jira-claim` tier or after a human Approve, and is never in a model run's allowlist.
- **Injection containment is stronger, not weaker.** The routing candidate set is computed from
  config alone and every tier can only narrow it, so a scripted route can only ever emit a slug the
  config already permits. The kind ladder's entire output alphabet is two fixed strings.
- **Terminal state stays absorbing.** `queue_disposition` looks up the whole `{ticket,
  ticket-investigation}` family *including* `completed/` and `rejected/`, so the self-sustaining
  re-queue loop (engineer-agent's own comment bumps `updatedAt`) cannot restart.

### Jira and Slite: what REST changes

These two have no CLI to shell out to, which is why they were previously listed as permanently
model-driven. Four consequences that a reader will otherwise try to "simplify" away:

- **Jira REST API v2, not v3.** v3 returns `description` as an Atlassian Document Format *tree*;
  reconstructing prose from that in bash would be a parser of its own, and its failure mode is a
  queue item with an empty or mangled `### Description` that a human then approves work from. v2
  returns text. Both are supported on Jira Cloud.
- **`jq` is a hard dependency of these two collectors and a soft one for the poll.** The GitHub
  collectors use `gh --jq` (gh's embedded engine) to honour the "the cron path is jq-free" policy;
  there is no equivalent for curl. So a missing `jq` exits 3 and the model polls that source, which
  is what the policy actually protects.
- **The JQL timezone conversion is load-bearing.** A bare datetime in JQL is read in the *account's*
  Jira profile timezone, not UTC, so feeding it a UTC watermark's clock digits shifts the window by
  the account offset — six hours into the **future** for a Denver account, after which every ticket
  updated during working hours falls before the cutoff. The poll then queues nothing and reports
  `status: ok`, which is indistinguishable from a quiet day. The offset is read off a real returned
  timestamp (DST-correct, no tz database); a **failed** bootstrap exits 3 rather than assuming UTC,
  because silently assuming +00:00 on a non-UTC account reintroduces the bug with no signal at all.
- **Slite's tag exposure is not guaranteed.** The note object is read for several plausible tag
  shapes; when none is present the doc is matched on the search query that found it and the item
  records `label_source: query`, so the approval gate can see the match was weaker than a real tag
  comparison. An *unrecognisable* response shape exits 3 rather than yielding zero docs — "no docs
  need review" must never be something a parse failure can say.

**A bug fixed in passing:** `skills/poll-slite/SKILL.md` iterates per project and queues a matching
doc for each. In a real config all six projects set `doc_labels: ["needs-review"]`, so every review
doc matches every project and the global `source_id` dedup silently awards it to whichever project
the loop reached first — the shared-repo trap in a different costume. `poll-slite.sh` collects docs
once and routes them through the ladder, so the ambiguous case becomes a visible `_unrouted` item
instead of an invisible arbitrary assignment.

### Credentials

`agent.jira.*` / `agent.slite.*` / `agent.typesafe.*` name **where** the token is, never what it is: `engineer.yaml` is a
file people paste into issues when asking for help, and `ea-config.sh dump` is documented as safe to
log. `lib-secret.sh` resolves env var → file → macOS Keychain and never writes; `setup-credentials.sh`
is the single (interactive) writer, and its `check` subcommand reports what resolves without printing
a secret.

> **Prefer the Keychain on macOS.** cron/launchd/systemd hand the run a minimal environment, so a
> token exported from a shell profile is present in every terminal you test from and ABSENT in the
> supervised poll — the collector then skips cleanly every 15 minutes forever, and the only symptom
> is that Jira is never actually scripted. This is the same class of bug as the missing `$USER` that
> once broke every cron poll. The poll already runs as a `gui/$UID` LaunchAgent specifically so it
> can read the login keychain (`slack-mcp.sh` relies on the same property), so this needs no
> scheduler change. `setup-credentials.sh check` warns when a token resolves only from the
> environment.

Credentials are passed to curl via `--config -` (**stdin**), never `-u`/`-H` in argv: an argv
credential is readable by any other process on the box via `ps`, and this runs unattended every 15
minutes. Both test suites assert the secret never appears in argv.

### Two hazards the design has to handle

**1. Nothing may be stranded in `incoming/`.** Only `drafts/` is reachable by the approval gate, and
the reconciliation table says a resolved `incoming/` item is "leave alone" — so an item written by
Phase A whose drafting phase died would sit there **forever, invisibly**. Two guards:
`poll_resume_candidates()` re-emits any `incoming/` item lacking a `## Draft Response` into every
subsequent manifest (self-healing on the next tick), and `queue-status.sh` reports the count as a
warning. `tests/lib-queue.test.sh` and `tests/poll-github-issues.test.sh` both pin it.

> **There are TWO stranding shapes, and for eight weeks only one was detected.**
> `poll_resume_candidates()` tests for a **missing** draft, because it was written for the
> Phase-A/Phase-B crash above. But the invariant it cites is about *location*, not about whether a
> draft exists — an item in `incoming/` **with a finished draft** is invisible to both approval
> paths too, and it is strictly worse: the work is already done and already reviewable, and nobody
> can reach it. That shape had no detector, so `/engineer-agent status` printed `stranded: 0` while
> five verified `code-audit-finding` items — including a cross-client authorization hole — sat
> unapprovable in `incoming/` from 2026-07-14. They came from a pre-`e218f1c` `audit-code` that had
> not yet learned to write straight to `drafts/`; that producer bug was fixed the next day, but
> nothing healed what it had already left behind, because the reconciliation table correctly says a
> resolved `incoming/` item is "leave alone".
> `poll_stranded_drafted()` is the second predicate and `scripts/queue-heal-stranded.sh --heal`
> (run by `cron-poll.sh`, before the dedup check) is the remedy. It is a **separate** predicate on
> purpose: the two remedies differ — an undrafted item needs the *model*, a drafted one just needs
> *moving* — and merging them into one looser condition would re-draft finished work on every tick.
> Three deliberate refusals: `_unrouted` items are left parked (`review-queue` surfaces those from
> `incoming/`, so they are reachable, and healing one would skip the routing decision it waits
> for); a name collision with `drafts/` is left to `queue-dedup-check.sh`, whose job it is; and the
> heal **sends no ntfy push**, because an auto-resolution needing no judgement must not reach the
> topic your Approve/Reject buttons arrive on. Ordering matters — the heal runs *first*, since
> dedup's rules key on whether a copy is in `drafts/`, which is exactly what the heal changes.
> **The general lesson: a guard's condition must be the invariant, not the one failure that
> prompted it.** This one was written as the complement of the hazard it quoted, and so was blind
> to precisely the case the hazard describes.

**2. `gh --jq`, not `jq`.** The collectors use gh's *embedded* jq engine, so they add no dependency
and stay inside the "the cron path is jq-free" policy `cron-poll.sh` sets. The Slack collector needs
real `jq` (there is no embedded engine behind `curl`) and so gates on it softly — exit 3, fall back
to the model — never hard-fail. Same rule Jira and Slite follow.

### Scripted Slack polling: a judgment tier that is not the model

Slack was listed here as permanently model-driven for the same stated reason Jira and Slite once
were, but a *different* underlying one. Jira/Slite lacked a CLI; Slack lacks a **mechanical
predicate**. Every other source's "is this work?" test is a field comparison — a status, an
assignee, a tag. `skills/poll-slack/SKILL.md` §3b is literally "use judgment to determine if it's
actually a question directed at the user", because a keyword filter alone is mostly false positives
("deploy" appears in every deploy announcement). That one sentence is why Slack kept every poll
paying for a model session even on a quiet day.

`scripts/poll-slack.sh` keeps the judgment and drops the session. Each surviving candidate gets
**one batched request** to a System One model (`scripts/lib-typesafe.sh`) carrying four independent
yes/no questions — `is_question`, `directed_at_user`, `already_answered`, `needs_engineer` — which
come back as probabilities. The composition is **in bash**:

```
relevant = is_question >= min_question && directed_at_user >= min_directed
        && already_answered <= max_answered && needs_engineer >= min_engineer
```

Keeping the policy in bash rather than asking one broad "should I answer this?" is the point, and
it is the same reason `lib-routing.sh` and `lib-ticket-kind.sh` exist: the thresholds are visible in
config, tunable per install, and testable without the network (`tests/poll-slack.test.sh` pins each
dimension in both directions against a stubbed API). The four raw probabilities are written to the
item's `relevance_scores`, so the gate audits the evidence, not just the verdict.

**Why this does not weaken the read-only / injection invariants.** `lib-typesafe.sh` is not a
general LLM client and must not become one — it sends fixed, repo-authored questions and reads back
floats. There is no completion, no tool use, no instruction following. Message text is the `state`
of a yes/no question and nothing else, so the **output alphabet is four numbers**: an injected
payload can at worst move a probability and get a message queued that should not have been, and
that item still passes the human approval gate. It cannot name a project (routing is a separate
ladder computed from config alone), cannot reach a posting verb, and cannot emit a string any later
stage executes. Phase A still only reads.

> **DOUBLE OPT-IN, and the second gate is not ceremony.** `slack` in `agent.poll.scripted_sources`
> is not sufficient: an `agent.typesafe` credential must also resolve, or the collector exits 3 and
> Slack stays model-driven. That is because **this is the only thing in the poll path that sends
> your content to a third party.** `gh`, Jira and Slite all talk to systems that already hold the
> data being sent; `api.typesafe.ai` does not. Anyone enabling it should be making that decision
> deliberately rather than inheriting it from a config array, so it costs a second explicit step
> (`setup-credentials.sh typesafe`, which says so at the prompt).
>
> **This generalizes: the credential is necessary for every TypeSafe-backed feature and sufficient
> for none.** Each one that egresses content carries its own opt-in and sends a different slice, so
> enabling one never silently enables the next — a key stored for Slack relevance does not start
> sending GitHub issue titles (`agent.typesafe.ticket_kind.enabled`, see "Ticket Kind"), and neither
> of those starts sending ticket *bodies* (`agent.typesafe.routing.enabled`, see "Ticket Routing").
> Keep that shape for the fourth: a per-feature gate, deny-by-default, named at the credential
> prompt, and stating which slice of content it sends.

**Four decisions in `poll-slack.sh` a reader will otherwise "fix" back:**
- **One read per CHANNEL, not per project** — the shared-repo trap in its third costume. Two
  projects watching `#eng-general` would otherwise hand the global `source_id` dedup an arbitrary
  winner. Channels are Tier 0 of the routing ladder; each project's `slack.keywords` is Tier 2, and
  their union is the discovery filter. Ambiguity becomes a visible `_unrouted` item.
- **The relevance request comes LAST**, after the keyword filter, own-message drop, recency cutoff
  and reconciliation. Every one of those is free; the judgment is not. Thread context is fetched at
  the same point, both because it is a second Slack call and because it is the evidence
  `already_answered` needs.
- **A failed judgment is not a silent "no", and does not advance the cutoff.** The run counts it as
  an error and exits 3, which hands Slack back to the model — but a cutoff already moved past the
  messages that *did* get judged would hide them from that fallback too, so a transient outage would
  quietly eat everything around it. Re-judging a handful next tick is the cheaper mistake;
  reconciliation stops anything already written from duplicating.
- **`last_checked_ts` still does not advance on a zero-message poll** (it is a Slack message
  timestamp, not a clock — `SKILL.md` §3e), nor on an exit-75 token skip. It *does* advance past
  messages the gate **rejected**: those have been judged, and re-examining them would pay for the
  same answer forever.

**Honest limits.** `ignore_bots` is best-effort: neither Slack backend exposes a subtype or
`bot_id`, so only a `B`-prefixed author id is dropped — skipping on an *empty* id would turn a
formatting change into silent data loss, and `needs_engineer` / `is_question` are the real backstop
for app noise. The permalink is *built*, not read (no backend returns one), so a `workspace` set to
a team_id rather than a domain yields a link that degrades rather than breaks. And a typed float is
a guarantee about the interface, not about truth — validate the thresholds on your own channels.

### Gotchas learned while building this — each cost a real debugging cycle

- **Flow *and* block sequences.** A real `engineer.yaml` mixes them (`exec.allowed_commands:` is a
  block list; `github.repos: ["a", "b"]` is flow). `lib-paths.sh`'s `yaml_project_list()` handles
  block only and gets away with it because its one caller reads `exec.allowed_commands`. A reader
  that missed flow would poll **zero repos, silently**.
- **Multi-line flow sequences.** `config/engineer.example.yaml` ships `title_keywords` wrapped
  across two lines. A single-line-only parser returns an empty list and silently disables the whole
  title tier of `references/ticket-kind.md` for anyone who copied the example.
- **`while read` drops an unterminated final line.** `read` returns non-zero at EOF without a
  newline, so the loop body never runs for that line. This silently produced `github_labels: []` —
  a valid-looking value that degrades Tier 2 routing and Tier 2 kind classification. Producers emit
  a trailing newline; consumers use `|| [ -n "$var" ]`.
- **`date -d` is GNU-only** and macOS runs LaunchAgents. A BSD fallback that merely strips a UTC
  offset is *six hours wrong* rather than failing, so `lib-time.sh` normalizes offsets in shell and
  both platforms take one path.
- **`exit` still runs awk's `END` block**, so an `END` that also prints emits the count twice.
- **`set -o pipefail` + `grep -q`** reports a *successful* match as a failed pipeline, because
  `grep -q` closes the pipe and the upstream dies of SIGPIPE. Capture output first, then grep.
- **`close` is a reserved word in awk** and cannot be a parameter name.
- **No apostrophes inside the awk program.** `lib-yaml.sh` holds its whole awk script in a
  single-quoted string, so an apostrophe in a *comment* terminates it and the file stops parsing.
  That is why the existing code writes `\047` for a literal quote. A comment reading "the
  sequence's parent" is a syntax error.
- **No `$` inside an alternation that is itself anchored.** macOS awk (20200816) never matches
  `(a|b$|c)$`; `_ar_children` used one and reported every nested `after_pr` map as an unknown key.
  Anchor once, outside the group.
- **Bash 3.2 has no `declare -A`, and `sed -i` needs `''` on BSD.** Under `#!/bin/bash` on macOS,
  `F[q]=x` indexes element 0 for every key; `sed -i 1d f` fails. Test stubs hit both.
- **Prepending fallback dirs to PATH shadows a caller's stubs.** The dispatcher scripts append
  `~/.local/bin`, `/opt/homebrew/bin` etc.; the installers set the real order.
- **A bare statement before `else` is not portable awk.** `if (c) x = 1` on its own line followed by
  `else` is rejected by BSD awk (which is what macOS LaunchAgents run). Brace every arm.
- **`"maxResults":1` is a substring of `"maxResults":100`.** A test stub dispatching on the former
  served the timezone fixture to every search page, so the collector saw zero issues and every
  assertion after it failed. Anchor on the trailing comma.
- **Jira `jira.sources` is a block sequence of MAPPINGS**, which `lib-yaml.sh` refused outright
  before this work (`[]#map-unsupported`). It is now modelled as indexed sub-paths
  (`…sources[0].project`) rather than flattened, because the elements are a set whose filters must
  stay attached to their own project key — flattened, a catch-all source silently inherits the
  previous one's component filter.
- **`routing.description` is written as a folded block scalar (`>-`) in a real config**, and the
  reader returned the literal `>-` as the value. Tier 3b of the routing ladder has no other input,
  so the tier looked configured while deciding on two characters of punctuation.

### A spec ambiguity this surfaced

`references/ticket-kind.md` gives Form A as a regex ending
`… [ \] ) ]? \s* ( : | — | – | - | \| | · | end-of-title )`, but also lists `[Decision] queue
backend` among the titles that **fire** — and under the literal regex it does not, since what
follows the bracket is `queue`. `lib-ticket-kind.sh` implements the doc's **worked examples** (a
closing bracket is itself a delimiter) and says so at the implementation site;
`tests/ticket-kind.test.sh` pins every fires/does-not-fire example verbatim. A model reading the doc
resolved this by intuition each run; a script has to pick, which is how the ambiguity became visible.

