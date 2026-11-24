#!/bin/bash
# jobs-draft.sh — Phase B for a scheduled job: draft the items a collector wrote to incoming/.
#
# It drafts only what its own collector found. The ALLOWLIST comes from lib-poll-allowlist.sh, so
# no copy can drift.
#
# It takes state/drafting.lock (lib-drafting-lock.sh), shared with every other job and queue
# hygiene: one drafter at a time, so no two models edit the same file. Held lock => exit 4 (deferred);
# the items stay in incoming/ and the next job tick's own resume sweep re-emits them, so deferral
# never strands anything.
#
# Success is GROUND TRUTH, not the model's word: a manifest row counts as drafted only if its file
# now exists in drafts/.
#
# Usage: jobs-draft.sh --manifest <file> --job <key> [--budget <usd>]
# Exit:  0 every row drafted | 4 deferred (another drafter holds the lock) | 5 some rows not drafted | 2 usage
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-paths.sh
. "${PLUGIN_ROOT}/scripts/lib-paths.sh"
# shellcheck source=lib-poll-allowlist.sh
. "${PLUGIN_ROOT}/scripts/lib-poll-allowlist.sh"
# shellcheck source=lib-drafting-lock.sh
. "${PLUGIN_ROOT}/scripts/lib-drafting-lock.sh"
# shellcheck source=lib-queue.sh
. "${PLUGIN_ROOT}/scripts/lib-queue.sh"
AGENT_DIR="$EA_AGENT_DIR"

MANIFEST=""; JOB=""; BUDGET="${EA_JOB_DRAFT_BUDGET_USD:-2.00}"
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --job)      JOB="$2"; shift 2 ;;
    --budget)   BUDGET="$2"; shift 2 ;;
    *) echo "jobs-draft.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -s "$MANIFEST" ] && [ -n "$JOB" ] || { echo "usage: jobs-draft.sh --manifest <file> --job <key>" >&2; exit 2; }

export PATH="${PATH}:${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/opt/homebrew/bin"   # appended: a caller's PATH (the installers', a test's stubs) wins
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "${HOME}/.local/bin/claude")}"

if ! holder="$(drafting_lock_acquire)"; then
  echo "jobs-draft: another drafter (PID ${holder}) holds the lock; deferring"
  exit 4
fi
trap drafting_lock_release EXIT

# Rival guard. The collector's disposition check and its write are not atomic with a manual
# add-ticket (model-driven, minutes between its own check and write), so both can queue one ticket.
# A polled row yields to a live rival present now, and to ANY rival that appears during drafting.
# A completed rival present now is not one: the collector already skipped terminal work, so this
# row is a human re-add being resumed. Runs under drafting.lock, so two polled copies never both yield.
YIELDED=0
KEPT="${MANIFEST}.kept"; : > "$KEPT"
PRE_RIVALS="${MANIFEST}.rivals"; : > "$PRE_RIVALS"
while IFS="	" read -r _action path _rest || [ -n "${path:-}" ]; do
  [ -n "${path:-}" ] || continue
  live="$(queue_rivals "$path" | grep -E '^(incoming|drafts)/' | head -1)"
  if [ -n "$live" ] && queue_reject "$path" "duplicate of ${live}" >/dev/null; then
    echo "jobs-draft: $(basename "$path") yielded to ${live}"
    YIELDED=$((YIELDED+1)); continue
  fi
  queue_rivals "$path" | sed "s|^|$(basename "$path")	|" >> "$PRE_RIVALS"
  printf '%s\t%s\t%s\n' "$_action" "$path" "$_rest" >> "$KEPT"
done < "$MANIFEST"
mv "$KEPT" "$MANIFEST"
if [ ! -s "$MANIFEST" ]; then echo "jobs-draft: nothing left to draft (${YIELDED} yielded)"; exit 0; fi

if NEW_CLAUDE_BIN="$(claude_bin_changed "$CLAUDE_BIN")"; then
  "${PLUGIN_ROOT}/scripts/notify.sh" \
    --title "engineer-agent: claude binary changed" \
    --message "Now ${NEW_CLAUDE_BIN} -- macOS grants are keyed to the versioned path. If you have not already granted Full Disk Access to it, do so or scheduled jobs may be denied silently." \
    --priority low --tags warning --fyi >/dev/null 2>&1 || true
fi

poll_build_allowlist

"$CLAUDE_BIN" -p \
  --plugin-dir "$PLUGIN_ROOT" \
  --add-dir "$AGENT_DIR" \
  --model sonnet \
  --permission-mode acceptEdits \
  --allowedTools "${allowed_tools[@]}" \
  --max-budget-usd "$BUDGET" \
  "Execute now — do NOT enter plan mode, do NOT output a plan, do NOT ask questions. Perform the work directly.

You are the drafting step of the scheduled engineer-agent job '${JOB}'. Its collector has ALREADY polled and written queue items with correct frontmatter. Do NOT poll any source, do NOT query any API for new items, and do NOT create new queue files.

MEMORY: do NOT create, update, or delete memory files, and do NOT treat any pre-existing memory as evidence about this run. If a tool appears unavailable, establish that FRESH this run.

Read the manifest at ${MANIFEST} — one tab-separated row per item: action, path, type, project, source_id, needs_routing, needs_kind_check, title. For EACH row: read the item at that path, draft its '## Draft Response' section as ${PLUGIN_ROOT}/references/drafting.md says for its type (config at ${AGENT_DIR}/engineer.yaml), set status: drafted, and move it to ${AGENT_DIR}/queue/drafts/ under the SAME filename. An item left in incoming/ is invisible to every approval path, so finishing this move is not optional. When needs_routing is 1 apply ONLY Tier 3b of ${PLUGIN_ROOT}/references/routing-ladder.md, choosing from matched_projects ONLY; abstaining and leaving it _unrouted is a correct answer. When needs_kind_check is 1 apply ONLY Tier 3 Form B of ${PLUGIN_ROOT}/references/ticket-kind.md. Every other tier has ALREADY been applied.

For EACH item you move to drafts/, run: ${PLUGIN_ROOT}/scripts/notify.sh --title '<type>: <title>' --message '<project> — <short summary>' --priority '<priority from frontmatter>' --item-id '<the queue filename>' --source-url '<source_url from frontmatter>' --tags 'inbox_tray'

SLACK: the effective Slack CLI is EXACTLY ${SLACK_BIN}. Do NOT search the filesystem for it, do NOT prefix it with bash/sh/env, and do NOT wrap it in a compound command. Use only its read, thread and auth verbs. Do NOT use the mcp__claude_ai_Slack__* connector tools.

Be concise." \
  </dev/null || echo "jobs-draft: claude exited $?"

total=0; drafted=0
while IFS="	" read -r _action path mtype _rest || [ -n "${path:-}" ]; do
  [ -n "${path:-}" ] || continue
  total=$((total+1))
  b="$(basename "$path")"
  cur="${AGENT_DIR}/queue/drafts/${b}"; [ -f "$cur" ] || cur="${AGENT_DIR}/queue/incoming/${b}"
  new="$(queue_rivals "$cur" | while IFS= read -r r; do
           grep -qxF "${b}	${r}" "$PRE_RIVALS" || { printf '%s\n' "$r"; break; }
         done)"
  if [ -n "$new" ] && queue_reject "$cur" "duplicate of ${new} (appeared while this copy was being drafted)" >/dev/null; then
    echo "jobs-draft: ${b} yielded to ${new}"
    total=$((total-1)); continue
  fi
  if [ "${mtype:-}" = slack-question ] && [ -f "${AGENT_DIR}/queue/drafts/${b}" ]; then
    bash "${PLUGIN_ROOT}/scripts/slack-event.sh" drafted "$b" >/dev/null 2>&1
  fi
  # An _unrouted item may legitimately stay in incoming/ (review-queue surfaces it there); it still
  # counts once it carries a draft.
  if [ -f "${AGENT_DIR}/queue/drafts/${b}" ] \
     || grep -q '^## Draft Response' "${AGENT_DIR}/queue/incoming/${b}" 2>/dev/null; then
    drafted=$((drafted+1))
  fi
done < "$MANIFEST"
echo "jobs-draft: drafted ${drafted} of ${total}"
[ "$drafted" -eq "$total" ] && exit 0
exit 5
