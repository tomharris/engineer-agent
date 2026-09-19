#!/bin/bash
# lib-ticket-kind-judge.sh — Tier 3 Form B of references/ticket-kind.md, answered as a typed
# judgment instead of being deferred to a prose instruction in the poll prompt.
#
# THE QUESTION THE CODE ADMITS IT CANNOT ANSWER. lib-ticket-kind.sh settles every other tier for
# free, and stops at exactly one thing: whether the leading word of a title is an imperative VERB
# commanding investigation, or a NOUN naming what the title is about. `Investigate why checkout
# 500s` is the first; `Research service returns 500` is a bug in a service called Research. That is
# grammar, not string comparison — the library's own comments say so, and its fallback is a
# hardcoded `_TK_NOUN_ONLY` list plus a gerund stemmer that still cannot tell the two apart.
#
# WHAT THIS CHANGES, AND WHAT IT DOES NOT. Before this, a Form B candidate was written out as
# `ticket` with `needs_kind_check=1` and re-examined in Phase B by the drafting model, guided by one
# sentence inside cron-poll.sh's ~900-word note. That still happens whenever this judgment is not
# configured or cannot be made. What this adds is that the kind is FINAL when the item is written:
# `type:` in the frontmatter and the `{YYYYMMDD-HHmmss}-{type}-{id}.md` filename are correct the
# first time, rather than being a placeholder a later phase is trusted to correct.
#
# SCOPE — deliberately Form B ONLY. Form A (a delimited kind prefix: `Spike:`, `[Decision]`,
# `RFC — `) stays in bash. It is deterministic, costs nothing, and tests/ticket-kind.test.sh pins
# every one of the spec's worked examples verbatim in both directions. Replacing a correct free
# comparison with a network call would trade a tested guarantee for a probability, send EVERY issue
# title to a third party rather than the rare candidate, and turn an offline test suite into a
# stubbed one. The judgment goes where the code is actually stuck, and nowhere else.
#
# CONTAINMENT IS UNCHANGED, AND STRUCTURAL. The precondition in _tk_form_b_candidate still gates
# what may be asked about: only a title whose leading word already matches a CONFIGURED keyword can
# reach this file. So ticket text remains the left side of a comparison and never contributes a
# keyword — the trigger vocabulary stays closed under config, exactly as the ladder's header
# claims. This judgment can only ever NARROW that candidate set: its output alphabet is one float,
# and the two outcomes it selects between are `ticket` and `ticket-investigation`, both of which
# the ladder could already emit and both of which pass the human approval gate. An injected payload
# can at worst flip one ticket toward the investigation path, which is the STRICTLY NARROWER
# execution path (read-only, no branch, no PR).
#
# ⚠ EGRESS, STATED PLAINLY — same rule as the Slack collector, smaller surface. The issue TITLE,
# its leading word and its labels go to api.typesafe.ai. The BODY never does: the tier is defined
# over the title alone, so sending more would widen egress for no signal. This is why it is its own
# opt-in (`agent.typesafe.ticket_kind.enabled`) and not implied by having a TypeSafe key for Slack
# — inheriting third-party egress from a config array set for another feature is precisely the
# failure the Slack double opt-in exists to prevent.
#
# DEGRADATION IS THE DEFAULT, NOT AN ERROR PATH. No key, no curl, no jq, disabled, a 429, a 500, a
# malformed answer — every one of them leaves needs_form_b=1 and hands the question to Phase B,
# which is today's behavior. Nothing fails, nothing is skipped, and an install that never sets the
# key never notices this file exists. Note this is also what keeps poll-github-issues.sh's "NO
# EXTERNAL jq" policy intact: jq missing degrades, it does not break.
#
# Requires (sourced by the caller, in this order): lib-secret.sh, lib-typesafe.sh.

# tk_judge_enabled — rc 0 when the Form B judgment is configured AND could actually be made.
#
# BOTH gates, in this order: the explicit per-feature opt-in first (so a disabled install never
# even resolves a credential), then ts_available, which covers the key, curl and jq.
tk_judge_enabled() {
  [ "$(_ts_cfg agent.typesafe.ticket_kind.enabled)" = "true" ] || return 1
  ts_available
}

# tk_judge_min — the probability at or above which the leading word is treated as an imperative.
#
# A threshold rather than a bare "more likely than not" because the spec's tie-break is explicit:
# "when you cannot tell, it does not fire". 0.60 keeps a genuinely ambiguous title on the default
# path (code work), which is the status quo and the cheaper mistake — a wrongly-defaulted spike
# becomes a PR nobody wanted, while a wrongly-flipped bug becomes a findings comment on a ticket
# that needed a fix.
tk_judge_min() { ts_threshold ticket_kind.min_imperative 0.60; }

# The question. Static, written here, never derived from ticket text — the same property that makes
# poll-slack.sh's four questions safe. `leading_word` is supplied by the deterministic precondition,
# so the model is not asked to FIND a marker (which would reopen the vocabulary); it is asked only
# to classify the grammatical role of a word the config already nominated.
#
# The `false` criteria are the spec's "mandatory disqualifier" verbatim in substance — the tells it
# names (a following noun the word modifies, a later third-person verb or copula, a possessive) are
# handed over as criteria rather than left to be inferred, and the last clause encodes "when you
# cannot tell, it does not fire" so ambiguity resolves the same way in the judgment as it does in
# the ladder.
_tk_judge_questions() {
  cat <<'QJSON'
{
  "leading_imperative": {
    "type": "noul",
    "instructions": "In `title`, the word given in `leading_word` is used as an imperative verb commanding that someone investigate, research, evaluate, compare or decide something — so what the ticket asks for is findings, a comparison, or a written decision rather than a code change. It is NOT an imperative when that same word is a noun or modifier naming the subject the ticket is about.",
    "criteria": {
      "true": "The title reads as an instruction to go and find something out: `leading_word` is the verb, and what follows is the thing to investigate.",
      "false": "`leading_word` names a system, service, component or concept that the title is ABOUT — the tells are a noun immediately after it that it modifies, a later third-person verb or copula (returns, is, fails, times out, breaks), or a possessive on the leading word. A bug report, a crash, or a request to change behaviour is never an imperative of this kind. When you cannot tell, false."
    }
  }
}
QJSON
}

# tk_form_b_judge <title> <leading-word> [labels-file] — print the probability, rc 0.
#
# rc 1 means NO JUDGMENT WAS MADE (unavailable, transport failure, missing or non-numeric answer),
# which the caller must treat as "leave needs_form_b=1", never as a "no". That distinction is the
# same one ts_noul draws by printing nothing rather than 0: a degradation has to abstain, because
# the fallback it abstains TO (Phase B) is a correct answer, while a silent "no" would quietly
# convert every outage into "everything is code work".
#
# Labels are included as state, and the body is not. A `bug` label is real evidence against the
# imperative reading of `Research service returns 500`, and labels are a small closed vocabulary
# the repo already publishes; the body is prose that would multiply egress without sharpening a
# question defined over the title.
tk_form_b_judge() {
  local title="$1" word="$2" labels_file="${3:-}" d rc p
  [ -n "$title" ] && [ -n "$word" ] || return 1

  d="$(mktemp -d)" || return 1
  : > "$d/labels"
  [ -n "$labels_file" ] && [ -f "$labels_file" ] && cat "$labels_file" > "$d/labels"

  _tk_judge_questions > "$d/questions.json"
  jq -n --arg t "$title" --arg w "$word" --rawfile l "$d/labels" \
     '{tracker: "github", title: $t, leading_word: $w,
       labels: ($l | split("\n") | map(select(length > 0)))}' > "$d/state.json" 2>/dev/null
  if [ ! -s "$d/state.json" ]; then
    # An empty state file would be POSTed as `state: null` and judged on nothing at all, which is
    # strictly worse than not asking. Abstain. (Same guard as poll-slack.sh, same reason.)
    rm -rf "$d"; return 1
  fi

  ts_ask "$d/state.json" "$d/questions.json" "$d/answers.json"; rc=$?
  if [ "$rc" -ne 0 ]; then rm -rf "$d"; return 1; fi

  p="$(ts_noul "$d/answers.json" leading_imperative)"
  rm -rf "$d"
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}
