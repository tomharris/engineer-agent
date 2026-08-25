#!/bin/bash
# setup-credentials.sh — store the Jira / Slite API credentials the scripted collectors need.
#
# INTERACTIVE ONLY. This is the single writer in the credential story; lib-secret.sh, poll-jira.sh
# and poll-slite.sh only ever READ. Nothing unattended calls this.
#
# WHY THE KEYCHAIN IS THE DEFAULT: cron/launchd/systemd hand a supervised run a MINIMAL environment,
# so a token exported from a shell profile is present in every terminal you test from and absent in
# the poll — the collector then skips cleanly every 15 minutes forever and the only symptom is Jira
# never being scripted. The poll already runs as a gui/$UID LaunchAgent specifically so it can read
# the login keychain (slack-mcp.sh relies on the same property), so this route needs no scheduler
# change and leaves no secret on disk.
#
# Usage:
#   setup-credentials.sh jira            store a Jira API token
#   setup-credentials.sh slite           store a Slite API key
#   setup-credentials.sh check           report what resolves, WITHOUT printing any secret
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib-paths.sh"
. "${SCRIPT_DIR}/lib-yaml.sh"
. "${SCRIPT_DIR}/lib-secret.sh"

EA_CFG="$("${SCRIPT_DIR}/ea-config.sh" dump 2>/dev/null)"
cfg() { printf '%s\n' "$EA_CFG" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }

usage() { sed -n '/^# Usage:/,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; }

store() {
  local kind="$1" account="$2" prompt="$3" secret svc
  svc="$(ea_secret_service "$kind")"
  printf '%s' "$prompt"
  # -s: never echo the token to the terminal or scrollback.
  read -rs secret; echo
  [ -n "$secret" ] || { echo "nothing entered; aborted" >&2; return 1; }
  if ea_secret_store "$svc" "$account" "$secret"; then
    echo "stored in the login keychain (service: ${svc}${account:+, account: $account})"
    echo "verify with: $(basename "$0") check"
  else
    cat >&2 <<EOF
could not write to the keychain.

Fallback: put the token in a 0600 file and point config at it —
  umask 077; printf '%s\\n' '<token>' > ~/.config/engineer-agent/${kind}.token
then set agent.${kind}.$( [ "$kind" = jira ] && echo api_token_file || echo api_key_file ) to that path.
EOF
    return 1
  fi
}

case "${1:-}" in
  jira)
    email="$(cfg agent.jira.email)"
    site="$(cfg agent.jira.site)"
    if [ -z "$site" ] || [ -z "$email" ]; then
      cat >&2 <<EOF
agent.jira.site and agent.jira.email must be set in ${EA_CONFIG_FILE} first.
The keychain entry is stored under the account name agent.jira.email, so a missing
email would store the token where the collector will not look for it.
EOF
      exit 1
    fi
    echo "Mint a token at https://id.atlassian.com/manage-profile/security/api-tokens"
    echo "Site: ${site}   Account: ${email}"
    store jira "$email" "Jira API token (input hidden): " ;;
  slite)
    echo "Find your key at https://app.slite.com -> Settings -> API"
    store slite "" "Slite API key (input hidden): " ;;
  check)
    # Reports RESOLVABILITY only — never the value. Mirrors exactly what the collectors do, so a
    # green line here means the collector will find it too.
    jmail="$(cfg agent.jira.email)"
    jt="$(ea_secret_resolve "$(cfg agent.jira.api_token_env)" "$(cfg agent.jira.api_token_file)" "$(ea_secret_service jira)" "$jmail")"
    st="$(ea_secret_resolve "$(cfg agent.slite.api_key_env)" "$(cfg agent.slite.api_key_file)" "$(ea_secret_service slite)" "")"
    printf 'jira.site        : %s\n' "$(cfg agent.jira.site)"
    printf 'jira.email       : %s\n' "$jmail"
    printf 'jira token       : %s\n'  "$([ -n "$jt" ] && echo 'resolved' || echo 'NOT FOUND (Jira stays model-driven)')"
    printf 'slite key        : %s\n'  "$([ -n "$st" ] && echo 'resolved' || echo 'NOT FOUND (Slite stays model-driven)')"
    for dep in curl jq; do
      printf '%-17s: %s\n' "$dep" "$(command -v "$dep" >/dev/null 2>&1 && echo present || echo "MISSING (source stays model-driven)")"
    done
    # A token that only resolves from the environment is the launchd trap: it will not be there when
    # the LaunchAgent runs. Say so, because nothing else ever will.
    env_name="$(cfg agent.jira.api_token_env)"
    if [ -n "$env_name" ] && [ -n "${!env_name:-}" ] && [ -z "$(_ea_secret_from_keychain "$(ea_secret_service jira)" "$jmail")" ]; then
      echo
      echo "WARNING: the Jira token resolves ONLY from \$${env_name}. cron/launchd hand the poll a"
      echo "minimal environment, so the supervised poll will NOT see it and will skip Jira silently."
      echo "Run '$(basename "$0") jira' to store it in the keychain instead."
    fi ;;
  ""|-h|--help) usage ;;
  *) echo "setup-credentials.sh: unknown command '$1'" >&2; usage >&2; exit 2 ;;
esac
