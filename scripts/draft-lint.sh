#!/bin/bash
# draft-lint.sh — flag mechanical AI-writing tells in the part of a queue item that gets posted.
#
# Usage: draft-lint.sh <queue-file>
# Output: one "rule<TAB>line<TAB>match" row per hit (line is within the postable text). Advisory:
# the approval gate shows the rows; nothing is rewritten or blocked.
# Exit: 0 clean, 1 hits, 2 usage / unreadable.
#
# Postable text by type (mirrors execute-item): slack-question -> "### Proposed Slack Message";
# pr-review -> "## Draft Response" above "### Dismissed"; anything else -> "## Draft Response".
# Fenced and inline code are skipped. Rules: see references/writing-style.md.
set -uo pipefail

f="${1:-}"
[ -n "$f" ] && [ -r "$f" ] || { echo "usage: draft-lint.sh <queue-file>" >&2; exit 2; }

type="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } /^type:/ { sub(/^type:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit }' "$f")"

LC_ALL=C awk -v type="$type" '
  function hit(rule, m) { printf "%s\t%d\t%s\n", rule, n, m; hits++ }
  # word(re): first whole-word match of re in lower-cased s, or "".
  function word(s, re,   r) {
    if (match(s, "(^|[^a-z])(" re ")([^a-z]|$)")) {
      r = substr(s, RSTART, RLENGTH); sub(/^[^a-z]/, "", r); sub(/[^a-z]$/, "", r); return r
    }
    return ""
  }
  BEGIN {
    start = (type == "slack-question") ? "### Proposed Slack Message" : "## Draft Response"
    ai = "delve|delves|delved|delving|crucial|crucially|pivotal|tapestry|testament|underscore|underscores|underscored|showcase|showcases|showcased|showcasing|foster|fosters|fostered|fostering|leverage|leverages|leveraged|leveraging|utilize|utilizes|utilized|utilizing|seamless|seamlessly|garner|garners|garnered|intricate|vibrant"
    nchat = split("great question|i hope this helps|hope this helps!|let me know if|happy to help|you\047re absolutely right|you are absolutely right|certainly!", chat, "|")
    nfill = split("in order to|due to the fact that|it is important to note|it\047s important to note|it\047s worth noting", fill, "|")
  }
  !on { if ($0 == start) on = 1; next }
  # End of the postable text.
  /^## / { exit }
  type == "slack-question" && /^### / { exit }
  type == "pr-review" && $0 == "### Dismissed" { exit }
  /^[[:space:]]*```/ { fence = !fence; n++; next }
  fence { n++; next }
  {
    n++
    s = $0; gsub(/`[^`]*`/, "", s)
    if (index(s, "\342\200\224")) hit("em-dash", "\342\200\224")
    if (s ~ /\342\200[\230\231\234\235]/) hit("curly-quote", "curly quote")
    l = tolower(s)
    if ((w = word(l, ai)) != "") hit("ai-word", w)
    for (i = 1; i <= nchat; i++) if (index(l, chat[i])) { hit("chatbot", chat[i]); break }
    for (i = 1; i <= nfill; i++) if (index(l, fill[i])) { hit("filler", fill[i]); break }
    if (l ~ /not (just|only|merely) [^.]*, (it\047s|it is|but)/) hit("not-just", "not just X, Y")
  }
  END { exit hits > 0 ? 1 : 0 }
' "$f"
