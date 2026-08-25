#!/bin/bash
# lib-yaml.sh — generic, dependency-free YAML reader for engineer-agent's config.
#
# WHY THIS EXISTS: lib-paths.sh grew six near-identical indent-aware awk readers
# (yaml_project_scalar, yaml_project_subscalar, yaml_agent_slack, yaml_agent_notify,
# yaml_agent_slack_mcp, yaml_project_list), each hardcoding one path at one depth and each
# carrying its own copy-pasted yaml_scalar(). Adding a source-collector that needs
# projects.<slug>.github.issues.assignee (four levels deep) would have meant a seventh.
# This reads the document ONCE into a flat, greppable form instead.
#
# DELIBERATELY NOT jq/yq/PyYAML. yq is not installed and is not a dependency anywhere in this
# repo; jq is a soft dependency that only the separately-installed approval-listener may
# hard-require (see the "deliberately NOT jq" note in cron-poll.sh); and PyYAML is NOT in the
# Python standard library, so a `python3 -c "import yaml"` would work on a dev box and die on a
# macOS launchd run with a minimal environment — this repo's signature failure shape (works
# interactively, silently fatal unattended). awk is everywhere.
#
# OUTPUT FORMAT (yaml_dump). One line per node, so every consumer is a grep:
#   path{}              a mapping node          (projects.my-api.github{})
#   path=value          a scalar                (agent.max_pr_files=50)
#   path[]=item         one list item           (…github.repos[]=my-api)
#   path[]#empty        a list that is PRESENT but EMPTY
#
# The #empty marker is load-bearing, not cosmetic. references/ticket-kind.md gives the
# investigation.* lists REPLACE-not-merge semantics in which an explicitly empty list DISABLES
# that tier while an ABSENT key keeps the shipped default. Collapse the two and that rule cannot
# be implemented.
#
# SUPPORTED SUBSET: nested block mappings, block sequences ("- item"), flow sequences
# ("[a, b]", "[]") INCLUDING ONES WRAPPED ACROSS LINES, and single-level flow mappings
# ("{ k: v, k2: [] }"). Quoted and bare scalars, full-line comments, and inline " #" comments on
# bare scalars. That is a superset of everything config/engineer.example.yaml and a real installed
# engineer.yaml use.
#
# MULTI-LINE FLOW SEQUENCES ARE NOT OPTIONAL. config/engineer.example.yaml ships this:
#     title_keywords: ["spike", "decision", "adr", "rfc", "investigate", "research",
#                      "evaluate", "compare", "assess", "determine"]
# A single-line-only reader finds no closing bracket, returns an EMPTY list, and silently
# disables the whole title-keyword tier of references/ticket-kind.md for anyone who copied the
# shipped example. No error, nothing to notice. Continuation lines are accumulated until the
# collection closes.
#
# BLOCK SEQUENCES OF MAPPINGS ("- project: ENG") are modelled as INDEXED sub-paths:
#     projects.my-api.jira.sources[0].project=ENG
#     projects.my-api.jira.sources[0].components[]=api
#     projects.my-api.jira.sources[1].project=PLAT
# plus a "path[N]{}" mapping line per element, which is what yaml_seq_len counts.
#
# This was previously refused outright — such an item emitted "[]#map-unsupported" on the reasoning
# that the only such key is projects.<slug>.jira.sources and Jira polling was model-driven, so
# nothing read it. scripts/poll-jira.sh now does. The indexed form is used rather than flattening
# the element into its parent because the elements are a SET whose members must stay distinct:
# `sources: [{project: ENG, components: [api]}, {project: PLAT}]` means ENG-with-a-component-filter
# and PLAT-as-catch-all. Flattened to jira.sources.project[]=ENG/PLAT + components[]=api, the pairing
# is gone and PLAT silently inherits ENG's filter — an N:M routing config that quietly collapses.
#
# BLOCK *AND* FLOW SEQUENCES ARE BOTH REQUIRED. A real engineer.yaml mixes them:
#   exec.allowed_commands:  is block   ("- \"bin/rails\"")
#   github.repos:           is flow    ("[\"wayfinder-api\", \"product-management\"]")
# lib-paths.sh's yaml_project_list() handles block only, and gets away with it solely because its
# one caller reads exec.allowed_commands. A reader that returned nothing for github.repos would
# poll zero repos, silently, unattended.

# yaml_dump [file] — flatten a YAML document to the line format documented above.
yaml_dump() {
  local file="${1:-${EA_CONFIG_FILE:-}}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk -v SEP="${YAML_SEP:-.}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

    # Extract a YAML scalar. Quoted -> content between the quotes (so a "#" inside quotes is
    # data, not a comment). Bare -> value up to an inline " #" comment, whitespace-trimmed.
    # Same semantics as lib-paths.sh yaml_scalar(); \047 is an apostrophe (octal beats \x27
    # for portability across awk implementations).
    function yaml_scalar(s,   q) {
      if (substr(s, 1, 1) == "\"")   { s = substr(s, 2); q = index(s, "\"");   return (q > 0) ? substr(s, 1, q - 1) : s }
      if (substr(s, 1, 1) == "\047") { s = substr(s, 2); q = index(s, "\047"); return (q > 0) ? substr(s, 1, q - 1) : s }
      sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s); return s
    }

    # Index of the bracket closing the one at position 1, honouring quotes and nesting.
    # Anything after it (an inline comment, say) is discarded by the caller.
    function find_close(s, ob, cb,   i, c, depth, inq, qc) {
      depth = 0; inq = 0; qc = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == qc) inq = 0; continue }
        if (c == "\"" || c == "\047") { inq = 1; qc = c; continue }
        if (c == ob)  depth++
        if (c == cb) { depth--; if (depth == 0) return i }
      }
      return 0
    }

    # Split on top-level commas only — commas inside quotes or nested brackets are data.
    function split_top(s, out,   i, c, depth, inq, qc, buf, n) {
      n = 0; buf = ""; depth = 0; inq = 0; qc = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { buf = buf c; if (c == qc) inq = 0; continue }
        if (c == "\"" || c == "\047") { inq = 1; qc = c; buf = buf c; continue }
        if (c == "[" || c == "{") depth++
        if (c == "]" || c == "}") depth--
        if (c == "," && depth == 0) { out[++n] = trim(buf); buf = ""; continue }
        buf = buf c
      }
      buf = trim(buf)
      if (buf != "") out[++n] = buf
      return n
    }

    function emit_flow_seq(path, s,   cpos, inner, parts, n, i) {
      cpos = find_close(s, "[", "]")
      if (cpos == 0) return
      inner = trim(substr(s, 2, cpos - 2))
      if (inner == "") { print path "[]#empty"; return }
      n = split_top(inner, parts)
      if (n == 0) { print path "[]#empty"; return }
      for (i = 1; i <= n; i++) print path "[]=" yaml_scalar(parts[i])
    }

    function emit_flow_map(path, s,   cpos, inner, parts, n, i, ci, k, v) {
      cpos = find_close(s, "{", "}")
      if (cpos == 0) return
      inner = trim(substr(s, 2, cpos - 2))
      print path "{}"
      if (inner == "") return
      n = split_top(inner, parts)
      for (i = 1; i <= n; i++) {
        ci = index(parts[i], ":")
        if (ci == 0) continue
        k = trim(substr(parts[i], 1, ci - 1))
        v = trim(substr(parts[i], ci + 1))
        emit_value(path SEP k, v)
      }
    }

    function emit_value(path, v) {
      if (v == "")                   { print path "{}";            return }
      if (substr(v, 1, 1) == "[")    { emit_flow_seq(path, v);     return }
      if (substr(v, 1, 1) == "{")    { emit_flow_map(path, v);     return }
      print path "=" yaml_scalar(v)
    }

    {
      line = $0
      sub(/\r$/, "", line)

      # Continuation of a BLOCK SCALAR (see the emitter below). Checked before the blank-line and
      # comment skips, because inside a block scalar a blank line and a leading "#" are DATA.
      if (blk_path != "") {
        if (line ~ /^[ \t]*$/) { blk_buf = blk_buf " "; next }
        match(line, /^ */); rind = RLENGTH
        if (rind > blk_indent) {
          seg = line; sub(/^[ \t]+/, "", seg); sub(/[ \t]+$/, "", seg)
          blk_buf = (blk_buf == "") ? seg : blk_buf " " seg
          next
        }
        print blk_path "=" trim(blk_buf)
        blk_path = ""
        # fall through: this line belongs to the enclosing mapping
      }

      if (line ~ /^[ \t]*$/) next
      if (line ~ /^[ \t]*#/) next          # full-line comment (a col-0 "#" is NOT a dedent)

      match(line, /^ */); ind = RLENGTH
      content = trim(line)

      # Continuation of a flow collection opened on an earlier line (see the multi-line note
      # in the header). Consume lines verbatim until the bracket balances.
      if (pending_path != "") {
        pending_buf = pending_buf " " content
        if (find_close(pending_buf, pending_ob, pending_cb) > 0) {
          emit_value(pending_path, pending_buf)
          pending_path = ""
        }
        next
      }

      # --- block sequence item -------------------------------------------------------
      # Attach to the most recent key that had an empty value. Both indentation styles are
      # legal YAML and both appear in the wild, so compare with >= rather than >:
      #     key:            key:
      #       - item        - item
      if (substr(content, 1, 1) == "-" && (length(content) == 1 || substr(content, 2, 1) == " ")) {
        item = trim(substr(content, 2))

        # "- key: value" opens a sequence of MAPPINGS (jira.sources). Give the element its own
        # indexed path and push it on the stack, so the key on this line AND every deeper line
        # that follows nest inside that element rather than inside the parent of the sequence.
        if (item ~ /^[A-Za-z0-9_.-]+:([ \t]|$)/) {
          # Braces on every arm: a bare statement followed by a newline and `else` is rejected by
          # some awks (BSD awk on macOS among them), and this file must parse identically there.
          if (seq_path != "" && ind == seq_indent) {
            owner = seq_path
          } else if (list_path != "" && ind >= list_indent) {
            owner = list_path; seq_path = list_path; seq_indent = ind; seq_n[owner] = 0
          } else {
            next
          }
          base = owner "[" seq_n[owner] "]"
          seq_n[owner]++
          print base "{}"
          while (top > 0 && ind_stack[top] >= ind) top--
          top++; ind_stack[top] = ind; path_stack[top] = base
          # Re-enter as an ordinary mapping key, indented two past the dash that introduced it —
          # which is exactly where the key physically sits ("- project:").
          content = item
          ind = ind + 2
          in_seq_item = 1
          # fall through to the mapping-key branch
        } else {
          if (list_path != "" && ind >= list_indent) print list_path "[]=" yaml_scalar(item)
          next
        }
      }

      # --- mapping key ---------------------------------------------------------------
      # A key at or above the indent of the open sequence CLOSES it. Without this, a later block
      # sequence introduced at the same depth under a different key would keep appending to the
      # index space of the previous one (statuses items landing inside sources[2], say).
      if (!in_seq_item && seq_path != "" && ind <= seq_indent) seq_path = ""
      in_seq_item = 0

      ci = index(content, ":")
      if (ci == 0) next
      key  = trim(substr(content, 1, ci - 1))
      rest = trim(substr(content, ci + 1))

      # "slug:  # comment" is an EMPTY value, not the value "# comment". lib-paths.sh has a
      # real bug here (the projects.* family compares the raw trimmed line, so a commented
      # slug header never matches); tests/slack-mcp.test.sh already carries a regression guard
      # for the same class of bug in yaml_agent_slack_mcp.
      if (substr(rest, 1, 1) == "#") rest = ""

      while (top > 0 && ind_stack[top] >= ind) top--
      path = (top > 0) ? path_stack[top] SEP key : key
      top++
      ind_stack[top]  = ind
      path_stack[top] = path

      # --- block scalar ("key: >-" / "key: |") ---------------------------------------
      # A real installed engineer.yaml writes projects.<slug>.routing.description as a FOLDED
      # block scalar, and this reader used to return the literal indicator ">-" as the value,
      # silently discarding the prose. That description is the sole input to Tier 3b of
      # references/routing-ladder.md, so the failure mode is a routing tier that looks configured
      # and decides on the two characters ">-".
      #
      # Both styles are FOLDED to one space-joined line: the flat output format is one line per
      # node and cannot represent an embedded newline. For the scalars this config actually holds
      # (descriptions, prose hints) that is lossless in every way a consumer cares about.
      if (rest ~ /^[|>][0-9]*[+-]?([ \t]+#.*)?$/) {
        blk_path = path; blk_indent = ind; blk_buf = ""
        list_path = ""
        next
      }

      if (rest == "") {
        print path "{}"
        list_path  = path        # a block sequence may follow and attach here
        list_indent = ind
      } else {
        list_path = ""
        ob = substr(rest, 1, 1)
        if (ob == "[" || ob == "{") {
          cb = (ob == "[") ? "]" : "}"
          if (find_close(rest, ob, cb) == 0) {
            pending_path = path; pending_buf = rest; pending_ob = ob; pending_cb = cb
            next
          }
        }
        emit_value(path, rest)
      }
    }

    # A block scalar running to EOF has no dedent to close it.
    END { if (blk_path != "") print blk_path "=" trim(blk_buf) }
  ' "$file"
}

# --- Accessors -------------------------------------------------------------------------
# Each takes an optional pre-computed dump on stdin via YAML_DUMP_CACHE to avoid re-parsing.
# Callers doing many lookups should set that once (ea-config.sh does).

_yaml_lines() {
  if [ -n "${YAML_DUMP_CACHE:-}" ]; then printf '%s\n' "$YAML_DUMP_CACHE"; else yaml_dump "$1"; fi
}

# yaml_get <path> [file] — scalar at an arbitrary depth. Empty (rc 0) if absent.
yaml_get() {
  local path="$1" file="${2:-}"
  _yaml_lines "$file" | awk -v p="${path}=" 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }'
}

# yaml_get_list <path> [file] — one item per line. Empty output for both an absent list and an
# explicitly empty one; use yaml_has_list to tell them apart.
yaml_get_list() {
  local path="$1" file="${2:-}"
  _yaml_lines "$file" | awk -v p="${path}[]=" 'index($0, p) == 1 { print substr($0, length(p) + 1) }'
}

# yaml_has_list <path> [file] — rc 0 if the key is PRESENT (empty or not). This is what makes
# references/ticket-kind.md's "[] disables the tier, absent keeps the default" implementable.
yaml_has_list() {
  local path="$1" file="${2:-}"
  _yaml_lines "$file" | grep -qE "^$(printf '%s' "$path" | sed 's/[][\.*^$/]/\\&/g')\[\](=|#empty)"
}

# yaml_seq_len <path> [file] — number of elements in a block sequence of MAPPINGS, i.e. the count
# of "path[N]{}" lines. Prints 0 for an absent key or for a sequence of plain scalars (those are
# yaml_get_list's job). Callers iterate `for i in $(seq 0 $((n-1)))` over "path[$i].key".
yaml_seq_len() {
  local path="$1" file="${2:-}"
  _yaml_lines "$file" \
    | grep -cE "^$(printf '%s' "$path" | sed 's/[][\.*^$/]/\\&/g')\[[0-9]+\]\{\}$"
}

# yaml_keys <path> [file] — immediate child mapping keys (e.g. the project slugs under
# "projects"). Pass an empty path for top-level keys.
yaml_keys() {
  local path="$1" file="${2:-}"
  if [ -z "$path" ]; then
    _yaml_lines "$file" | awk -v SEP="${YAML_SEP:-.}" '/\{\}$/ { k = substr($0, 1, length($0) - 2); if (index(k, SEP) == 0) print k }'
  else
    _yaml_lines "$file" | awk -v pre="${path}${YAML_SEP:-.}" -v SEP="${YAML_SEP:-.}" '
      /\{\}$/ {
        k = substr($0, 1, length($0) - 2)
        if (index(k, pre) != 1) next
        rest = substr(k, length(pre) + 1)
        if (rest != "" && index(rest, SEP) == 0) print rest
      }'
  fi
}
