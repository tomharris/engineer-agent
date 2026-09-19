#!/bin/bash
# poll-slack.sh — deterministic collector for Slack questions that need an answer.
#
# Replaces the mechanical half of skills/poll-slack/SKILL.md: channel reads, the keyword and
# recency filters, reconciliation, routing, queue-file writing and state. It does NOT draft — it
# writes slack-question items to queue/incoming/ and emits a manifest naming what still needs a
# model.
#
# WHY THIS WAS THE LAST SOURCE TO BE SCRIPTED. Every other collector's "is this work?" test is
# mechanical — a Jira status, a GitHub assignee, a Slite tag. Slack's is not: SKILL.md §3b is
# literally "use judgment to determine if it's actually a question directed at the user", and a
# keyword match alone is mostly false positives ("deploy" appears in every deploy announcement).
# That one sentence is why Slack kept every poll paying for a model session even on a quiet day.
# scripts/lib-typesafe.sh answers exactly that shape of question as four probabilities, which bash
# can threshold — see "The relevance gate" below.
#
# ⚠ DOUBLE OPT-IN, AND THE SECOND GATE IS NOT A FORMALITY. This collector runs only when BOTH
#   1. `slack` appears in agent.poll.scripted_sources (or EA_POLL_SCRIPTED_SOURCES), and
#   2. an agent.typesafe.* credential resolves (plus curl and jq).
# Absent either, it exits 3 and cron-poll.sh leaves Slack to the model, exactly as before. The
# second gate exists because this is the ONLY thing in the poll path that sends your content to a
# third party: Slack message and thread text goes to api.typesafe.ai. gh, Jira and Slite all talk
# to systems that already hold the data being sent. Anyone enabling this should know that, so it is
# a separate, explicit decision rather than a side effect of listing "slack" in a config array.
#
# ONE COLLECTION PASS, NOT ONE PER PROJECT — the same correction poll-slite.sh makes, for the same
# reason. SKILL.md iterates over projects and queues a matching message for each, so two projects
# watching #eng-general hand the global source_id dedup an arbitrary winner. Channels are read ONCE,
# messages deduplicated by (channel, ts), and routed through references/routing-ladder.md, so the
# ambiguous case becomes a visible `_unrouted` item instead of an invisible coin flip.
#
# THE RELEVANCE GATE, and what it is allowed to decide. Four independent yes/no judgments are asked
# in ONE request per surviving candidate (the docs' batching guidance: N questions in one request
# cost far less than N requests), and composed IN CODE:
#
#     relevant = is_question    >= min_question
#             && directed       >= min_directed
#             && already_answered <= max_answered
#             && needs_engineer >= min_engineer
#
# Keeping the composition in bash rather than asking one broad "should I answer this?" is the whole
# point: the thresholds are visible, tunable per install, and testable without the network. The
# four raw probabilities are recorded in the item's frontmatter (`relevance_scores`) so the
# approval gate can audit the decision and not only its outcome — the same reason
# `routing_rationale` exists for the tier that infers a project.
#
# INJECTION CONTAINMENT. Message text is the `state` of a yes/no question and nothing else. The
# output alphabet is four floats, so an injected payload can at worst get a message queued that
# should not have been — and every queued item still passes the human approval gate. It cannot name
# a project (routing is a separate ladder computed from config alone), cannot reach a posting verb
# (this script has none; `<slack> send` is execute-item's job), and cannot emit a string any later
# stage executes.
#
# Usage: poll-slack.sh [--project <slug>] [--run-ts <iso>] [--dry-run] [--manifest <file>]
# Exit:  0 ok (including "nothing to do" and a clean token-expiry skip)
#        2 usage
#        3 unavailable — leave Slack to the model
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib-paths.sh"
. "${SCRIPT_DIR}/lib-yaml.sh"
. "${SCRIPT_DIR}/lib-time.sh"
. "${SCRIPT_DIR}/lib-queue.sh"
. "${SCRIPT_DIR}/lib-queue-write.sh"
. "${SCRIPT_DIR}/lib-routing.sh"
. "${SCRIPT_DIR}/lib-state.sh"
. "${SCRIPT_DIR}/lib-secret.sh"
. "${SCRIPT_DIR}/lib-typesafe.sh"

ONLY_PROJECT=""; RUN_TS=""; DRY_RUN=0; MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)  ONLY_PROJECT="$2"; shift 2 ;;
    --run-ts)   RUN_TS="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help)  sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "poll-slack.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_TS" ] || RUN_TS="$(iso_now)"
TS_PREFIX="$(queue_ts)"
READ_COUNT="${EA_SLACK_READ_COUNT:-50}"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
WRITTEN="$TMPD/written"; : > "$WRITTEN"
log()  { printf '%s\n' "$*" >&2; }
emit() { [ -n "$MANIFEST" ] && printf '%s\n' "$*" >> "$MANIFEST"; return 0; }

command -v curl >/dev/null 2>&1 || { log "poll-slack: curl not found; leaving Slack to the model"; exit 3; }
command -v jq   >/dev/null 2>&1 || { log "poll-slack: jq not found; leaving Slack to the model"; exit 3; }

EA_CFG="$("${SCRIPT_DIR}/ea-config.sh" dump)"; export EA_CFG
cfg()  { printf '%s\n' "$EA_CFG" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }
cfgl() { printf '%s\n' "$EA_CFG" | awk -v p="$1[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}'; }

# --- Gate 2: the relevance model ---------------------------------------------------------------
# Checked BEFORE any Slack call. Discovering halfway through that no judgment can be made would
# leave some channels read and some not, and would advance no cutoff — a half-done poll is worse
# than one that cleanly declined.
if ! ts_available; then
  log "poll-slack: no TypeSafe credential available (checked env/file/keychain); leaving Slack to the model"
  exit 3
fi

MIN_QUESTION="$(ts_threshold slack.min_question 0.60)"
MIN_DIRECTED="$(ts_threshold slack.min_directed 0.55)"
MAX_ANSWERED="$(ts_threshold slack.max_answered 0.40)"
MIN_ENGINEER="$(ts_threshold slack.min_engineer 0.50)"

# --- The Slack binary, resolved in plain bash --------------------------------------------------
# Same resolution cron-poll.sh does, and for the same reason: which backend runs must never depend
# on anything the run reads. Both backends expose read/thread with identical flags.
SLACK_METHOD="$(cfg agent.slack.method)"; SLACK_METHOD="${SLACK_METHOD:-spy}"
if [ "$SLACK_METHOD" = "mcp-proxy" ]; then
  SLACK_BIN="${SCRIPT_DIR}/slack-mcp.sh"
else
  SLACK_BIN="$(cfg agent.slack.bin)"; SLACK_BIN="${SLACK_BIN:-spy}"
fi
command -v "$SLACK_BIN" >/dev/null 2>&1 || [ -x "$SLACK_BIN" ] || {
  log "poll-slack: Slack binary '${SLACK_BIN}' not found or not executable; leaving Slack to the model"; exit 3; }

USER_NAME="$(cfg agent.slack.user_name)"
USER_ID="$(cfg agent.slack.user_id)"

# slack_call <out> <verb> <args...> — run the Slack CLI, capture stdout, return its exit code.
#
# Exit 75 is the mcp-proxy shim's documented clean skip on an expired Keychain token. It is NOT an
# error: Claude Code re-auths on its own and the next poll succeeds, so the caller leaves
# last_checked_ts untouched and reports a skip, exactly as SKILL.md §1 specifies.
slack_call() {
  local out="$1"; shift
  local ws_args=()
  [ -n "${WORKSPACE:-}" ] && ws_args=(-w "$WORKSPACE")
  "$SLACK_BIN" "$@" --json "${ws_args[@]}" > "$out" 2>"$TMPD/slackerr"
}

# slack_messages <file> — the message objects out of a read/thread response.
#
# Both backends emit a bare JSON array of {ts,user_id,user_name,reply_count,thread_ts,text}
# (scripts/slack-mcp.sh parse_messages_text builds exactly spy's shape on purpose). `.messages`
# and `.results` envelopes are accepted too so a future wrapper does not silently yield zero
# messages — which, as in poll-slite.sh, must never be something a parse failure can say.
slack_messages() {
  jq -c 'if type == "array" then .[]
         elif has("messages") then (.messages | if type == "array" then .[] else empty end)
         elif has("results")  then (.results  | if type == "array" then .[] else empty end)
         else empty end' "$1" 2>/dev/null
}
slack_shape_ok() {
  jq -e 'type == "array" or has("messages") or has("results")' "$1" >/dev/null 2>&1
}

state_load

# --- Phase 1: the deduplicated channel set -----------------------------------------------------
# Keyed by CHANNEL, not by project: several projects legitimately watch the same channel, and each
# distinct channel needs exactly one read. The workspace is resolved per channel from the first
# watching project (ea-config.sh has already applied the project-overrides-agent fallback).
CHANNELS="$TMPD/channels.all"; : > "$CHANNELS"
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  [ "$(cfg "projects.${slug}.source.slack")" = "configured" ] || continue
  cfgl "projects.${slug}.slack.channels" >> "$CHANNELS"
done < <(cfgl project)
sed -i.bak -E '/^[[:space:]]*$/d' "$CHANNELS" 2>/dev/null; rm -f "${CHANNELS}.bak"
sort -u "$CHANNELS" -o "$CHANNELS"

if [ ! -s "$CHANNELS" ]; then
  log "poll-slack: no project has slack.channels configured; nothing to do"
  exit 0
fi

FOUND=0; ROUTED=0; UNROUTED=0; SKIPPED=0; UNCHANGED=0; RESUMED=0; ERRORS=0; FILTERED=0; ASKED=0
SKIPPED_IDS=""; TOKEN_SKIP=0
HIGHEST="$TMPD/highest"; : > "$HIGHEST"

# --- The four questions ------------------------------------------------------------------------
# Static, written here, never derived from message text — that is what keeps the trigger vocabulary
# closed and the containment argument above true. Each is one narrow judgment with concrete
# criteria on both sides, per the System One guidance; the composition happens in bash below.
cat > "$TMPD/questions.json" <<'QJSON'
{
  "is_question": {
    "type": "noul",
    "instructions": "The Slack message in `message.text` asks for information, a decision, or help, and is waiting for another person to respond.",
    "criteria": {
      "true": "It poses a genuine question or request that expects an answer from someone else.",
      "false": "It is a statement, announcement, status update, acknowledgement, or a rhetorical question the author goes on to answer themselves."
    }
  },
  "directed_at_user": {
    "type": "noul",
    "instructions": "The message in `message.text` is aimed at the person described in `user` — by @-mention, by name, by replying to them, or because it plainly falls in an area they own. `user.match_terms` lists the configured terms that caused this message to be inspected; some are that person's handles and some are topics they own, so a term appearing in the text is weak evidence on its own.",
    "criteria": {
      "true": "A specific person is being asked, and `user` is that person or one of a small named group that includes them.",
      "false": "It is addressed to the channel at large, or to somebody else by name, or the person in `user` only appears incidentally."
    }
  },
  "already_answered": {
    "type": "noul",
    "instructions": "The question in `message.text` has already been satisfactorily answered in `thread`.",
    "criteria": {
      "true": "A reply in `thread` answers it, or the author states they worked it out or no longer need help.",
      "false": "`thread` is empty, or holds only acknowledgements, reactions, or clarifying questions, and the question is still open."
    }
  },
  "needs_engineer": {
    "type": "noul",
    "instructions": "Answering `message.text` correctly requires knowledge of the codebase, the implementation, a deployment, or the status of engineering work.",
    "criteria": {
      "true": "A correct answer depends on how the software works, what was built or shipped, or the state of engineering work in progress.",
      "false": "It is social chatter, scheduling, an administrative request, or something anyone in the channel could answer without engineering context."
    }
  }
}
QJSON

while IFS= read -r channel || [ -n "$channel" ]; do
  [ -n "$channel" ] || continue

  # Tier 0 for this channel, plus the union of its watchers' keywords (the discovery filter).
  cands="$(route_candidates_slack "$channel" | sort -u | tr '\n' ' ' | sed 's/ $//')"
  [ -n "$cands" ] || continue

  KWFILE="$TMPD/kw.$$"; : > "$KWFILE"
  WORKSPACE=""; IGNORE_BOTS=0
  for s in $cands; do
    route_slack_keywords "$s" >> "$KWFILE"
    [ -n "$WORKSPACE" ] || WORKSPACE="$(cfg "projects.${s}.slack.workspace")"
    # ANY watcher opting out of bot messages suppresses them for the whole channel. The channel is
    # read once and shared, so the strictest watcher has to win — the alternative is re-reading it
    # per project, which is the per-project collection bug this collector exists to remove.
    [ "$(cfg "projects.${s}.slack.ignore_bots")" = "true" ] && IGNORE_BOTS=1
  done
  sed -i.bak -E '/^[[:space:]]*$/d' "$KWFILE" 2>/dev/null; rm -f "${KWFILE}.bak"
  sort -u "$KWFILE" -o "$KWFILE"

  slack_call "$TMPD/read.json" read "$channel" "$READ_COUNT"
  rc=$?
  if [ "$rc" -eq 75 ]; then
    # Clean skip, not an error: the token re-auths on its own. Advance nothing.
    log "poll-slack: Slack token unavailable (exit 75); skipping this poll's Slack read"
    TOKEN_SKIP=1
    break
  fi
  if [ "$rc" -ne 0 ]; then
    log "poll-slack: ERROR reading ${channel} (exit ${rc}): $(head -c 200 "$TMPD/slackerr" 2>/dev/null)"
    ERRORS=$((ERRORS+1)); continue
  fi
  if ! slack_shape_ok "$TMPD/read.json"; then
    log "poll-slack: unrecognised read response shape for ${channel}; leaving Slack to the model"
    exit 3
  fi

  while IFS= read -r msg || [ -n "$msg" ]; do
    [ -n "$msg" ] || continue
    mts="$(printf '%s' "$msg" | jq -r '.ts // empty')"
    [ -n "$mts" ] || continue
    mtext="$(printf '%s' "$msg" | jq -r '.text // ""')"
    muid="$(printf '%s' "$msg" | jq -r '.user_id // ""')"
    muname="$(printf '%s' "$msg" | jq -r '.user_name // ""')"
    mreplies="$(printf '%s' "$msg" | jq -r '(.reply_count // 0) | tostring')"
    mthread="$(printf '%s' "$msg" | jq -r '.thread_ts // empty')"

    # The user's OWN messages are never questions for the user. Deterministic and free.
    if [ -n "$USER_ID" ] && [ "$muid" = "$USER_ID" ]; then continue; fi

    # ignore_bots is BEST EFFORT and says so. Neither backend exposes a subtype or bot_id field —
    # scripts/slack-mcp.sh only recovers a user id matching (U…), so an app post yields a B-prefixed
    # or empty id. Only a B-prefix is treated as a bot: skipping on an EMPTY id would also drop
    # every message whose identity line simply failed to parse, turning a formatting change into
    # silent data loss. The needs_engineer / is_question judgments are the real backstop for app noise.
    if [ "$IGNORE_BOTS" -eq 1 ]; then
      case "$muid" in B*) continue ;; esac
    fi

    # --- discovery filter: at least one watching project's keyword, whole-word -----------------
    # Whole-word via _rt_has_word, not substring: a keyword like "ci" otherwise fires on "specific"
    # and "decision", which is how a relevance filter turns into a firehose.
    hit=0
    while IFS= read -r kw || [ -n "$kw" ]; do
      [ -n "$kw" ] || continue
      if _rt_has_word "$mtext" "$kw"; then hit=1; break; fi
    done < "$KWFILE"
    [ "$hit" -eq 1 ] || continue

    sid="${channel}:${mts}"
    FOUND=$((FOUND+1))

    excerpt="$(printf '%s' "$mtext" | tr '\n\r\t' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//' | cut -c1-60)"
    [ -n "$excerpt" ] || excerpt="(no text)"

    # --- routing -------------------------------------------------------------------------------
    route_out="$(route_ticket --tracker slack --candidates "$cands" --title "$excerpt" \
                   --body "$(printf '%s' "$mtext" | head -c 20000)")"
    slug="$(printf '%s' "$route_out" | cut -f1)"
    rmethod="$(printf '%s' "$route_out" | cut -f2)"
    rrat="$(printf '%s' "$route_out" | cut -f3)"
    needs_route="$(printf '%s' "$route_out" | cut -f4)"
    matched="$(printf '%s' "$route_out" | cut -f5)"

    if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then
      if [ "$slug" != "_unrouted" ]; then continue; fi
      case " $matched " in *" $ONLY_PROJECT "*) ;; *) continue ;; esac
    fi

    # --- recency --------------------------------------------------------------------------------
    # After routing, because the cutoff is per project (matching the per-project state the skill
    # keeps). Compared with awk: a Slack ts is a decimal string and `[ "$a" \> "$b" ]` would compare
    # it lexically, which is right for equal-width values and wrong the moment one is not.
    if [ "$slug" != "_unrouted" ]; then
      last="$(state_get "projects|${slug}|slack|last_checked_ts")"
      if [ -n "$last" ] && awk -v a="$mts" -v b="$last" 'BEGIN { exit !(a+0 <= b+0) }'; then
        UNCHANGED=$((UNCHANGED+1)); continue
      fi
    fi

    # --- reconciliation -------------------------------------------------------------------------
    # Terminal state is absorbing: a thread that gets more replies after you answered it must not
    # re-enter the queue (references/queue-reconciliation.md).
    disp="$(queue_disposition slack-question "$sid")"
    target=""
    case "$disp" in
      skip)        SKIPPED=$((SKIPPED+1)); SKIPPED_IDS="${SKIPPED_IDS}${SKIPPED_IDS:+, }${sid}"; continue ;;
      unchanged:*) UNCHANGED=$((UNCHANGED+1)); continue ;;
      update:*)    target="${disp#update:}" ;;
      create)      target="${EA_AGENT_DIR}/queue/incoming/$(queue_filename slack-question "${channel}-${mts//./-}" "$TS_PREFIX")" ;;
    esac

    # --- thread context --------------------------------------------------------------------------
    # Fetched ONLY here, for candidates that survived every free filter: it is a second network call
    # per message, and it is also the evidence the already_answered judgment needs.
    : > "$TMPD/thread.txt"
    if [ "${mreplies:-0}" -gt 0 ] 2>/dev/null; then
      if slack_call "$TMPD/thread.json" thread "$channel" "${mthread:-$mts}" && slack_shape_ok "$TMPD/thread.json"; then
        slack_messages "$TMPD/thread.json" \
          | jq -r '"**@" + (.user_name // "unknown") + ":** " + ((.text // "") | gsub("\n"; " "))' \
          > "$TMPD/thread.txt" 2>/dev/null
      fi
    fi

    # --- the relevance gate ----------------------------------------------------------------------
    jq -n --arg ch "$channel" --arg un "$USER_NAME" --arg ui "$USER_ID" \
          --arg au "$muname" --arg ai "$muid" --arg tx "$mtext" \
          --argjson rc "${mreplies:-0}" \
          --rawfile kw "$KWFILE" --rawfile th "$TMPD/thread.txt" \
      '{channel: $ch,
        user: {name: $un, id: $ui, match_terms: ($kw | split("\n") | map(select(length > 0)))},
        message: {author: $au, author_id: $ai, text: $tx, reply_count: $rc},
        thread: ($th | split("\n") | map(select(length > 0)))}' > "$TMPD/state.json" 2>/dev/null

    if [ ! -s "$TMPD/state.json" ]; then
      # An empty state file would be sent as `state: null` and judged on nothing at all, which is
      # strictly worse than not asking. Treat it as an error so the cutoff stays put.
      log "poll-slack: could not build request state for ${sid} (jq --rawfile unsupported?); not queuing"
      ERRORS=$((ERRORS+1)); continue
    fi

    if ! ts_ask "$TMPD/state.json" "$TMPD/questions.json" "$TMPD/answers.json"; then
      # A judgment that could not be made must NOT become a silent "no". Count it as an error so
      # the run reports non-zero and cron-poll.sh hands Slack back to the model, rather than
      # advancing the cutoff past a message nobody ever looked at.
      log "poll-slack: relevance request failed for ${sid}; not queuing, leaving the cutoff alone"
      ERRORS=$((ERRORS+1)); continue
    fi
    ASKED=$((ASKED+1))

    p_q="$(ts_noul "$TMPD/answers.json" is_question)"
    p_d="$(ts_noul "$TMPD/answers.json" directed_at_user)"
    p_a="$(ts_noul "$TMPD/answers.json" already_answered)"
    p_e="$(ts_noul "$TMPD/answers.json" needs_engineer)"
    if [ -z "$p_q" ] || [ -z "$p_d" ] || [ -z "$p_a" ] || [ -z "$p_e" ]; then
      log "poll-slack: incomplete relevance answers for ${sid}; not queuing"
      ERRORS=$((ERRORS+1)); continue
    fi
    scores="question=${p_q} directed=${p_d} answered=${p_a} engineer=${p_e}"

    if ! { ts_ge "$p_q" "$MIN_QUESTION" && ts_ge "$p_d" "$MIN_DIRECTED" \
        && ts_le "$p_a" "$MAX_ANSWERED" && ts_ge "$p_e" "$MIN_ENGINEER"; }; then
      # Judged irrelevant. The cutoff DOES advance past it (below) — that is the point of asking.
      FILTERED=$((FILTERED+1))
      printf '%s\n' "$mts" >> "$HIGHEST"
      continue
    fi

    # --- permalink ---------------------------------------------------------------------------
    # Built, not read: neither backend returns one. `workspace` is usually the team domain, in
    # which case this is the canonical archive URL; when it is a team_id the host is wrong but the
    # path still resolves through slack.com, so the link degrades rather than breaking.
    if [ -n "$WORKSPACE" ]; then
      url="https://${WORKSPACE}.slack.com/archives/${channel}/p${mts//./}"
    else
      url="https://slack.com/archives/${channel}/p${mts//./}"
    fi

    printf '%s\n' "$mtext" > "$TMPD/body"
    if [ "$DRY_RUN" -eq 0 ]; then
      write_slack_item --path "$target" --source-url "$url" --source-id "$sid" --title "$excerpt" \
        --priority normal --created-at "$RUN_TS" --project "$slug" \
        --channel-id "$channel" --channel-name "" --message-ts "$mts" \
        --author "$muname" --author-id "$muid" --matched "$matched" \
        --routing-method "$rmethod" --routing-rationale "$rrat" \
        --relevance-method typesafe --relevance-scores "$scores" \
        --body-file "$TMPD/body" --thread-file "$TMPD/thread.txt"
    fi

    printf '%s\n' "$target" >> "$WRITTEN"
    printf '%s\n' "$mts" >> "$HIGHEST"
    if [ "$slug" = "_unrouted" ]; then
      UNROUTED=$((UNROUTED+1))
    else
      ROUTED=$((ROUTED+1))
    fi
    emit "$(printf 'draft\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$target" "slack-question" "$slug" "$sid" "$needs_route" "0" "$excerpt")"
  done < <(slack_messages "$TMPD/read.json")
  rm -f "$KWFILE"
done < "$CHANNELS"

# --- Phase 3: resume sweep ----------------------------------------------------------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -qxF "$f" "$WRITTEN"; then continue; fi
  RESUMED=$((RESUMED+1))
  emit "$(printf 'resume\t%s\t%s\t%s\t%s\t0\t0\t%s' \
    "$f" "$(fm "$f" type)" "$(fm "$f" project)" "$(fm "$f" source_id)" "$(fm "$f" title)")"
done < <(poll_resume_candidates)

# --- State --------------------------------------------------------------------------------------
# ZERO-MESSAGE POLLS DO NOT ADVANCE THE CUTOFF, and this is the one source where that is correct.
# last_checked_ts is a Slack MESSAGE timestamp, not a wall clock (SKILL.md §3e), so when nothing was
# read there is no higher timestamp to move to and writing a clock value here would skip every
# message posted in between. A token-expiry skip likewise advances nothing: no channel was read.
#
# The value written is the highest ts this run actually CONSIDERED — including messages the
# relevance gate rejected. That is deliberate: a rejected message has been judged, so re-examining
# it next tick would pay for the same judgment forever.
# AND NOT ON A RUN THAT HAD ERRORS. An error exits 3, which hands Slack back to the model — but a
# cutoff already advanced past the messages this run judged would hide them from that fallback too,
# so a transient failure would silently eat every message around it. Re-judging a handful next tick
# is the cheaper mistake; reconciliation stops anything already written from being duplicated.
if [ "$DRY_RUN" -eq 0 ] && [ "$TOKEN_SKIP" -eq 0 ] && [ "$ERRORS" -eq 0 ] && [ -s "$HIGHEST" ]; then
  top="$(sort -g "$HIGHEST" | tail -1)"
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then continue; fi
    [ "$(cfg "projects.${slug}.source.slack")" = "configured" ] || continue
    prev="$(state_get "projects|${slug}|slack|last_checked_ts")"
    if [ -z "$prev" ] || awk -v a="$top" -v b="$prev" 'BEGIN { exit !(a+0 > b+0) }'; then
      state_set "projects|${slug}|slack|last_checked_ts" "$top"
    fi
  done < <(cfgl project)
  state_save
fi

printf 'Found %d candidate Slack message(s). %d routed, %d unrouted, %d filtered by relevance, %d skipped (already handled), %d unchanged, %d resumed, %d judged.\n' \
  "$FOUND" "$ROUTED" "$UNROUTED" "$FILTERED" "$SKIPPED" "$UNCHANGED" "$RESUMED" "$ASKED"
if [ -n "$SKIPPED_IDS" ]; then
  printf 'Skipped (terminal): %s\n' "$SKIPPED_IDS"
fi
[ "$TOKEN_SKIP" -eq 0 ] || printf 'Slack token unavailable this run; cutoff left unchanged.\n'
[ "$ERRORS" -eq 0 ] || exit 3
exit 0
