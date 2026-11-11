#!/bin/bash
# lib-review.sh — review helpers shared by pr-pipeline.sh, job-jira-implement-next.sh and the
# cr-qa job. Pure functions: jq/sed/tr only, no config or network.

# _neutral — model text made inert for Markdown and Jira wiki: no link/markup brackets, no
# scheme://… or www.… address. Applied to every line of model text that leaves this machine.
_neutral() {
  tr -d '[]()<>`|' | sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*#[link removed]#g; s#[Ww][Ww][Ww]\.[^[:space:]]*#[link removed]#g'
}

# security_introduced <findings.json> <changed-files> — the findings this PR introduced, as a JSON
# array. Fails closed: any finding on a changed file (minus ./, :line, #Lnn; an absolute or a/-style
# path counts when it ends with /<changed file>) counts whatever the
# adapter says, since its output is model text that read the diff; `introduced: true` adds
# findings outside the diff.
security_introduced() {
  jq --rawfile ch "$2" '($ch | split("\n") | map(select(. != ""))) as $changed
    | [.[] | select(
        (.introduced == true)
        or (((.file // "") | sub("^\\./"; "") | sub("#L?[0-9].*$"; "") | sub(":[0-9].*$"; "")) as $f
            | $changed | any(. as $c | $f == $c or ($f | endswith("/" + $c)))))]' "$1"
}

# severity_rank <severity> — 4 critical, 3 high, 2 medium, 1 low; anything else 3 (fail closed).
severity_rank() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    critical) echo 4 ;; high) echo 3 ;; medium) echo 2 ;; low) echo 1 ;; *) echo 3 ;;
  esac
}

# jira_untrusted_reason <issue.json> <trusted-ids, newline-separated> — empty when the ticket's
# creator and the author of every changelog edit to summary/description/labels/components are
# trusted. Account ids only: a display name is attacker-chosen text.
jira_untrusted_reason() {
  [ -n "$2" ] || { echo "no trusted_authors configured"; return; }
  jq -r --arg t "$2" '
    ($t | split("\n") | map(select(. != ""))) as $ok
    | (.fields.creator.accountId // "") as $c
    | if ($ok | index($c)) == null then "created by \($c), not a trusted author"
      elif (.changelog.total // 0) > (.changelog.histories // [] | length) then "changelog truncated; cannot verify edits"
      else ([.changelog.histories[]?
              | select(any(.items[]?; (.fieldId // .field) | IN("summary", "description", "labels", "components")))
              | (.author.accountId // "") as $a | select(($ok | index($a)) == null) | $a] | first)
           | if . == null then empty else "edited by \(.), not a trusted author" end
      end' "$1"
}
