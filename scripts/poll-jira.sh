#!/bin/bash
# poll-jira.sh — deterministic collector for Jira tickets.
#
# Replaces the mechanical half of skills/poll-jira/SKILL.md: the multi-source normalization, the
# deduplicated per-key JQL query, the timezone conversion, reconciliation, routing (tiers 0-3a),
# kind classification (tier 1, which is TERMINAL for Jira), queue-file writing, and state. It does
# NOT draft — it writes items to queue/incoming/ and emits a manifest naming what still needs a
# model.
#
# WHY REST AND NOT MCP. Every other Jira surface in this plugin goes through mcp__atlassian__*,
# which a bash script cannot call — that is precisely why config/engineer.example.yaml used to say
# Jira "always stays model-driven". So this talks to the Jira Cloud REST API directly with curl.
# Consequences that are NOT incidental:
#
#   • API v2, NOT v3. v3 returns `description` as an Atlassian Document Format tree, and
#     reconstructing prose from that JSON in bash would be a parser of its own — with the failure
#     mode being a queue item whose ### Description is empty or mangled, which a human then approves
#     work from. v2 returns description as text. Both are supported on Jira Cloud.
#   • jq is a HARD dependency here and a SOFT one for the poll: no jq means exit 3, and cron-poll.sh
#     leaves Jira to the model exactly as before. CLAUDE.md sets "the cron path is jq-free" as
#     policy for the collectors that can honour it (the GitHub ones use `gh --jq`, gh's embedded
#     engine); there is no equivalent here, so the dependency is gated rather than assumed.
#   • The credential is resolved by lib-secret.sh and NEVER read from engineer.yaml. It is passed to
#     curl via `--config -` (stdin) rather than `-u`, so it never appears in the process list.
#
# THE TIMEZONE TRAP, carried over verbatim from the skill because it silently queues NOTHING:
# a bare datetime in JQL (`updated > "yyyy-MM-dd HH:mm"`) is interpreted in the searching account's
# Jira PROFILE timezone, not UTC. The watermark is stored in UTC, so handing its clock digits to JQL
# shifts the window by the account offset — a "…14:03Z" watermark becomes 14:03 Denver = 20:03Z,
# ~6h into the future, and every ticket updated during working hours falls before the cutoff. The
# poll then reports `status: ok` having queued nothing, indistinguishable from a genuinely quiet
# day. The offset is read off a real returned timestamp (already DST-correct, no tz database), never
# hardcoded.
#
# Usage: poll-jira.sh [--project <slug>] [--run-ts <iso>] [--dry-run] [--manifest <file>]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib-paths.sh"
. "${SCRIPT_DIR}/lib-yaml.sh"
. "${SCRIPT_DIR}/lib-time.sh"
. "${SCRIPT_DIR}/lib-queue.sh"
. "${SCRIPT_DIR}/lib-queue-write.sh"
. "${SCRIPT_DIR}/lib-routing.sh"
. "${SCRIPT_DIR}/lib-ticket-kind.sh"
. "${SCRIPT_DIR}/lib-state.sh"
. "${SCRIPT_DIR}/lib-secret.sh"

ONLY_PROJECT=""; RUN_TS=""; DRY_RUN=0; MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)  ONLY_PROJECT="$2"; shift 2 ;;
    --run-ts)   RUN_TS="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help)  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "poll-jira.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_TS" ] || RUN_TS="$(iso_now)"
TS_PREFIX="$(queue_ts)"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
WRITTEN="$TMPD/written"; : > "$WRITTEN"
log()  { printf '%s\n' "$*" >&2; }
emit() { [ -n "$MANIFEST" ] && printf '%s\n' "$*" >> "$MANIFEST"; return 0; }
b64d() { base64 -d 2>/dev/null || base64 -D 2>/dev/null; }

# --- Preconditions. Every one of these is a CLEAN SKIP (exit 3), never an error ---------------
# cron-poll.sh treats a non-zero collector as "leave this source to the model", which is the
# correct fallback for an install that has not set up REST access: behaviour is exactly what it was
# before this script existed. Exiting non-zero on a missing optional dependency would instead turn
# an unconfigured source into a failed poll.
command -v curl >/dev/null 2>&1 || { log "poll-jira: curl not found; leaving Jira to the model"; exit 3; }
command -v jq   >/dev/null 2>&1 || { log "poll-jira: jq not found; leaving Jira to the model"; exit 3; }

EA_CFG="$("${SCRIPT_DIR}/ea-config.sh" dump)"; export EA_CFG
cfg()  { printf '%s\n' "$EA_CFG" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }
cfgl() { printf '%s\n' "$EA_CFG" | awk -v p="$1[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}'; }

JIRA_SITE="$(cfg agent.jira.site)"
JIRA_EMAIL="$(cfg agent.jira.email)"
JIRA_API_BASE="$(cfg agent.jira.api_base)"; JIRA_API_BASE="${JIRA_API_BASE:-/rest/api/2}"
[ -n "$JIRA_SITE" ]  || { log "poll-jira: agent.jira.site is not set; leaving Jira to the model"; exit 3; }
[ -n "$JIRA_EMAIL" ] || { log "poll-jira: agent.jira.email is not set; leaving Jira to the model"; exit 3; }
JIRA_SITE="${JIRA_SITE#https://}"; JIRA_SITE="${JIRA_SITE#http://}"; JIRA_SITE="${JIRA_SITE%/}"

JIRA_TOKEN="$(ea_secret_resolve "$(cfg agent.jira.api_token_env)" "$(cfg agent.jira.api_token_file)" \
                                "$(ea_secret_service jira)" "$JIRA_EMAIL")"
if [ -z "$JIRA_TOKEN" ]; then
  log "poll-jira: no Jira API token available (checked env/file/keychain); leaving Jira to the model"
  exit 3
fi

# --- HTTP ------------------------------------------------------------------------------------
# The credential goes to curl on STDIN via `--config -`, never in argv: an argv credential is
# readable by any other process on the box via `ps`, and this runs unattended every 15 minutes.
# Writes the response body to $1 and prints the HTTP status.
jira_api() {
  local out="$1" method="$2" path="$3" body="${4:-}" code
  local url="https://${JIRA_SITE}${JIRA_API_BASE}${path}"
  if [ -n "$body" ]; then
    code="$(printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_TOKEN" \
      | curl -sS --config - -o "$out" -w '%{http_code}' \
             -X "$method" -H 'Content-Type: application/json' -H 'Accept: application/json' \
             --max-time 60 --data-binary "$body" "$url" 2>"$TMPD/curlerr")"
  else
    code="$(printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_TOKEN" \
      | curl -sS --config - -o "$out" -w '%{http_code}' \
             -X "$method" -H 'Accept: application/json' --max-time 60 "$url" 2>"$TMPD/curlerr")"
  fi
  printf '%s' "${code:-000}"
}

JIRA_FIELDS='["summary","description","issuetype","components","labels","status","priority","updated"]'

# jira_search <out> <jql> <maxResults> [fields-json] — one page of /search/jql.
jira_search() {
  local out="$1" jql="$2" mx="$3" fields="${4:-$JIRA_FIELDS}" token="${5:-}" body
  body="$(jq -nc --arg jql "$jql" --argjson mx "$mx" --argjson f "$fields" --arg tok "$token" \
    '{jql: $jql, maxResults: $mx, fields: $f} + (if $tok == "" then {} else {nextPageToken: $tok} end)')"
  jira_api "$out" POST "/search/jql" "$body"
}

state_load

# --- Phase 1: the deduplicated per-KEY query map ----------------------------------------------
# Keyed by Jira project key, NOT by engineer-agent project. In a real config six projects watch the
# single key WIRE; querying per project would issue six identical queries and — worse — let the
# global source_id dedup hand each ticket to whichever project the loop reached first, an arbitrary
# misroute with no _unrouted escape. (Same trap the GitHub collector documents for shared repos.)
KEYS="$TMPD/keys"; : > "$KEYS"
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  [ "$(cfg "projects.${slug}.source.jira")" = "configured" ] || continue
  assignee="$(cfg "projects.${slug}.jira.assignee")"
  [ -n "$assignee" ] || continue
  n="$(cfg "projects.${slug}.jira.source_count")"; n="${n:-0}"
  i=0
  while [ "$i" -lt "$n" ] 2>/dev/null; do
    jkey="$(cfg "projects.${slug}.jira.source.${i}.project")"
    if [ -n "$jkey" ]; then
      printf '%s\t%s\t%s\n' "$jkey" "$assignee" "$slug" >> "$KEYS"
      while IFS= read -r st; do
        [ -n "$st" ] && printf '%s\t%s\n' "$jkey" "$st" >> "$TMPD/statuses"
      done < <(cfgl "projects.${slug}.jira.statuses")
    fi
    i=$((i+1))
  done
done < <(cfgl project)
touch "$TMPD/statuses"

if [ ! -s "$KEYS" ]; then
  log "poll-jira: no project has jira configured; nothing to do"
  exit 0
fi

# --- Phase 1b: the account UTC offset, read ONCE ----------------------------------------------
# See the TIMEZONE TRAP note in the header. The bootstrap query deliberately carries NO `updated`
# filter, so it returns regardless of the very bug it exists to fix.
ALL_ASSIGNEES="$(cut -f2 "$KEYS" | sort -u)"
jql_quote_list() { local out="" v; while IFS= read -r v; do [ -n "$v" ] || continue
    # A JQL string is double-quoted; a literal " or \ inside must be escaped or the whole query is
    # rejected with Bad Request and the poll silently queues nothing.
    v="$(printf '%s' "$v" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    [ -n "$out" ] && out="${out}, "; out="${out}\"${v}\""; done; printf '%s' "$out"; }

ASSIGNEE_LIST="$(printf '%s\n' "$ALL_ASSIGNEES" | jql_quote_list)"
ACCOUNT_OFFSET_SECS=0
if [ -n "$ASSIGNEE_LIST" ]; then
  code="$(jira_search "$TMPD/tz.json" "assignee IN (${ASSIGNEE_LIST}) ORDER BY updated DESC" 1)"
  if [ "$code" = "200" ]; then
    tzstamp="$(jq -r '.issues[0].fields.updated // empty' "$TMPD/tz.json" 2>/dev/null)"
    off="$(printf '%s' "$tzstamp" | sed -nE 's/.*([+-][0-9]{2}:?[0-9]{2})$/\1/p')"
    if [ -n "$off" ]; then
      sign="${off:0:1}"; digits="${off:1}"; digits="${digits/:/}"
      ACCOUNT_OFFSET_SECS=$(( 10#${digits:0:2} * 3600 + 10#${digits:2:2} * 60 ))
      [ "$sign" = "-" ] && ACCOUNT_OFFSET_SECS=$(( -ACCOUNT_OFFSET_SECS ))
    fi
    # Zero issues assigned at all, or a Z-suffixed timestamp: treat the watermark as UTC. There is
    # nothing to miss in the first case, and nothing to convert in the second.
  else
    # A failed bootstrap must NOT silently fall back to +00:00 on an account that is not UTC — that
    # is the exact silent-empty-window bug. Refuse the run and let the model poll Jira instead.
    log "poll-jira: timezone bootstrap failed (HTTP ${code}); leaving Jira to the model"
    log "poll-jira: $(head -c 300 "$TMPD/tz.json" 2>/dev/null)"
    exit 3
  fi
fi

FOUND=0; ROUTED=0; UNROUTED=0; SKIPPED=0; UNCHANGED=0; CREATED=0; RESUMED=0; INVESTIGATIONS=0
SKIPPED_IDS=""; ERRORS=0
FAILED_KEYS=""

# agent.max_issue_age_days, the same guard the GitHub collector applies and for the same reason.
# It matters MORE here: when jira_projects.<key>.last_checked is absent the cutoff is the epoch, so
# a first scripted poll of a long-lived assigned backlog would queue years of tickets in one run
# and exhaust the run budget. (On an install that has been polling, the watermark is already
# present and this never fires.) 0 or absent = no limit.
MAX_AGE="$(cfg agent.max_issue_age_days)"; MAX_AGE="${MAX_AGE:-0}"

# --- Phase 2: one pass per distinct Jira project key ------------------------------------------
while IFS= read -r jkey; do
  [ -n "$jkey" ] || continue
  assignees="$(awk -F'\t' -v k="$jkey" '$1==k {print $2}' "$KEYS" | sort -u)"
  statuses="$(awk -F'\t' -v k="$jkey" '$1==k {print $2}' "$TMPD/statuses" | sort -u)"

  a_list="$(printf '%s\n' "$assignees" | jql_quote_list)"
  s_list="$(printf '%s\n' "$statuses"  | jql_quote_list)"

  watermark="$(state_get "jira_projects|${jkey}|last_checked")"
  [ -n "$watermark" ] || watermark="1970-01-01T00:00:00Z"
  wm_epoch="$(epoch_of_iso "$watermark")"
  [ -n "$wm_epoch" ] || wm_epoch=0
  # UTC watermark -> account-local wall clock, minute precision, which is what JQL will read it as.
  local_cutoff="$(iso_of_epoch "$(( wm_epoch + ACCOUNT_OFFSET_SECS ))" | sed -E 's/T/ /; s/:[0-9]{2}Z$//')"

  jql="project = \"${jkey}\" AND assignee IN (${a_list})"
  [ -n "$s_list" ] && jql="${jql} AND status IN (${s_list})"
  jql="${jql} AND updated > \"${local_cutoff}\" ORDER BY updated ASC"

  ISSUES="$TMPD/issues"; : > "$ISSUES"
  page_token=""; page_ok=1
  while :; do
    code="$(jira_search "$TMPD/page.json" "$jql" 100 "$JIRA_FIELDS" "$page_token")"
    if [ "$code" != "200" ]; then
      log "poll-jira: ERROR querying ${jkey} (HTTP ${code}): $(jq -r '.errorMessages[0]? // empty' "$TMPD/page.json" 2>/dev/null | head -c 200)"
      page_ok=0; ERRORS=$((ERRORS+1)); FAILED_KEYS="${FAILED_KEYS} ${jkey}"; break
    fi
    jq -r '.issues[]? | tojson | @base64' "$TMPD/page.json" >> "$ISSUES" 2>/dev/null
    page_token="$(jq -r '.nextPageToken // empty' "$TMPD/page.json" 2>/dev/null)"
    [ -n "$page_token" ] || break
  done

  if [ "$page_ok" -ne 1 ]; then
    # Leave this key's cutoff untouched so the next run retries the same window. Advancing it after
    # a failed query would silently drop every ticket in that window, forever.
    log "poll-jira: query failed for ${jkey}; leaving cutoff unchanged"
    continue
  fi

  while IFS= read -r b64 || [ -n "$b64" ]; do
    [ -n "$b64" ] || continue
    printf '%s' "$b64" | b64d > "$TMPD/issue.json" 2>/dev/null || continue
    key="$(jq -r '.key // empty' "$TMPD/issue.json")"
    [ -n "$key" ] || continue

    # Recency guard BEFORE the counter: an age-filtered ticket was never a candidate, and counting
    # it would make the report claim tickets were found that no branch below can account for.
    # iso_older_than fails toward DOING the work on an unparseable timestamp, so a format change can
    # never silently drop live tickets.
    updated_at="$(jq -r '.fields.updated // ""' "$TMPD/issue.json")"
    if [ "$MAX_AGE" -gt 0 ] 2>/dev/null && iso_older_than "$updated_at" "$MAX_AGE"; then
      continue
    fi
    FOUND=$((FOUND+1))

    title="$(jq -r '.fields.summary // ""' "$TMPD/issue.json")"
    jstatus="$(jq -r '.fields.status.name // ""' "$TMPD/issue.json")"
    jtype="$(jq -r '.fields.issuetype.name // ""' "$TMPD/issue.json")"
    jprio="$(jq -r '.fields.priority.name // ""' "$TMPD/issue.json")"
    jq -r '.fields.description // ""' "$TMPD/issue.json" > "$TMPD/body"
    # Trailing newline: a file whose last line is unterminated makes `read` return non-zero, so a
    # `while read` loop silently drops it. See lib-queue-write.sh.
    jq -r '.fields.components[]?.name // empty' "$TMPD/issue.json" > "$TMPD/comps"; printf '' >> "$TMPD/comps"
    jq -r '.fields.labels[]? // empty'          "$TMPD/issue.json" > "$TMPD/labels"
    : > "$TMPD/comments"

    sid="$key"
    url="https://${JIRA_SITE}/browse/${key}"

    # --- routing (tiers 0-3a) ------------------------------------------------------------
    # The candidate set is ALWAYS the full watcher list, even under --project: narrowing it would
    # let a genuinely ambiguous ticket record routing_method: single-candidate, a false audit trail.
    cands="$(route_candidates_jira "$jkey" | tr '\n' ' ' | sed 's/ $//')"
    route_out="$(route_ticket --tracker jira --jira-key "$jkey" --candidates "$cands" \
                   --title "$title" --body "$(cat "$TMPD/body")" \
                   --labels-file "$TMPD/labels" --components-file "$TMPD/comps")"
    slug="$(printf '%s' "$route_out" | cut -f1)"
    rmethod="$(printf '%s' "$route_out" | cut -f2)"
    rrat="$(printf '%s' "$route_out" | cut -f3)"
    needs_route="$(printf '%s' "$route_out" | cut -f4)"
    matched="$(printf '%s' "$route_out" | cut -f5)"

    if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then
      if [ "$slug" != "_unrouted" ]; then continue; fi
      case " $matched " in *" $ONLY_PROJECT "*) ;; *) continue ;; esac
    fi

    # --- kind (tier 1, TERMINAL for Jira) -------------------------------------------------
    # A Jira issue always has a type, so Tier 1 always answers and the title tier is unreachable —
    # which is what stops a Story titled "Add spike protection to the rate limiter" being drafted
    # as an investigation. needs_kind is therefore always 0 for Jira.
    typ="ticket"; kmethod=""; krat=""; needs_kind=0
    if [ "$slug" != "_unrouted" ]; then
      cfgl "projects.${slug}.investigation.jira_types" > "$TMPD/k_jt"
      kind_out="$(ticket_kind_classify --tracker jira --title "$title" \
                    --jira-issue-type "$jtype" --jira-types-file "$TMPD/k_jt")"
      typ="$(printf '%s' "$kind_out" | cut -f1)"
      kmethod="$(printf '%s' "$kind_out" | cut -f2)"
      krat="$(printf '%s' "$kind_out" | cut -f3)"
      needs_kind="$(printf '%s' "$kind_out" | cut -f4)"
    fi

    # --- reconciliation ------------------------------------------------------------------
    # Family-wide and terminal-inclusive. Terminal state is ABSORBING: engineer-agent recording its
    # own findings as a Jira comment bumps `updated`, so "re-queue anything updated since
    # last_checked" is self-sustaining. Never re-queue finished work.
    disp="$(queue_disposition "$typ" "$sid")"
    target=""
    case "$disp" in
      skip)
        SKIPPED=$((SKIPPED+1)); SKIPPED_IDS="${SKIPPED_IDS}${SKIPPED_IDS:+, }${sid}"
        if [ "$slug" != "_unrouted" ] && [ "$DRY_RUN" -eq 0 ]; then
          state_list_add "projects|${slug}|jira|seen_tickets" "$sid"
        fi
        continue ;;
      unchanged:*)
        UNCHANGED=$((UNCHANGED+1))
        if [ "$slug" != "_unrouted" ] && [ "$DRY_RUN" -eq 0 ]; then
          state_list_add "projects|${slug}|jira|seen_tickets" "$sid"
        fi
        continue ;;
      update:*)
        target="${disp#update:}"
        old_base="$(basename "$target")"
        old_prefix="$(printf '%s' "$old_base" | cut -d- -f1-2)"
        new_base="$(queue_filename "$typ" "$key" "$old_prefix")"
        if [ "$old_base" != "$new_base" ]; then
          rm -f "$target"
          target="$(dirname "$target")/$new_base"
        fi ;;
      create)
        target="${EA_AGENT_DIR}/queue/incoming/$(queue_filename "$typ" "$key" "$TS_PREFIX")" ;;
    esac

    # Recent comments are fetched ONLY for an item we are actually going to write. Pulling them in
    # the search would multiply every page by the comment volume of tickets that then turn out to
    # be skipped as already-handled — which is the common case.
    if [ "$DRY_RUN" -eq 0 ]; then
      ccode="$(jira_api "$TMPD/c.json" GET "/issue/${key}/comment?maxResults=5&orderBy=-created")"
      if [ "$ccode" = "200" ]; then
        jq -r '[.comments[]?] | sort_by(.created) | .[-3:] | .[]
               | "**" + (.author.displayName // "unknown") + "** (" + ((.created // "")|split("T")[0]) + "):\n"
                 + ((.body // "") | tostring) + "\n"' "$TMPD/c.json" > "$TMPD/comments" 2>/dev/null
      fi
    fi

    # --- priority mapping (poll-jira step 5d) --------------------------------------------
    case "$(printf '%s' "$jprio" | tr '[:upper:]' '[:lower:]')" in
      highest|high) prio="urgent" ;;
      low|lowest)   prio="low" ;;
      *)            prio="normal" ;;
    esac

    if [ "$DRY_RUN" -eq 0 ]; then
      write_ticket_item --path "$target" --type "$typ" --source jira \
        --source-url "$url" --source-id "$sid" --title "$title" --priority "$prio" \
        --created-at "$RUN_TS" --project "$slug" --ticket-key "$key" --state "$jstatus" \
        --jira-issue-type "$jtype" --labels-file "$TMPD/labels" --components-file "$TMPD/comps" \
        --comments-file "$TMPD/comments" --matched "$matched" \
        --routing-method "$rmethod" --routing-rationale "$rrat" \
        --kind-method "$kmethod" --kind-rationale "$krat" --body-file "$TMPD/body"
    fi

    CREATED=$((CREATED+1))
    [ "$typ" = "ticket-investigation" ] && INVESTIGATIONS=$((INVESTIGATIONS+1))
    printf '%s\n' "$target" >> "$WRITTEN"
    if [ "$slug" = "_unrouted" ]; then
      UNROUTED=$((UNROUTED+1))
      # Deliberately NOT recorded in seen_tickets: an unrouted ticket must be re-checked every poll
      # until a human or a model assigns it.
    else
      ROUTED=$((ROUTED+1))
      if [ "$DRY_RUN" -eq 0 ]; then
        state_list_add "projects|${slug}|jira|seen_tickets" "$sid"
      fi
    fi
    emit "$(printf 'draft\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$target" "$typ" "$slug" "$sid" "$needs_route" "$needs_kind" "$title")"
  done < "$ISSUES"

  # Advance the per-key cutoff even when the key produced zero tickets: a source that found nothing
  # was still polled successfully, and this source FILTERS on the cutoff, so a stale one re-scans
  # the same backlog every cycle.
  if [ "$DRY_RUN" -eq 0 ]; then
    state_set "jira_projects|${jkey}|last_checked" "$RUN_TS"
  fi
done < <(cut -f1 "$KEYS" | sort -u)

# --- Phase 3: resume sweep --------------------------------------------------------------------
# Anything already in incoming/ without a "## Draft Response" is STRANDED — invisible to both
# approval paths, because only drafts/ is reachable by the gate. Re-emitting it makes a failed
# drafting phase self-heal on the next tick instead of parking real work forever, silently.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -qxF "$f" "$WRITTEN"; then continue; fi
  RESUMED=$((RESUMED+1))
  emit "$(printf 'resume\t%s\t%s\t%s\t%s\t0\t0\t%s' \
    "$f" "$(fm "$f" type)" "$(fm "$f" project)" "$(fm "$f" source_id)" "$(fm "$f" title)")"
done < <(poll_resume_candidates)

if [ "$DRY_RUN" -eq 0 ]; then
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then continue; fi
    [ "$(cfg "projects.${slug}.source.jira")" = "configured" ] || continue
    # Skip a project any of whose keys failed this run. The per-key cutoff is what JQL filters on,
    # but poll-jira documents projects.<slug>.jira.last_checked as a backward-compat FALLBACK for
    # it — so advancing it after a failed query can still silently swallow that window.
    skip_slug=0
    n="$(cfg "projects.${slug}.jira.source_count")"; n="${n:-0}"; i=0
    while [ "$i" -lt "$n" ] 2>/dev/null; do
      case " $FAILED_KEYS " in *" $(cfg "projects.${slug}.jira.source.${i}.project") "*) skip_slug=1 ;; esac
      i=$((i+1))
    done
    [ "$skip_slug" -eq 1 ] && continue
    state_set "projects|${slug}|jira|last_checked" "$RUN_TS"
  done < <(cfgl project)
  state_save
fi

# The reporting contract from references/queue-reconciliation.md: a poll that says "0 new items"
# when it skipped six already-handled tickets is indistinguishable from a broken poll. Naming the
# investigation count makes a misclassification wave visible in the receipt rather than only in the
# queue after the fact.
printf 'Found %d Jira ticket(s). %d routed (of which %d investigations), %d unrouted, %d skipped (already handled), %d unchanged, %d resumed.\n' \
  "$FOUND" "$ROUTED" "$INVESTIGATIONS" "$UNROUTED" "$SKIPPED" "$UNCHANGED" "$RESUMED"
if [ -n "$SKIPPED_IDS" ]; then
  printf 'Skipped (terminal): %s\n' "$SKIPPED_IDS"
fi
# A partial failure must not look like a clean run: cron-poll.sh keys "was this source scripted?"
# off the exit status, so a key that errored has to leave Jira to the model this cycle.
[ "$ERRORS" -eq 0 ] || exit 3
exit 0
