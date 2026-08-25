#!/bin/bash
# lib-ticket-kind.sh — the deterministic tiers of references/ticket-kind.md: does a ticket deliver
# a CODE CHANGE (type: ticket) or a FINDINGS DOCUMENT (type: ticket-investigation)?
#
# Implements Tier 0 (manual flag), Tier 1 (Jira issue type — TERMINAL for Jira), Tier 2 (GitHub
# label), Tier 3 Form A (delimited kind prefix) and Tier 4 (default: code work).
#
# Tier 3 Form B — "leading imperative verb" — is NOT implemented here, because deciding that
# `Investigate why checkout 500s` is an imperative while `Research service returns 500` is a bug in
# a service called Research is a grammatical judgment, and the spec says so ("when you cannot tell,
# it does not fire"). Instead this library detects the cheap PRECONDITION for Form B and reports
# needs_form_b=1 so the caller can put exactly those titles in front of a model. Everything else is
# settled here, for free.
#
# OUTPUT — one tab-separated line: <type>\t<method>\t<rationale>\t<needs_form_b>
#   type          ticket | ticket-investigation
#   method        manual | jira-issuetype | github-label | title-keyword | default
#   rationale     one line naming the evidence; REQUIRED when method is title-keyword
#   needs_form_b  1 when a model must adjudicate Form B before this answer is final
#
# INJECTION CONTAINMENT (preserved structurally, not by instruction): ticket text is only ever the
# LEFT side of a comparison — it never contributes a keyword — so the trigger vocabulary is closed
# under config. The output alphabet is two fixed strings. Neither property depends on the caller.

# _tk_lower <s>
_tk_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _tk_trim <s>
_tk_trim() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# _tk_in_list <needle> <list-on-stdin> — whole-string, case-insensitive membership.
# Whole-string and never substring: substring matching makes `spike-protection`,
# `no-research-needed` and `decision-log` all fire, and every one is a plausible real label.
_tk_in_list() {
  local needle; needle="$(_tk_lower "$(_tk_trim "$1")")"
  local item
  while IFS= read -r item || [ -n "$item" ]; do
    [ -n "$item" ] || continue
    [ "$(_tk_lower "$(_tk_trim "$item")")" = "$needle" ] && return 0
  done
  return 1
}

# _tk_normalize_label <label> — lowercase, trim, strip a leading type:/type//kind:/kind//category:
# prefix, then drop leading emoji or punctuation.
#
# The prefix strip exists because `type: spike` and `kind/spike` are the two dominant house styles,
# and a config matching only the bare form silently fails for both.
_tk_normalize_label() {
  local l; l="$(_tk_lower "$(_tk_trim "$1")")"
  l="$(printf '%s' "$l" | sed -E 's#^(type|kind|category)[:/][[:space:]]*##')"
  # Drop leading characters that are neither alphanumeric nor an intra-word - or _ . This removes
  # decorative emoji and punctuation without touching the token itself.
  l="$(printf '%s' "$l" | sed -E 's/^[^[:alnum:]]+//')"
  _tk_trim "$l"
}

# _tk_strip_project_prefix <title> <keywords-file> — remove AT MOST ONE leading bracketed segment
# whose contents are not themselves a keyword.
#
# That segment is the routing ladder's Tier 1 project prefix, and leaving it in place would hide the
# kind prefix behind it: `[payroll-workflows] Spike: cache invalidation` must still classify. The
# "not itself a keyword" guard is what keeps `[Spike] Add caching` matching on the bracket it was
# handed rather than being stripped down to `Add caching`.
_tk_strip_project_prefix() {
  local title="$1" kwfile="$2" open close inner rest
  title="$(_tk_trim "$title")"
  case "$title" in
    "["*) open="[" close="]" ;;
    "("*) open="(" close=")" ;;
    *) printf '%s' "$title"; return 0 ;;
  esac
  rest="${title#?}"
  case "$rest" in
    *"$close"*) inner="${rest%%"$close"*}" ;;
    *) printf '%s' "$title"; return 0 ;;
  esac
  if _tk_in_list "$inner" < "$kwfile"; then printf '%s' "$title"; return 0; fi
  rest="${rest#*"$close"}"
  _tk_trim "$rest"
}

# _tk_form_a <normalized-title> <keywords-file> — print the matched keyword, or nothing.
#
# ⚠ DIVERGENCE FROM THE REGEX AS WRITTEN IN references/ticket-kind.md, resolved toward that
# document's own worked examples. The regex reads:
#
#     ^ [ \[ ( ]?  <keyword>  [ \] ) ]?  \s*  ( : | — | – | - | \| | · | end-of-title )
#
# but the doc also lists `[Decision] queue backend` and `(spike) websocket limits` as titles that
# FIRE — and under the literal regex they do not, because what follows the closing bracket is
# `queue` / `websocket`, none of the listed delimiters and not end-of-title. The examples are the
# more concrete statement of intent, so the rule implemented here is:
#
#     a CLOSING BRACKET is itself a delimiter; otherwise an explicit delimiter or end-of-title is
#     required.
#
# Every example in the doc classifies correctly under that rule, in both directions (see
# tests/ticket-kind.test.sh, which pins the fires/does-not-fire lists verbatim).
#
# Deliberately no regex: the delimiter set includes em dash, en dash and middle dot, which are
# multibyte UTF-8. A `grep -E` over them is locale-dependent and silently stops matching under
# LC_ALL=C — which is exactly the environment a launchd/cron run gets. Prefix comparison is not.
_tk_form_a() {
  local title="$1" kwfile="$2" kw lower_title bracketed body rest first
  lower_title="$(_tk_lower "$title")"
  bracketed=0
  case "$lower_title" in
    "["*|"("*) bracketed=1; body="${lower_title#?}" ;;
    *) body="$lower_title" ;;
  esac
  while IFS= read -r kw || [ -n "$kw" ]; do
    kw="$(_tk_lower "$(_tk_trim "$kw")")"
    [ -n "$kw" ] || continue
    case "$body" in
      "$kw"*) ;;
      *) continue ;;
    esac
    rest="${body#"$kw"}"
    if [ "$bracketed" -eq 1 ]; then
      # A closing bracket closes the labelled segment and is itself the delimiter.
      case "$rest" in "]"*|")"*) printf '%s' "$kw"; return 0 ;; esac
      continue
    fi
    rest="$(_tk_trim "$rest")"
    [ -z "$rest" ] && { printf '%s' "$kw"; return 0; }   # bare "Spike"
    first="${rest%"${rest#?}"}"                          # first character, multibyte-safe
    case "$first" in
      ":"|"-"|"|"|"—"|"–"|"·") printf '%s' "$kw"; return 0 ;;
    esac
  done < "$kwfile"
  return 1
}

# Keywords that are NOUNS in the shipped vocabulary. references/ticket-kind.md: "Nouns in the list
# (spike, decision, adr, rfc) are Form A only." A noun leading a title is not an imperative, so it
# can never be a Form B candidate and must not be sent to a model to adjudicate.
#
# A keyword NOT on this list (a shipped verb, or any custom word a user added) IS treated as a
# possible Form B candidate — conservative on purpose: an unknown word gets a judgment call rather
# than a silent decision.
_TK_NOUN_ONLY="spike decision adr rfc"

# _tk_form_b_candidate <normalized-title> <keywords-file> — rc 0 when the first word could be a
# leading imperative. This is the PRECONDITION only; the verb-vs-noun disqualifier
# (`Research service returns 500` is a bug in a service called Research) is left to a model.
_tk_form_b_candidate() {
  local title="$1" kwfile="$2" first base n
  title="$(_tk_trim "$(_tk_lower "$title")")"
  title="${title#please }"                    # "optionally after a single 'please '"
  first="${title%%[ 	]*}"
  first="$(printf '%s' "$first" | sed -E 's/[^[:alnum:]]+$//')"
  [ -n "$first" ] || return 1
  for n in $_TK_NOUN_ONLY; do [ "$first" = "$n" ] && return 1; done
  _tk_in_list "$first" < "$kwfile" && return 0
  # Gerunds only — "no stemming beyond the gerund", so `comparison` is not `compare`.
  case "$first" in
    *ing)
      base="${first%ing}"
      for n in $_TK_NOUN_ONLY; do [ "$base" = "$n" ] && return 1; done
      _tk_in_list "$base" < "$kwfile" && return 0
      _tk_in_list "${base}e" < "$kwfile" && return 0   # comparing -> compare
      ;;
  esac
  return 1
}

# ticket_kind_classify — the ladder. Named arguments:
#   --tracker jira|github        (required)
#   --manual investigate|implement
#   --jira-issue-type <name>
#   --title <title>
#   --labels-file <file>         one GitHub label per line
#   --jira-types-file <file>     effective jira_types,     one per line
#   --github-labels-file <file>  effective github_labels,  one per line
#   --title-keywords-file <file> effective title_keywords, one per line
#
# Lists arrive as FILES holding already-resolved effective values (ea-config.sh applies the
# replace-not-merge rule). An empty file is a DISABLED tier, which is why absence and emptiness must
# already have been distinguished upstream.
ticket_kind_classify() {
  local tracker="" manual="" jtype="" title="" f_labels="" f_jtypes="" f_ghlabels="" f_kw=""
  local empty; empty="$(mktemp)"; trap 'rm -f "$empty"' RETURN
  while [ $# -gt 0 ]; do
    case "$1" in
      --tracker) tracker="$2"; shift 2 ;;
      --manual) manual="$2"; shift 2 ;;
      --jira-issue-type) jtype="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --labels-file) f_labels="$2"; shift 2 ;;
      --jira-types-file) f_jtypes="$2"; shift 2 ;;
      --github-labels-file) f_ghlabels="$2"; shift 2 ;;
      --title-keywords-file) f_kw="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -f "${f_labels:-}"   ] || f_labels="$empty"
  [ -f "${f_jtypes:-}"   ] || f_jtypes="$empty"
  [ -f "${f_ghlabels:-}" ] || f_ghlabels="$empty"
  [ -f "${f_kw:-}"       ] || f_kw="$empty"

  # --- Tier 0: manual flag. Never reachable when polling; add-ticket sets it. ---------------
  case "$manual" in
    investigate) printf 'ticket-investigation\tmanual\t--investigate flag\t0\n'; return 0 ;;
    implement)   printf 'ticket\tmanual\t--implement flag\t0\n'; return 0 ;;
  esac

  # --- Tier 1: Jira issue type. TERMINAL FOR JIRA. -----------------------------------------
  # A Jira issue ALWAYS has a type, so this tier always answers and Tiers 2-3 are unreachable.
  # That is what removes the false-positive problem: a Story titled "Add spike protection to the
  # rate limiter" is code work by structure, not by luck.
  if [ "$tracker" = "jira" ]; then
    if [ -n "$jtype" ] && _tk_in_list "$jtype" < "$f_jtypes"; then
      printf 'ticket-investigation\tjira-issuetype\tJira issue type %s\t0\n' "$jtype"
    else
      printf 'ticket\tdefault\t\t0\n'
    fi
    return 0
  fi

  # --- Tier 2: GitHub label --------------------------------------------------------------
  local raw norm
  while IFS= read -r raw || [ -n "$raw" ]; do
    [ -n "$raw" ] || continue
    norm="$(_tk_normalize_label "$raw")"
    [ -n "$norm" ] || continue
    if _tk_in_list "$norm" < "$f_ghlabels"; then
      printf 'ticket-investigation\tgithub-label\tlabel %s\t0\n' "$raw"
      return 0
    fi
  done < "$f_labels"

  # --- Tier 3: title keyword (the only tier that reads untrusted prose) --------------------
  local norm_title kw
  norm_title="$(_tk_strip_project_prefix "$title" "$f_kw")"
  if kw="$(_tk_form_a "$norm_title" "$f_kw")"; then
    printf "ticket-investigation\ttitle-keyword\ttitle prefix '%s' (Form A)\t0\n" "$kw"
    return 0
  fi
  if _tk_form_b_candidate "$norm_title" "$f_kw"; then
    # Precondition only. Default to code work — the spec's own tie-break — and flag for a model.
    printf 'ticket\tdefault\t\t1\n'
    return 0
  fi

  # --- Tier 4: default. Unlike the routing ladder the last tier is NOT a human: "nothing
  # matched" has a correct, non-surprising answer, and both outcomes are gated anyway.
  printf 'ticket\tdefault\t\t0\n'
}
