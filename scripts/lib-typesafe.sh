#!/bin/bash
# lib-typesafe.sh — a minimal client for TypeSafe's System One API (POST /v1/systemone), used to
# turn one narrow, untrusted-text judgment into a NUMBER that bash can threshold.
#
# WHY THIS EXISTS AT ALL. Every other source in this plugin became scriptable because its "is this
# work?" test is mechanical: a Jira status, a GitHub assignee, a Slite tag. Slack's is not —
# skills/poll-slack/SKILL.md §3b is literally "use judgment to determine if it's actually a question
# directed at the user", and that single sentence is the only reason Slack had no scripted collector
# and kept every poll paying for a model session. A System One model answers exactly that shape of
# question (a probability, not prose) for no reasoning tokens, which is what lets poll-slack.sh join
# Phase A.
#
# THIS IS NOT A GENERAL LLM CLIENT AND MUST NOT BECOME ONE. It sends a fixed set of yes/no
# questions and reads back floats. There is no completion, no tool use, no instruction following —
# so the containment argument that lets the poll ingest untrusted text survives intact:
#
#   • The OUTPUT ALPHABET IS A FLOAT PER QUESTION. Untrusted message text is the `state`; the
#     questions are written here, in this repo. The worst an injected payload can do is move a
#     probability, i.e. get a message queued that should not have been (or vice versa) — and every
#     queued item still passes the human approval gate. It cannot name a project (routing is a
#     separate, config-derived ladder), cannot reach a posting verb, and cannot emit a string that
#     any later stage executes.
#   • READ-ONLY BY CONSTRUCTION. One POST to one endpoint that returns a judgment. Phase A's
#     "polling only reads" invariant is unaffected.
#
# ⚠ EGRESS, STATED PLAINLY — this is the one thing in the poll path that sends your content to a
# third party. Slack message text and thread context leave the machine and go to api.typesafe.ai.
# Nothing else in Phase A does that (gh, Jira and Slite talk to systems that already hold the data).
# That is precisely why the Slack collector is DOUBLE opt-in: `slack` must be listed in
# agent.poll.scripted_sources AND an agent.typesafe credential must resolve. Absent either, the
# collector exits 3 and Slack stays model-driven exactly as before.
#
# CREDENTIAL: same rules as Jira/Slite, same library. The config names WHERE the key is, never what
# it is — see the SECURITY note at the top of lib-secret.sh, and prefer the Keychain on macOS
# because launchd hands the poll a minimal environment.
#
# DEPENDENCIES: curl and jq, both HARD here and SOFT for the poll. A missing one is not an error,
# it is "leave this source to the model" — the same graceful degradation poll-jira.sh and
# poll-slite.sh already give. jq is required because a request body containing arbitrary Slack text
# must be built by a real JSON encoder; hand-rolled quoting is how you ship a collector that dies on
# the first message containing a quote character.
#
# Requires: lib-secret.sh (sourced by the caller), and EA_CFG holding `ea-config.sh dump`.

TS_ENDPOINT_DEFAULT="https://api.typesafe.ai/v1/systemone"
TS_MODEL_DEFAULT="jev-latest"

# _ts_cfg <path> — read one scalar out of the normalized config view.
_ts_cfg() { printf '%s\n' "${EA_CFG:-}" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }

ts_endpoint() { local v; v="$(_ts_cfg agent.typesafe.api_base)"; printf '%s' "${v:-$TS_ENDPOINT_DEFAULT}"; }
ts_model()    { local v; v="$(_ts_cfg agent.typesafe.model)";    printf '%s' "${v:-$TS_MODEL_DEFAULT}"; }

# ts_key — resolve the API key (env -> file -> Keychain). Prints nothing when unconfigured, which
# every caller treats as "not available", never as an error.
ts_key() {
  ea_secret_resolve "$(_ts_cfg agent.typesafe.api_key_env)" \
                    "$(_ts_cfg agent.typesafe.api_key_file)" \
                    "$(ea_secret_service typesafe)" ""
}

# ts_available — rc 0 when a request could actually be made. Callers exit 3 on failure so the
# source falls back to the model rather than failing the poll.
ts_available() {
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq   >/dev/null 2>&1 || return 1
  [ -n "$(ts_key)" ] || return 1
}

# ts_threshold <name> <default> — a tunable from agent.typesafe.<name>, validated as a number.
#
# Validated rather than trusted because a threshold is read from config and then compared with awk:
# a non-numeric value would make every comparison silently false, which presents as "the collector
# found nothing" — indistinguishable from a quiet day, the exact failure shape the Jira timezone
# bug had. A malformed value falls back to the shipped default and says so.
ts_threshold() {
  local name="$1" def="$2" v
  v="$(_ts_cfg "agent.typesafe.${name}")"
  [ -n "$v" ] || { printf '%s' "$def"; return 0; }
  case "$v" in
    ''|*[!0-9.]*|*.*.*) printf 'lib-typesafe: agent.typesafe.%s is not a number (%s); using %s\n' "$name" "$v" "$def" >&2
                        printf '%s' "$def"; return 0 ;;
  esac
  printf '%s' "$v"
}

# ts_ask <state-json-file> <questions-json-file> <out-file>
#
# POSTs {state, model, questions} and writes the response body to <out-file>. rc 0 only when the
# response is a 200 carrying an `answers` object — a 4xx/5xx body is left in place for the log but
# never treated as answers.
#
# The key goes in a curl `--config -` (stdin) header line, NEVER in argv: this runs unattended every
# 15 minutes, and an argv credential is readable by any other process on the box via `ps`. Same rule
# as poll-jira.sh and poll-slite.sh, and tests/poll-slack.test.sh asserts it.
#
# BOUNDED, because this is an unattended network read. CLAUDE.md's rule from the listener stall:
# never add one without a timeout. --connect-timeout and --max-time cap a single attempt; at most
# TS_RETRIES additional attempts are made, and ONLY for 429 / 5xx (a retry on 400 would just
# re-send a body that is wrong). Total worst case is bounded and small relative to the poll budget.
TS_RETRIES="${EA_TYPESAFE_RETRIES:-2}"
TS_MAX_TIME="${EA_TYPESAFE_MAX_TIME:-45}"

ts_ask() {
  local f_state="$1" f_questions="$2" out="$3"
  local key url model body code attempt=0 delay=2

  key="$(ts_key)"
  [ -n "$key" ] || return 1
  url="$(ts_endpoint)"; model="$(ts_model)"

  body="$(mktemp)" || return 1
  # jq builds the body, so arbitrary Slack text (quotes, backslashes, newlines, emoji) is encoded
  # by something that actually knows JSON.
  if ! jq -n --slurpfile s "$f_state" --slurpfile q "$f_questions" --arg m "$model" \
        '{state: $s[0], model: $m, questions: $q[0]}' > "$body" 2>/dev/null; then
    rm -f "$body"; return 1
  fi

  # curl's config format is `name = "value"` with backslash escapes; escape both so a key
  # containing either cannot terminate the line early or smuggle another directive.
  local esc_key; esc_key="$(printf '%s' "$key" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"

  while :; do
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$esc_key" \
      | curl -sS --config - \
             -H 'Content-Type: application/json' \
             --data-binary @"$body" \
             -o "$out" -w '%{http_code}' \
             --connect-timeout 10 --max-time "$TS_MAX_TIME" \
             -X POST "$url" 2>/dev/null)"
    code="${code:-000}"
    case "$code" in
      200)
        rm -f "$body"
        jq -e 'has("answers") and (.answers | type == "object")' "$out" >/dev/null 2>&1 || return 1
        return 0 ;;
      429|5*|000)
        if [ "$attempt" -lt "$TS_RETRIES" ]; then
          attempt=$((attempt+1)); sleep "$delay"; delay=$((delay*2)); continue
        fi
        rm -f "$body"; return 1 ;;
      *)
        rm -f "$body"; return 1 ;;
    esac
  done
}

# ts_noul <response-file> <question-key> — the probability for one noul, or nothing.
#
# Prints NOTHING rather than 0 when the key is absent or non-numeric. That distinction is
# load-bearing: the caller must be able to tell "the model said no" (0) from "there is no answer"
# (empty), because the second is a degradation that has to abstain, not a confident rejection.
ts_noul() {
  jq -r --arg k "$2" '(.answers[$k].noul // empty) | select(type == "number") | tostring' \
     "$1" 2>/dev/null | head -1
}

# ts_choice <response-file> <question-key> — the chosen option name, or nothing.
#
# The value comes off the wire, so it is NOT trusted to be one of the options that were sent: the
# caller must re-check membership against its own option list before using it (lib-routing-judge.sh
# does, and refuses anything else). Restricted here to the slug charset — a choice carrying
# whitespace, control characters or shell metacharacters is not a slug this repo could have sent,
# and this value reaches log lines and, once validated, queue frontmatter.
ts_choice() {
  jq -r --arg k "$2" '(.answers[$k].choice // empty) | select(type == "string")' "$1" 2>/dev/null \
    | head -1 | grep -E '^[A-Za-z0-9._-]+$' | head -1
}

# ts_choice_prob <response-file> <question-key> <option> — that option's probability, or nothing.
#
# Nothing rather than 0 when absent, for the same reason ts_noul prints nothing: the caller has to
# be able to tell "the model gave this option almost no weight" from "there is no distribution
# here", because only the second is a degradation that must abstain.
ts_choice_prob() {
  jq -r --arg k "$2" --arg o "$3" \
     '(.answers[$k].probabilities[$o] // empty) | select(type == "number") | tostring' \
     "$1" 2>/dev/null | head -1
}

# ts_confidence <response-file> <question-key> — the Choice confidence, or nothing.
#
# Distribution CONCENTRATION, not the winner's probability: it also falls when two also-rans are
# tied with each other, which says nothing about whether the winner is right. Callers threshold the
# winner's probability and use this only as a fallback for a response that omits `probabilities`.
ts_confidence() {
  jq -r --arg k "$2" '(.answers[$k].confidence // empty) | select(type == "number") | tostring' \
     "$1" 2>/dev/null | head -1
}

# ts_ge <a> <b> / ts_le <a> <b> — float comparison. bash has no float arithmetic and `[` would
# compare these as strings ("0.9" > "0.55" is TRUE as a string but so is "0.1" > "0.05"), so every
# threshold test goes through awk.
ts_ge() { [ -n "${1:-}" ] && awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
ts_le() { [ -n "${1:-}" ] && awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }
