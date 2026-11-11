#!/bin/bash
# lib-slite-api.sh — Slite REST over curl, shared by poll-slite.sh and pr-pipeline.sh.
#
# The key goes in a header supplied via `--config -` (stdin), never `-H` in argv, so it is not
# visible in the process list of an unattended run.

# slite_init <api_base> <api_key_env> <api_key_file> — sets SLITE_BASE and SLITE_KEY (needs
# lib-secret.sh). rc 1 with SLITE_ERR when no key resolves.
slite_init() {
  SLITE_BASE="${1:-https://api.slite.com/v1}"; SLITE_BASE="${SLITE_BASE%/}"
  SLITE_KEY="$(ea_secret_resolve "$2" "$3" "$(ea_secret_service slite)" "")"
  [ -n "$SLITE_KEY" ] || { SLITE_ERR="no Slite API key available (checked env/file/keychain)"; return 1; }
}

# slite_api <out> <path> [method] [json-body] — writes the response to <out>, prints the HTTP
# status. Needs SLITE_BASE, SLITE_KEY, TMPD.
slite_api() {
  local out="$1" path="$2" method="${3:-GET}" body="${4:-}" code
  if [ "$method" = GET ]; then
    code="$(printf 'header = "x-slite-api-key: %s"\n' "$SLITE_KEY" \
      | curl -sS --config - -o "$out" -w '%{http_code}' -H 'Accept: application/json' \
             --max-time 60 --get "${SLITE_BASE}${path}" 2>"$TMPD/curlerr")"
  else
    code="$(printf 'header = "x-slite-api-key: %s"\n' "$SLITE_KEY" \
      | curl -sS --config - -o "$out" -w '%{http_code}' -X "$method" \
             -H 'Accept: application/json' -H 'Content-Type: application/json' \
             --max-time 60 --data-binary "$body" "${SLITE_BASE}${path}" 2>"$TMPD/curlerr")"
  fi
  printf '%s' "${code:-000}"
}
