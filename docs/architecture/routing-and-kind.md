# Ticket routing and ticket kind

### Ticket Routing

**`references/routing-ladder.md` is the single source of truth for which project a ticket belongs
to.** `poll-jira`, `poll-github-issues`, and `add-ticket` all `Read` it and follow it rather than
describing routing themselves — the same single-source-of-truth invariant `execute-item` has for
approvals, and for the same reason: three prose copies of a rule drift.

The ladder fires tier by tier; each tier requires **exactly one** match, and ambiguity always falls
through to the next:

| Tier | Basis | `routing_method` |
|---|---|---|
| 0 | Only one project watches this Jira key / repo | `single-candidate` |
| 1 | `[token]` title prefix equals a slug or `github.repos` entry | `prefix` |
| 2 | Jira `components`/`labels`; GitHub `github.issues.labels` | `filters` |
| 3a | `routing.keywords` / `routing.paths` hit | `keyword` |
| 3b | Semantic match against `routing.description` | `inferred` (+ `routing_rationale`) |
| 4 | Nothing resolved to exactly one | `_unrouted`, `matched_projects` set |

Tier 0 short-circuits: a project that is the sole watcher of its key/repo pays nothing for any of
this. Tiers 3a/3b consult the optional `projects.<slug>.routing` block (`description`, `keywords`,
`paths`) and are **skipped entirely when no candidate has one**, so installs that never add hints
behave exactly as they did before the ladder existed. An `inferred` route auto-routes and gets a
draft, but the draft still passes the normal approval gate — `review-queue` displays the method and
rationale so a wrong guess is visible rather than silent. Tier 3b may also **abstain**; a tie falls
to Tier 4, never to a coin flip. `add-ticket` is interactive, so it prompts at Tier 4 instead of
writing `_unrouted` (`routing_method: manual`).

**Two traps encoded in the GitHub path, each of which broke a real behavior:**
- `gh issue list --label a --label b` is **AND, not OR**, so several watchers' label filters cannot
  be unioned into one query the way `poll-jira` unions statuses into `status IN (...)`. Fetch the
  repo unfiltered and apply `github.issues.labels` as a *routing* predicate at Tier 2.
- Collection must be deduplicated **per repo**, not per project. When it ran per project, the global
  `source_id` dedup handed a shared repo's issue to whichever project the loop reached first — an
  arbitrary misroute that looked like a confident decision, with no `_unrouted` escape.

> **Tier 3b is the one tier bash cannot decide, and it is now answerable two ways.** Whether a
> ticket about void paycycles belongs to `payroll-workflows` or `billing-api` is semantics, not
> string comparison. `lib-routing.sh` therefore stops at the *candidate set* and emits
> `needs_inference=1`. Who answers it:
> - **`scripts/lib-routing-judge.sh`**, when `agent.typesafe.routing.enabled: true` and a
>   credential resolves. One **Choice whose options ARE the candidate slugs** plus a no-match
>   sentinel, thresholded against `routing.min_confidence` (default `0.70`, which with
>   probabilities summing to 1 also guarantees a ≥ 0.40 margin over the runner-up). The project is
>   then **final when the item is written**, which is why the judgment runs *before* the
>   `--project` filter and before kind classification — the filter compares the final slug, and the
>   kind lists are per-project, so classifying first would use the wrong ones or skip the kind
>   entirely. `routing_rationale` carries the evidence (`routing.description match (p=0.82;
>   runner-up billing-api 0.11)`), **assembled in bash from a validated slug and two numbers** — no
>   model-authored prose ever reaches a queue file a human reads at the gate.
> - **The drafting model in Phase B** otherwise, via `needs_routing=1`. This is the default, the
>   pre-existing behavior, and the fallback for *every* failure.
>
> **An abstention and a failure are different outcomes**, and conflating them is the bug waiting to
> be written here. A judgment that was made and said "cannot tell" (the sentinel won, or the winner
> was below threshold) **clears** the flag: the question has been answered, the item stays
> `_unrouted`, and the human decides. A judgment that could not be made **leaves it up**, so an
> outage degrades to today's behavior instead of to a silent "unroutable".
>
> **Containment gets stronger, not weaker.** The spec's first mandatory injection rule ("only ever
> output a slug from the Tier 0 candidate set") stops being an instruction the model is trusted to
> follow and becomes the **response type**: `criteria` is built from config alone, so there is no
> room in the answer for a slug the config does not permit. Bash re-validates membership anyway and
> refuses anything else as *malformed* (flag stays up) rather than as an abstention — the type
> closes the door on an injected payload, the check closes it on a service bug.

**Injection containment (Tier 3b reads untrusted ticket text):** the inference tier may only ever
output a slug from the Tier 0 candidate set, which is computed from config alone. So an injected
payload can at worst shuffle a ticket between projects that already legitimately watch that key or
repo — it cannot invent a target or reach an unrelated project. Ticket text is matched as *data*
(topic only); imperatives inside it ("assign this to X") are ignored. Routing decides only which
project's config drafts the item; every posting verb stays in `execute-item`, behind the gate.

### Ticket Kind

**`references/ticket-kind.md` is the single source of truth for what a ticket delivers** — a code
change (branch → draft PR → QA) or a findings document (a `## Findings` comment on the ticket + a
local archive). `poll-jira`, `poll-github-issues`, `add-ticket`, and `review-queue`'s unrouted
assignment flow all `Read` it, for the same reason they do the routing ladder.

Two independent ladders, and **routing runs first**: the kind lists are per-project overridable, so
there is no correct kind to compute until a slug exists. Routing answers *which project*; this
answers *what it delivers*. Neither reads the other's output.

| Tier | Basis | `ticket_kind_method` |
|---|---|---|
| 0 | `--investigate` / `--implement` on `add-ticket` | `manual` |
| 1 | Jira issue type name ∈ `jira_types` — **terminal for Jira** | `jira-issuetype` |
| 2 | GitHub label ∈ `github_labels` (after a `type:`/`kind/` prefix strip) | `github-label` |
| 3 | GitHub title keyword, delimited prefix or leading imperative | `title-keyword` (+ `ticket_kind_rationale`) |
| 4 | Nothing matched ⇒ code work, the status quo | `default` |

**Tier 1 being terminal for Jira is what removes the false-positive problem.** A Jira issue always
has a type, so Tier 1 always answers and title matching is unreachable for Jira — a Story titled
`Add spike protection to the rate limiter` is code work by structure, not by luck. For GitHub, Tier
3 requires a *form* (`Spike:`, `[Decision]`, or a leading imperative verb like `Investigate`), never
bare presence of a keyword, because it is impossible to write about rate limiting or decision
engines without tripping a presence test.

Unlike the routing ladder, the last tier is **not** a human: "nothing matched" has a correct,
non-surprising answer (code work — the behavior before this ladder existed), and both outcomes are
gated anyway. The human override is `add-ticket --investigate` / `--implement`.

> **Tier 3 Form B is the one thing bash cannot decide, and it is now answerable two ways.** Whether
> `Investigate why checkout 500s` is an imperative while `Research service returns 500` is a bug in
> a service called Research is grammar, not string comparison. `lib-ticket-kind.sh` therefore stops
> at the *precondition* — the leading word (after one optional `please `) is a configured keyword or
> its gerund, and is not one of the Form-A-only nouns — and emits `needs_form_b=1` plus that word.
> Who answers it:
> - **`scripts/lib-ticket-kind-judge.sh`**, when `agent.typesafe.ticket_kind.enabled: true` and a
>   credential resolves. One noul thresholded against `ticket_kind.min_imperative` (default `0.60`,
>   encoding the spec's "when you cannot tell, it does not fire"). The kind is then **final when the
>   item is written** — `type:` and the `{ts}-{type}-{id}.md` filename are right the first time,
>   which is why the judgment runs *before* reconciliation, and `ticket_kind_rationale` carries the
>   score (`leading imperative 'Investigate' (Form B, imperative=0.93)`) so the gate audits the
>   evidence and not just the verdict — the same reason `routing_rationale` exists for Tier 3b.
> - **The drafting model in Phase B** otherwise, via `needs_kind_check=1` in the manifest. This is
>   the default, the pre-existing behavior, and the fallback for *every* failure: no key, disabled,
>   no jq, a 429/5xx, a malformed answer. A failed judgment **abstains**; it never becomes a silent
>   "no", because that would convert any outage into "everything is code work".
>
> **Form A stays in bash, deliberately** — it is deterministic, free, and `tests/ticket-kind.test.sh`
> pins every worked example in the spec verbatim in both directions. Replacing a correct free
> comparison with a network call would trade a tested guarantee for a probability, send *every*
> issue title to a third party instead of the rare candidate, and turn an offline suite into a
> stubbed one. The judgment goes where the code is stuck and nowhere else.
>
> **Containment is unchanged and still structural.** The precondition gates what may be asked
> about, so ticket text remains the left side of a comparison and never contributes a keyword; the
> judgment can only ever *narrow* a config-derived candidate set, its output alphabet is one float,
> and both outcomes it selects between are gated. A flip toward investigation also moves the item
> to the **narrower** execution path (read-only, no branch, no PR).

> **`Task` ships as a trigger and is the one aggressive default.** In many Jira projects `Task` is
> the catch-all for ordinary code work, so on such an instance a routine ticket is drafted as an
> investigation. Bounded by the gate (the human reads an "Investigation Plan" that says "no branch,
> no PR") and by one line of config (`jira_types: ["Spike", "Decision"]`, globally or per project).

**Injection containment:** the ladder's entire output alphabet is two config-derived shapes, both
behind the approval gate. Ticket text is only ever the *left* side of a comparison — it never
contributes a keyword — so the trigger vocabulary is closed under config. Classification happens
during polling, which has a read-only allowlist, so it cannot reach a posting verb; the comment
target is `ticket_key` from the tracker API, never a key parsed out of ticket text; and the
investigation execution path is *narrower* than the implementation path, so a flip toward
investigation reduces capability.

**`{ticket, ticket-investigation}` is one `(type, source_id)` family.** A kind can change between
polls (an issue type edited, a title retitled), and since the dedup invariant is keyed on `type`, the
naive rule mints a rival item for work already queued or finished. So the poller lookup is
family-wide **including terminal items**, while `queue-dedup-check.sh` collapses the family only
among **non-terminal** ones — a completed investigation followed by a fresh implementation draft is
the legitimate spike → `add-ticket --implement` handoff, and flagging it would leave the check
permanently red on the most likely real workflow. Both asymmetries are deliberate; see
`references/queue-reconciliation.md`.

