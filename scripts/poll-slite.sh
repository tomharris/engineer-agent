#!/bin/bash
# poll-slite.sh — deterministic collector for Slite docs tagged for review.
#
# Replaces the mechanical half of skills/poll-slite/SKILL.md: the per-label search, the recency
# filter, reconciliation, routing, queue-file writing, and state. It does NOT draft — it writes
# doc-review items to queue/incoming/ and emits a manifest naming what still needs a model.
#
# WHY REST AND NOT MCP: same reason as poll-jira.sh — mcp__slite__* is unreachable from bash, which
# is why config/engineer.example.yaml used to say Slite "always stays model-driven". curl + the
# Slite REST API instead, with jq a HARD dependency here and a SOFT one for the poll (no jq =>
# exit 3 and Slite is left to the model, exactly as before).
#
# ONE COLLECTION PASS, NOT ONE PER PROJECT. The skill iterates over projects and queues a matching
# doc for each one, which in a real config is a live bug rather than a hypothetical: all six
# projects set doc_labels: ["needs-review"], so every review doc matches every project and the
# global source_id dedup silently awards it to whichever project the loop reached first. Docs are
# therefore collected ONCE, deduplicated by id, and routed through references/routing-ladder.md, so
# an ambiguous doc becomes a visible `_unrouted` item instead of an invisible arbitrary assignment.
#
# THE LABEL QUESTION, stated honestly. The Slite REST API's exposure of doc tags is not as
# well-specified as Jira's fields, so the label a doc carries is read from whichever of several
# plausible shapes the note object actually has (see slite_labels). When NONE of them is present,
# the doc is matched on the search that found it — the label was the query — and the item records
# `label_source: query` so a reader at the approval gate can see the match was weaker than a real
# tag comparison. An unrecognisable response shape exits 3 rather than guessing: a collector that
# silently decides no docs need review is indistinguishable from a quiet week.
#
# Usage: poll-slite.sh [--project <slug>] [--run-ts <iso>] [--dry-run] [--manifest <file>]
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

ONLY_PROJECT=""; RUN_TS=""; DRY_RUN=0; MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)  ONLY_PROJECT="$2"; shift 2 ;;
    --run-ts)   RUN_TS="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help)  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "poll-slite.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_TS" ] || RUN_TS="$(iso_now)"
TS_PREFIX="$(queue_ts)"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
WRITTEN="$TMPD/written"; : > "$WRITTEN"
log()  { printf '%s\n' "$*" >&2; }
emit() { [ -n "$MANIFEST" ] && printf '%s\n' "$*" >> "$MANIFEST"; return 0; }

command -v curl >/dev/null 2>&1 || { log "poll-slite: curl not found; leaving Slite to the model"; exit 3; }
command -v jq   >/dev/null 2>&1 || { log "poll-slite: jq not found; leaving Slite to the model"; exit 3; }

EA_CFG="$("${SCRIPT_DIR}/ea-config.sh" dump)"; export EA_CFG
cfg()  { printf '%s\n' "$EA_CFG" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }
cfgl() { printf '%s\n' "$EA_CFG" | awk -v p="$1[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}'; }

SLITE_BASE="$(cfg agent.slite.api_base)"; SLITE_BASE="${SLITE_BASE:-https://api.slite.com/v1}"
SLITE_BASE="${SLITE_BASE%/}"
SLITE_KEY="$(ea_secret_resolve "$(cfg agent.slite.api_key_env)" "$(cfg agent.slite.api_key_file)" \
                               "$(ea_secret_service slite)" "")"
if [ -z "$SLITE_KEY" ]; then
  log "poll-slite: no Slite API key available (checked env/file/keychain); leaving Slite to the model"
  exit 3
fi

# --- HTTP -------------------------------------------------------------------------------------
# The key goes in a header supplied via `--config -` (stdin) rather than `-H` in argv, so it is not
# visible in the process list of an unattended run. Writes the body to $1, prints the HTTP status.
slite_api() {
  local out="$1" path="$2" code
  code="$(printf 'header = "x-slite-api-key: %s"\n' "$SLITE_KEY" \
    | curl -sS --config - -o "$out" -w '%{http_code}' -H 'Accept: application/json' \
           --max-time 60 --get "${SLITE_BASE}${path}" 2>"$TMPD/curlerr")"
  printf '%s' "${code:-000}"
}

# urlenc <s> — percent-encode a query value. jq does this correctly (including UTF-8), and jq is
# already a hard dependency of this script.
urlenc() { printf '%s' "${1:-}" | jq -sRr '@uri'; }

# slite_hits <file> — the note objects out of a search response, whatever the envelope is called.
# `.hits`, `.notes`, `.results` and a bare array are all accepted; anything else is the
# unrecognisable-shape case that must exit 3 rather than silently yield zero docs.
slite_hits() {
  jq -c 'if type == "array" then .[]
         elif has("hits")    then .hits[]
         elif has("notes")   then .notes[]
         elif has("results") then .results[]
         else empty end' "$1" 2>/dev/null
}
slite_shape_ok() {
  jq -e 'type == "array" or has("hits") or has("notes") or has("results")' "$1" >/dev/null 2>&1
}

# slite_labels <note-json-file> — the doc's labels, one per line, from whichever shape carries them.
# Prints nothing when the note object exposes no tag field at all; the caller then falls back to
# the search query that found the doc, and records that it did.
slite_labels() {
  jq -r '[ (.tags // empty), (.labels // empty), (.attributes.tags // empty),
           (.metadata.tags // empty) ] | flatten
         | map(if type == "object" then (.name // .title // empty) else tostring end)
         | .[] // empty' "$1" 2>/dev/null | sed -E '/^[[:space:]]*$/d'
}

state_load

# --- Phase 1: the deduplicated label set ------------------------------------------------------
# Keyed by LABEL, not by project: several projects legitimately watch the same label, and each
# distinct label needs exactly one search.
LABELS="$TMPD/labels.all"; : > "$LABELS"
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  [ "$(cfg "projects.${slug}.source.slite")" = "configured" ] || continue
  cfgl "projects.${slug}.slite.doc_labels" >> "$LABELS"
done < <(cfgl project)
sort -u "$LABELS" -o "$LABELS"
sed -i.bak -E '/^[[:space:]]*$/d' "$LABELS" 2>/dev/null; rm -f "${LABELS}.bak"

if [ ! -s "$LABELS" ]; then
  log "poll-slite: no project has slite.doc_labels configured; nothing to do"
  exit 0
fi

FOUND=0; ROUTED=0; UNROUTED=0; SKIPPED=0; UNCHANGED=0; RESUMED=0; ERRORS=0
SKIPPED_IDS=""

SEEN_IDS="$TMPD/seen.ids"; : > "$SEEN_IDS"

while IFS= read -r label; do
  [ -n "$label" ] || continue
  code="$(slite_api "$TMPD/search.json" "/search-notes?query=$(urlenc "$label")")"
  if [ "$code" != "200" ]; then
    log "poll-slite: ERROR searching for '${label}' (HTTP ${code}): $(head -c 200 "$TMPD/search.json" 2>/dev/null)"
    ERRORS=$((ERRORS+1)); continue
  fi
  if ! slite_shape_ok "$TMPD/search.json"; then
    log "poll-slite: unrecognised search response shape; leaving Slite to the model"
    exit 3
  fi

  while IFS= read -r hit || [ -n "$hit" ]; do
    [ -n "$hit" ] || continue
    doc_id="$(printf '%s' "$hit" | jq -r '.id // .noteId // empty')"
    [ -n "$doc_id" ] || continue
    # Deduplicate ACROSS labels: a doc tagged both "needs-review" and "design" is one doc.
    grep -qxF "$doc_id" "$SEEN_IDS" && continue
    printf '%s\n' "$doc_id" >> "$SEEN_IDS"

    # Full note: the search payload is a summary, and the queue item needs the body.
    ncode="$(slite_api "$TMPD/note.json" "/notes/${doc_id}")"
    if [ "$ncode" != "200" ]; then
      log "poll-slite: ERROR fetching note ${doc_id} (HTTP ${ncode})"
      ERRORS=$((ERRORS+1)); continue
    fi

    title="$(jq -r '.title // .name // ""' "$TMPD/note.json")"
    url="$(jq -r '.url // .publicUrl // ""' "$TMPD/note.json")"
    [ -n "$url" ] || url="https://app.slite.com/api/s/${doc_id}"
    updated="$(jq -r '.updatedAt // .updated_at // .modifiedAt // ""' "$TMPD/note.json")"
    author="$(jq -r '(.author.displayName // .author.name // .createdBy.displayName // .createdBy.name // "")' "$TMPD/note.json")"
    jq -r '(.content // .markdown // .body // .text // "") | tostring' "$TMPD/note.json" > "$TMPD/body"

    # Labels: a real tag comparison when the API exposes one, else the query that found the doc.
    slite_labels "$TMPD/note.json" > "$TMPD/doclabels"
    label_source="tags"
    if [ ! -s "$TMPD/doclabels" ]; then
      printf '%s\n' "$label" > "$TMPD/doclabels"
      label_source="query"
    fi

    sid="slite:${doc_id}"
    FOUND=$((FOUND+1))

    # --- routing ---------------------------------------------------------------------------
    cands="$(route_candidates_slite "$TMPD/doclabels" | sort -u | tr '\n' ' ' | sed 's/ $//')"
    route_out="$(route_ticket --tracker slite --candidates "$cands" --title "$title" \
                   --body "$(head -c 20000 "$TMPD/body")" --labels-file "$TMPD/doclabels")"
    slug="$(printf '%s' "$route_out" | cut -f1)"
    rmethod="$(printf '%s' "$route_out" | cut -f2)"
    rrat="$(printf '%s' "$route_out" | cut -f3)"
    needs_route="$(printf '%s' "$route_out" | cut -f4)"
    matched="$(printf '%s' "$route_out" | cut -f5)"

    if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then
      if [ "$slug" != "_unrouted" ]; then continue; fi
      case " $matched " in *" $ONLY_PROJECT "*) ;; *) continue ;; esac
    fi

    # --- recency ---------------------------------------------------------------------------
    # Applied AFTER routing so the cutoff compared against is the routed project's, matching the
    # per-project state the skill keeps. An unparseable/absent updatedAt fails toward doing the
    # work, never toward silently dropping a doc.
    if [ "$slug" != "_unrouted" ] && [ -n "$updated" ]; then
      last="$(state_get "projects|${slug}|slite|last_checked")"
      if [ -n "$last" ]; then
        u_e="$(epoch_of_iso "$updated")"; l_e="$(epoch_of_iso "$last")"
        # Counted as UNCHANGED, not dropped silently. A bare `continue` here put the doc in NO
        # bucket, so the summary read "Found 1 ... 0 routed, 0 unrouted, 0 skipped, 0 unchanged"
        # -- a found doc accounted for nowhere, which is indistinguishable from a parse bug and
        # is the invisible-drop shape this collector exists to avoid. UNCHANGED is the honest
        # bucket: there is nothing to do because nothing moved since the last poll.
        if [ -n "$u_e" ] && [ -n "$l_e" ] && [ "$u_e" -le "$l_e" ]; then
          UNCHANGED=$((UNCHANGED+1)); continue
        fi
      fi
    fi

    # --- reconciliation --------------------------------------------------------------------
    # Terminal state is ABSORBING, and it matters more here than anywhere: posting review comments
    # back to the doc UPDATES it, so without this the doc just reviewed reappears every poll.
    disp="$(queue_disposition doc-review "$sid")"
    target=""
    case "$disp" in
      skip)
        SKIPPED=$((SKIPPED+1)); SKIPPED_IDS="${SKIPPED_IDS}${SKIPPED_IDS:+, }${sid}"
        continue ;;
      unchanged:*)
        UNCHANGED=$((UNCHANGED+1)); continue ;;
      update:*)
        target="${disp#update:}" ;;
      create)
        target="${EA_AGENT_DIR}/queue/incoming/$(queue_filename doc-review "$doc_id" "$TS_PREFIX")" ;;
    esac

    if [ "$DRY_RUN" -eq 0 ]; then
      write_doc_item --path "$target" --source-url "$url" --source-id "$sid" --title "$title" \
        --priority normal --created-at "$RUN_TS" --project "$slug" --doc-id "$doc_id" \
        --updated-at "$updated" --author "$author" --labels-file "$TMPD/doclabels" \
        --label-source "$label_source" --matched "$matched" --body-file "$TMPD/body"
    fi

    printf '%s\n' "$target" >> "$WRITTEN"
    if [ "$slug" = "_unrouted" ]; then
      UNROUTED=$((UNROUTED+1))
    else
      ROUTED=$((ROUTED+1))
      [ "$DRY_RUN" -eq 0 ] && state_list_add "projects|${slug}|slite|seen_docs" "$doc_id"
    fi
    emit "$(printf 'draft\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$target" "doc-review" "$slug" "$sid" "$needs_route" "0" "$title")"
  done < <(slite_hits "$TMPD/search.json")
done < "$LABELS"

# --- Phase 3: resume sweep --------------------------------------------------------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -qxF "$f" "$WRITTEN"; then continue; fi
  RESUMED=$((RESUMED+1))
  emit "$(printf 'resume\t%s\t%s\t%s\t%s\t0\t0\t%s' \
    "$f" "$(fm "$f" type)" "$(fm "$f" project)" "$(fm "$f" source_id)" "$(fm "$f" title)")"
done < <(poll_resume_candidates)

if [ "$DRY_RUN" -eq 0 ]; then
  # Advance the cutoff for every project polled, even at zero docs: this source FILTERS on
  # last_checked, so a stale cutoff re-surfaces the same docs every cycle.
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then continue; fi
    [ "$(cfg "projects.${slug}.source.slite")" = "configured" ] || continue
    state_set "projects|${slug}|slite|last_checked" "$RUN_TS"
  done < <(cfgl project)
  state_save
fi

printf 'Found %d Slite doc(s). %d routed, %d unrouted, %d skipped (already handled), %d unchanged, %d resumed.\n' \
  "$FOUND" "$ROUTED" "$UNROUTED" "$SKIPPED" "$UNCHANGED" "$RESUMED"
if [ -n "$SKIPPED_IDS" ]; then
  printf 'Skipped (terminal): %s\n' "$SKIPPED_IDS"
fi
[ "$ERRORS" -eq 0 ] || exit 3
exit 0
