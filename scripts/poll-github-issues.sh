#!/bin/bash
# poll-github-issues.sh — deterministic collector for GitHub Issues.
#
# Replaces the mechanical half of skills/poll-github-issues/SKILL.md: fetch, recency filter,
# reconciliation, routing (tiers 0-3a), kind classification (tiers 0-2 and 3-Form-A), queue-file
# writing, and state. It does NOT draft — it writes items to queue/incoming/ and emits a manifest
# naming what still needs a model, which is the only thing a model is then asked to do.
#
# NO EXTERNAL jq. Field extraction uses `gh --jq`, gh's own embedded jq engine, so this adds no
# dependency beyond `gh` itself and stays inside the "the cron path is jq-free" policy that
# cron-poll.sh sets. Titles and bodies are carried as base64 through the TSV because both routinely
# contain tabs, newlines and quotes.
#
# TWO TRAPS FROM THE SKILL, PRESERVED — each broke a real behavior:
#   1. `gh issue list --label a --label b` is AND, not OR, so several watchers' label filters
#      CANNOT be unioned into one query. The repo is fetched unfiltered and github.issues.labels is
#      applied later as a ROUTING predicate (routing ladder Tier 2).
#   2. Collection is deduplicated PER REPO, not per project. When it ran per project, the global
#      source_id dedup handed a shared repo's issue to whichever project the loop reached first —
#      an arbitrary misroute that looked like a confident decision, with no _unrouted escape.
#
# Usage: poll-github-issues.sh [--project <slug>] [--run-ts <iso>] [--dry-run] [--manifest <file>]
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

TAB="$(printf '\t')"

ONLY_PROJECT=""; RUN_TS=""; DRY_RUN=0; MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)  ONLY_PROJECT="$2"; shift 2 ;;
    --run-ts)   RUN_TS="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help)  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "poll-github-issues.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_TS" ] || RUN_TS="$(iso_now)"
TS_PREFIX="$(queue_ts)"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
# Paths written by THIS run, so the resume sweep below does not re-report them as stranded.
WRITTEN="$TMPD/written"; : > "$WRITTEN"
log()  { printf '%s\n' "$*" >&2; }
emit() { [ -n "$MANIFEST" ] && printf '%s\n' "$*" >> "$MANIFEST"; return 0; }

# b64d — portable base64 decode. macOS shipped `-D` before it accepted `-d`.
b64d() { base64 -d 2>/dev/null || base64 -D 2>/dev/null; }

command -v gh >/dev/null 2>&1 || { log "poll-github-issues: gh not found; skipping"; exit 3; }

EA_CFG="$("${SCRIPT_DIR}/ea-config.sh" dump)"; export EA_CFG
cfg()  { printf '%s\n' "$EA_CFG" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }
cfgl() { printf '%s\n' "$EA_CFG" | awk -v p="$1[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}'; }

MAX_AGE="$(cfg agent.max_issue_age_days)"; MAX_AGE="${MAX_AGE:-0}"

# --- Phase 1: build the per-REPO query map ----------------------------------------------------
# "owner/repo" -> the distinct assignees to query, and the projects watching it. Keyed by repo
# rather than by project (trap 2 above): a shared repo must be fetched once and routed per issue.
REPOS="$TMPD/repos"; : > "$REPOS"
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then continue; fi
  [ "$(cfg "projects.${slug}.source.github_issues")" = "configured" ] || continue
  owner="$(cfg "projects.${slug}.github.owner")"
  assignee="$(cfg "projects.${slug}.github.issues.assignee")"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    printf '%s\t%s\t%s\n' "${owner}/${repo}" "$assignee" "$slug" >> "$REPOS"
  done < <(cfgl "projects.${slug}.github.repos")
done < <(cfgl project)

if [ ! -s "$REPOS" ]; then
  log "poll-github-issues: no project has github_issues configured; nothing to do"
  exit 0
fi

state_load

FOUND=0; ROUTED=0; UNROUTED=0; SKIPPED=0; UNCHANGED=0; CREATED=0; RESUMED=0
SKIPPED_IDS=""

# --- Phase 2: one pass per distinct repo ------------------------------------------------------
while IFS= read -r full; do
  [ -n "$full" ] || continue
  owner="${full%%/*}"; repo="${full#*/}"
  assignees="$(awk -F'\t' -v r="$full" '$1==r {print $2}' "$REPOS" | sort -u)"

  ISSUES="$TMPD/issues"; : > "$ISSUES"
  ok_any=0
  while IFS= read -r who; do
    [ -n "$who" ] || continue
    # Deliberately NO --label filter (trap 1). One query per distinct assignee, merged below.
    if gh issue list --repo "$full" --assignee "$who" --state open --limit 100 \
         --json number,title,body,labels,url,updatedAt \
         --jq '.[] | [ (.number|tostring), .updatedAt, (.title|@base64), ((.body // "")|@base64), ((.labels|map(.name))|join("\u0001")), .url ] | @tsv' \
         >> "$ISSUES" 2>"$TMPD/err"; then
      ok_any=1
    else
      log "poll-github-issues: ERROR querying ${full} for ${who}: $(head -1 "$TMPD/err")"
    fi
  done <<EOF
$assignees
EOF
  if [ "$ok_any" -ne 1 ]; then
    # Leave this repo's cutoff untouched so the next run retries the same window. Advancing it
    # after a failed query would silently drop every issue in that window, forever.
    log "poll-github-issues: all queries failed for ${full}; leaving cutoff unchanged"
    continue
  fi

  # Merge by issue number across assignees (dedup is PER REPO).
  sort -u -t"$TAB" -k1,1n "$ISSUES" -o "$ISSUES"

  while IFS="$TAB" read -r num updated title_b64 body_b64 labels_raw url; do
    [ -n "$num" ] || continue
    FOUND=$((FOUND+1))
    title="$(printf '%s' "$title_b64" | b64d)"
    printf '%s' "$body_b64" | b64d > "$TMPD/body"
    # NOTE the trailing newline: a file whose last line is unterminated makes `read` return
    # non-zero, so a `while read` loop silently drops that line. See lib-queue-write.sh.
    printf '%s\n' "$labels_raw" | tr '\001' '\n' | sed -E '/^[[:space:]]*$/d' > "$TMPD/labels"
    sid="${full}#${num}"

    # --- recency guard (agent.max_issue_age_days) ---------------------------------------
    # Keeps a multi-year assigned backlog in a shared tracker from flooding the queue on a
    # first poll. iso_older_than fails toward DOING the work on an unparseable timestamp.
    if [ "$MAX_AGE" -gt 0 ] 2>/dev/null && iso_older_than "$updated" "$MAX_AGE"; then
      continue
    fi

    # --- routing (tiers 0-3a) ------------------------------------------------------------
    # The candidate set is ALWAYS the full watcher list, even under --project. Narrowing it here
    # would let a genuinely ambiguous issue record routing_method: single-candidate, which is a
    # false audit trail — a full poll would have called the same issue _unrouted. Filter the
    # RESULT below instead, so the recorded decision is the one the ladder actually made.
    cands="$(route_candidates_github "$owner" "$repo" | tr '\n' ' ' | sed 's/ $//')"
    route_out="$(route_ticket --candidates "$cands" --title "$title" \
                   --body "$(cat "$TMPD/body")" --labels-file "$TMPD/labels")"
    slug="$(printf '%s' "$route_out" | cut -f1)"
    rmethod="$(printf '%s' "$route_out" | cut -f2)"
    rrat="$(printf '%s' "$route_out" | cut -f3)"
    needs_route="$(printf '%s' "$route_out" | cut -f4)"
    matched="$(printf '%s' "$route_out" | cut -f5)"

    # Under --project, keep only issues that actually belong to it. An _unrouted issue is kept
    # when the requested project is one of the candidates: it still needs a human or a model.
    if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then
      if [ "$slug" != "_unrouted" ]; then continue; fi
      case " $matched " in *" $ONLY_PROJECT "*) ;; *) continue ;; esac
    fi

    # --- kind (tiers 0-2, 3-Form-A) -------------------------------------------------------
    # Only meaningful once a slug exists: the kind lists are per-project overridable, so an
    # _unrouted item is deliberately classified LATE (references/ticket-kind.md).
    typ="ticket"; kmethod=""; krat=""; needs_kind=0
    if [ "$slug" != "_unrouted" ]; then
      cfgl "projects.${slug}.investigation.github_labels"  > "$TMPD/k_gl"
      cfgl "projects.${slug}.investigation.title_keywords" > "$TMPD/k_kw"
      kind_out="$(ticket_kind_classify --tracker github --title "$title" \
                    --labels-file "$TMPD/labels" --github-labels-file "$TMPD/k_gl" \
                    --title-keywords-file "$TMPD/k_kw")"
      typ="$(printf '%s' "$kind_out" | cut -f1)"
      kmethod="$(printf '%s' "$kind_out" | cut -f2)"
      krat="$(printf '%s' "$kind_out" | cut -f3)"
      needs_kind="$(printf '%s' "$kind_out" | cut -f4)"
    fi

    # --- reconciliation ------------------------------------------------------------------
    # Family-wide and terminal-inclusive. Terminal state is ABSORBING: engineer-agent's own
    # comment bumps updatedAt, so "re-queue anything updated since last_checked" was a
    # self-sustaining loop. Never re-queue finished work.
    disp="$(queue_disposition "$typ" "$sid")"
    target=""
    case "$disp" in
      skip)
        SKIPPED=$((SKIPPED+1)); SKIPPED_IDS="${SKIPPED_IDS}${SKIPPED_IDS:+, }${sid}"
        if [ "$slug" != "_unrouted" ] && [ "$DRY_RUN" -eq 0 ]; then
          state_list_add "projects|${slug}|github_issues|seen_issues" "$sid"
        fi
        continue ;;
      unchanged:*)
        UNCHANGED=$((UNCHANGED+1))
        if [ "$slug" != "_unrouted" ] && [ "$DRY_RUN" -eq 0 ]; then
          state_list_add "projects|${slug}|github_issues|seen_issues" "$sid"
        fi
        continue ;;
      update:*)
        # Keep the ORIGINAL {YYYYMMDD-HHmmss} prefix so created_at ordering survives, but correct
        # the {type} segment if the kind changed while the item sat unrouted.
        target="${disp#update:}"
        old_base="$(basename "$target")"
        old_prefix="$(printf '%s' "$old_base" | cut -d- -f1-2)"
        new_base="$(queue_filename "$typ" "gh-${num}" "$old_prefix")"
        if [ "$old_base" != "$new_base" ]; then
          rm -f "$target"
          target="$(dirname "$target")/$new_base"
        fi ;;
      create)
        target="${EA_AGENT_DIR}/queue/incoming/$(queue_filename "$typ" "gh-${num}" "$TS_PREFIX")" ;;
    esac

    # --- priority mapping (poll-github-issues 5d) ----------------------------------------
    prio="normal"
    if grep -qiE '^(priority:[[:space:]]*high|urgent)$' "$TMPD/labels"; then prio="urgent"; fi
    if grep -qiE '^priority:[[:space:]]*low$' "$TMPD/labels"; then prio="low"; fi

    if [ "$DRY_RUN" -eq 0 ]; then
      write_ticket_item --path "$target" --type "$typ" --source-url "$url" --source-id "$sid" \
        --title "$title" --priority "$prio" --created-at "$RUN_TS" --project "$slug" \
        --ticket-key "#${num}" --labels-file "$TMPD/labels" --matched "$matched" \
        --routing-method "$rmethod" --routing-rationale "$rrat" \
        --kind-method "$kmethod" --kind-rationale "$krat" --body-file "$TMPD/body"
    fi

    CREATED=$((CREATED+1))
    printf '%s\n' "$target" >> "$WRITTEN"
    if [ "$slug" = "_unrouted" ]; then
      UNROUTED=$((UNROUTED+1))
      # Unrouted items are deliberately NOT recorded in seen_issues: they must be re-checked on
      # every poll until a human or a model assigns them.
    else
      ROUTED=$((ROUTED+1))
      if [ "$DRY_RUN" -eq 0 ]; then
        state_list_add "projects|${slug}|github_issues|seen_issues" "$sid"
      fi
    fi
    emit "$(printf 'draft\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$target" "$typ" "$slug" "$sid" "$needs_route" "$needs_kind" "$title")"
  done < "$ISSUES"

  # Advance the per-repo cutoff even when the repo produced zero items: a source that found
  # nothing was still polled successfully. (Slack's message-timestamp cutoff is the documented
  # exception to this rule; a wall-clock source like this one is not.)
  if [ "$DRY_RUN" -eq 0 ]; then
    state_set "github_repos|${full}|last_checked" "$RUN_TS"
  fi
done < <(cut -f1 "$REPOS" | sort -u)

# --- Phase 3: resume sweep --------------------------------------------------------------------
# Anything already in incoming/ without a "## Draft Response" is STRANDED — invisible to both
# approval paths, because only drafts/ is reachable by the gate, and the reconciliation table says
# a resolved incoming/ item is "leave alone". Re-emitting it makes a failed drafting phase
# self-heal on the next tick instead of parking real work forever, silently.
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
    [ "$(cfg "projects.${slug}.source.github_issues")" = "configured" ] || continue
    state_set "projects|${slug}|github_issues|last_checked" "$RUN_TS"
  done < <(cfgl project)
  state_save
fi

# The reporting contract from references/queue-reconciliation.md: a poll that says "0 new items"
# when it skipped six already-handled tickets is indistinguishable from a broken poll.
printf 'Found %d issue(s). %d routed, %d unrouted, %d skipped (already handled), %d unchanged, %d resumed.\n' \
  "$FOUND" "$ROUTED" "$UNROUTED" "$SKIPPED" "$UNCHANGED" "$RESUMED"
if [ -n "$SKIPPED_IDS" ]; then
  printf 'Skipped (terminal): %s\n' "$SKIPPED_IDS"
fi
exit 0
