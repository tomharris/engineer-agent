#!/bin/bash
# lib-decision-log.sh — append-only TSV of decisions an unattended run made, written by bash.
#
#   dlog_row <tsv> <phase> <decision> <why> <evidence> <result>
#   dlog_attach <tsv> <queue-file>   # (re)writes a trailing "## Decision Log" table into the item
#
# Rows carry bash-derived facts (shas, counts, exit codes, check names). Callers pass any text that
# came from outside bash through _neutral (lib-review.sh) first: model runs (codify) read the item.
# Portable bash 3.2 / BSD awk.

DLOG_HEADER="ts	phase	decision	why	evidence	result"

# _dlog_cell — one line, no tabs; a leading = + - @ is quoted so a spreadsheet won't run it.
_dlog_cell() {
  local c
  c="$(printf '%s' "$1" | tr '\t\r\n' '   ')"
  case "$c" in [=+@-]*) c="'${c}" ;; esac
  printf '%s' "$c"
}

dlog_row() {
  local f="$1" ts row
  [ -n "$f" ] || return 0
  mkdir -p "$(dirname "$f")" || return 0
  [ -s "$f" ] || printf '%s\n' "$DLOG_HEADER" > "$f"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  row="${ts}	$(_dlog_cell "$2")	$(_dlog_cell "$3")	$(_dlog_cell "$4")	$(_dlog_cell "$5")	$(_dlog_cell "$6")"
  printf '%s\n' "$row" >> "$f"
}

# dlog_attach — replaces everything from an existing "## Decision Log" heading to EOF, so reruns
# (a resumed pipeline) rewrite the section instead of stacking copies. No-op without both files.
dlog_attach() {
  local tsv="$1" item="$2" tmp
  [ -s "$tsv" ] && [ -f "$item" ] || return 0
  tmp="${item}.dlog.$$"
  {
    awk '$0 == "## Decision Log" { exit } { print }' "$item" | awk '
      { lines[NR] = $0 } END { n = NR; while (n > 0 && lines[n] == "") n--; for (i = 1; i <= n; i++) print lines[i] }'
    printf '\n## Decision Log\n\n'
    printf '_Written by bash from run receipts; append-only (a later row supersedes an earlier one)._\n\n'
    awk -F'\t' '
      function esc(s) { gsub(/\|/, "\\|", s); return s }
      NR == 1 { print "| ts | phase | decision | why | evidence | result |"; print "|---|---|---|---|---|---|"; next }
      { printf "| %s | %s | %s | %s | %s | %s |\n", esc($1), esc($2), esc($3), esc($4), esc($5), esc($6) }' "$tsv"
  } > "$tmp" && mv "$tmp" "$item" || rm -f "$tmp"
}
