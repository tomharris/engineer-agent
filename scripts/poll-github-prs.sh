#!/bin/bash
# poll-github-prs.sh — deterministic collector for GitHub pull requests needing review.
#
# Replaces the mechanical half of skills/poll-github/SKILL.md: fetch, reviewer/label/size filters,
# reconciliation, routing, queue-file writing, and state. It does NOT review — the item lands in
# queue/incoming/ and the manifest names it for the drafting phase.
#
# THE BIG DIFFERENCE FROM THE SKILL: poll-github step 3c has the poll run `gh pr view` and
# `gh pr diff` and generate a full structured review INLINE, for every PR, on every poll. That is
# the single most expensive thing the poll does, and it is pure waste on a poll that finds a PR
# already sitting in drafts/. Here the diff is never fetched during collection; it is read once, by
# the drafting phase, only for PRs that actually need a new review.
#
# Like poll-github-issues.sh this uses `gh --jq` (gh's embedded jq engine) and adds no dependency.
#
# NOTE ON ROUTING: PR review is NOT gated on `tracker`. A project can review PRs in a repo while
# tracking its work in Jira, so the candidate predicate is the github section alone
# (route_candidates_github_prs), not the github-issues one.
#
# Usage: poll-github-prs.sh [--project <slug>] [--run-ts <iso>] [--dry-run] [--manifest <file>]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib-paths.sh"
. "${SCRIPT_DIR}/lib-yaml.sh"
. "${SCRIPT_DIR}/lib-time.sh"
. "${SCRIPT_DIR}/lib-queue.sh"
. "${SCRIPT_DIR}/lib-queue-write.sh"
. "${SCRIPT_DIR}/lib-routing.sh"
. "${SCRIPT_DIR}/lib-state.sh"

TAB="$(printf '\t')"

ONLY_PROJECT=""; RUN_TS=""; DRY_RUN=0; MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)  ONLY_PROJECT="$2"; shift 2 ;;
    --run-ts)   RUN_TS="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "poll-github-prs.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_TS" ] || RUN_TS="$(iso_now)"
TS_PREFIX="$(queue_ts)"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
WRITTEN="$TMPD/written"; : > "$WRITTEN"
log()  { printf '%s\n' "$*" >&2; }
emit() { [ -n "$MANIFEST" ] && printf '%s\n' "$*" >> "$MANIFEST"; return 0; }
b64d() { base64 -d 2>/dev/null || base64 -D 2>/dev/null; }

command -v gh >/dev/null 2>&1 || { log "poll-github-prs: gh not found; skipping"; exit 3; }

EA_CFG="$("${SCRIPT_DIR}/ea-config.sh" dump)"; export EA_CFG
cfg()  { printf '%s\n' "$EA_CFG" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }
cfgl() { printf '%s\n' "$EA_CFG" | awk -v p="$1[]=" 'index($0,p)==1 {print substr($0,length(p)+1)}'; }

MAX_FILES="$(cfg agent.max_pr_files)"; MAX_FILES="${MAX_FILES:-50}"

# --- Phase 1: per-REPO map ---------------------------------------------------------------------
# Same per-repo keying as poll-github-issues.sh, for the same reason: a repo watched by several
# projects must be fetched once and routed per PR, never handed to whichever project came first.
REPOS="$TMPD/repos"; : > "$REPOS"
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then continue; fi
  [ "$(cfg "projects.${slug}.source.github")" = "configured" ] || continue
  owner="$(cfg "projects.${slug}.github.owner")"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    printf '%s\t%s\n' "${owner}/${repo}" "$slug" >> "$REPOS"
  done < <(cfgl "projects.${slug}.github.repos")
done < <(cfgl project)

if [ ! -s "$REPOS" ]; then
  log "poll-github-prs: no project has github PR review configured; nothing to do"
  exit 0
fi

state_load
FOUND=0; ROUTED=0; UNROUTED=0; SKIPPED=0; UNCHANGED=0; TOOBIG=0; RESUMED=0
SKIPPED_IDS=""

while IFS= read -r full; do
  [ -n "$full" ] || continue
  owner="${full%%/*}"; repo="${full#*/}"

  PRS="$TMPD/prs"; : > "$PRS"
  if ! gh pr list --repo "$full" --state open --limit 100 \
       --json number,title,author,url,labels,headRefName,baseRefName,changedFiles,reviewRequests,body \
       --jq '.[] | [ (.number|tostring), (.title|@base64), (.author.login // ""), .url, ((.labels|map(.name))|join("\u0001")), .headRefName, .baseRefName, ((.changedFiles // 0)|tostring), ((.reviewRequests|map(.login // .name // ""))|join("\u0001")), ((.body // "")|@base64) ] | @tsv' \
       > "$PRS" 2>"$TMPD/err"; then
    # Leave the cutoff untouched so the next run retries this window rather than skipping it.
    log "poll-github-prs: ERROR querying ${full}: $(head -1 "$TMPD/err"); leaving cutoff unchanged"
    continue
  fi

  while IFS="$TAB" read -r num title_b64 author url labels_raw head base changed reviewers_raw body_b64; do
    [ -n "$num" ] || continue
    title="$(printf '%s' "$title_b64" | b64d)"
    printf '%s\n' "$body_b64" | b64d > "$TMPD/body"
    printf '%s\n' "$labels_raw"    | tr '\001' '\n' | sed -E '/^[[:space:]]*$/d' > "$TMPD/labels"
    printf '%s\n' "$reviewers_raw" | tr '\001' '\n' | sed -E '/^[[:space:]]*$/d' > "$TMPD/reviewers"
    sid="${full}#${num}"

    # --- routing first: the reviewer/label filters are PER PROJECT, so which project's filters
    # apply cannot be known until the PR is routed.
    cands="$(route_candidates_github_prs "$owner" "$repo" | tr '\n' ' ' | sed 's/ $//')"
    route_out="$(route_ticket --candidates "$cands" --title "$title" \
                   --body "$(cat "$TMPD/body")" --labels-file "$TMPD/labels")"
    slug="$(printf '%s' "$route_out" | cut -f1)"
    rmethod="$(printf '%s' "$route_out" | cut -f2)"
    needs_route="$(printf '%s' "$route_out" | cut -f4)"
    matched="$(printf '%s' "$route_out" | cut -f5)"

    if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then
      if [ "$slug" != "_unrouted" ]; then continue; fi
      case " $matched " in *" $ONLY_PROJECT "*) ;; *) continue ;; esac
    fi

    # --- reviewer filter: a review must actually have been requested from the configured user.
    # For an _unrouted PR, accept if ANY candidate's configured reviewer matches — otherwise a
    # shared repo would silently drop PRs simply because routing was ambiguous.
    if [ "$slug" = "_unrouted" ]; then check_projects="$matched"; else check_projects="$slug"; fi
    want_ok=0
    for c in $check_projects; do
      who="$(cfg "projects.${c}.github.review_requested_for")"
      [ -n "$who" ] || continue
      if grep -qix -- "$who" "$TMPD/reviewers"; then want_ok=1; break; fi
    done
    [ "$want_ok" -eq 1 ] || continue

    FOUND=$((FOUND+1))

    # --- ignore_labels ------------------------------------------------------------------
    ignore_hit=0
    ref="$slug"; [ "$slug" = "_unrouted" ] && ref="$(printf '%s' "$matched" | awk '{print $1}')"
    while IFS= read -r ig || [ -n "$ig" ]; do
      [ -n "$ig" ] || continue
      if grep -qix -- "$ig" "$TMPD/labels"; then ignore_hit=1; break; fi
    done < <(cfgl "projects.${ref}.github.ignore_labels")
    [ "$ignore_hit" -eq 1 ] && continue

    # --- size guard (agent.max_pr_files) ------------------------------------------------
    # A PR far past the cap is not reviewable in one pass; the skill logs a warning and skips.
    if [ "$changed" -gt "$MAX_FILES" ] 2>/dev/null; then
      TOOBIG=$((TOOBIG+1))
      log "poll-github-prs: skipping ${sid} — ${changed} files changed exceeds agent.max_pr_files (${MAX_FILES})"
      continue
    fi

    # --- reconciliation -----------------------------------------------------------------
    disp="$(queue_disposition pr-review "$sid")"
    target=""
    case "$disp" in
      skip)
        SKIPPED=$((SKIPPED+1)); SKIPPED_IDS="${SKIPPED_IDS}${SKIPPED_IDS:+, }${sid}"
        if [ "$slug" != "_unrouted" ] && [ "$DRY_RUN" -eq 0 ]; then
          state_list_add "projects|${slug}|github|seen_prs" "$sid"
        fi
        continue ;;
      unchanged:*)
        UNCHANGED=$((UNCHANGED+1))
        if [ "$slug" != "_unrouted" ] && [ "$DRY_RUN" -eq 0 ]; then
          state_list_add "projects|${slug}|github|seen_prs" "$sid"
        fi
        continue ;;
      update:*)
        target="${disp#update:}" ;;
      create)
        target="${EA_AGENT_DIR}/queue/incoming/$(queue_filename pr-review "${repo}-${num}" "$TS_PREFIX")" ;;
    esac

    if [ "$DRY_RUN" -eq 0 ]; then
      write_pr_item --path "$target" --source-url "$url" --source-id "$sid" --title "$title" \
        --priority normal --created-at "$RUN_TS" --project "$slug" --pr-author "$author" \
        --repo "$full" --pr-number "$num" --head "$head" --base "$base" \
        --changed-files "$changed" --labels-file "$TMPD/labels" --body-file "$TMPD/body"
      printf '%s\n' "$target" >> "$WRITTEN"
    fi

    if [ "$slug" = "_unrouted" ]; then
      UNROUTED=$((UNROUTED+1))
    else
      ROUTED=$((ROUTED+1))
      [ "$DRY_RUN" -eq 0 ] && state_list_add "projects|${slug}|github|seen_prs" "$sid"
    fi
    emit "$(printf 'draft\t%s\tpr-review\t%s\t%s\t%s\t0\t%s' \
      "$target" "$slug" "$sid" "$needs_route" "$title")"
  done < "$PRS"
done < <(cut -f1 "$REPOS" | sort -u)

# Resume sweep — see lib-queue.sh poll_resume_candidates(). Only pr-review items are re-emitted
# here so the two GitHub collectors do not each claim the other's stranded work.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -qxF "$f" "$WRITTEN"; then continue; fi
  [ "$(fm "$f" type)" = "pr-review" ] || continue
  RESUMED=$((RESUMED+1))
  emit "$(printf 'resume\t%s\tpr-review\t%s\t%s\t0\t0\t%s' \
    "$f" "$(fm "$f" project)" "$(fm "$f" source_id)" "$(fm "$f" title)")"
done < <(poll_resume_candidates)

if [ "$DRY_RUN" -eq 0 ]; then
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if [ -n "$ONLY_PROJECT" ] && [ "$slug" != "$ONLY_PROJECT" ]; then continue; fi
    [ "$(cfg "projects.${slug}.source.github")" = "configured" ] || continue
    state_set "projects|${slug}|github|last_checked" "$RUN_TS"
  done < <(cfgl project)
  state_save
fi

printf 'Found %d PR(s) awaiting review. %d routed, %d unrouted, %d skipped (already handled), %d unchanged, %d too large, %d resumed.\n' \
  "$FOUND" "$ROUTED" "$UNROUTED" "$SKIPPED" "$UNCHANGED" "$TOOBIG" "$RESUMED"
if [ -n "$SKIPPED_IDS" ]; then
  printf 'Skipped (terminal): %s\n' "$SKIPPED_IDS"
fi
exit 0
