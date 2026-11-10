# Integrations

## Available Integrations

- GitHub (PRs and Issues): `gh` CLI via Bash (requires `gh auth login`)
- Slack (two backends via `agent.slack.method`, see "Config Loading Pattern" above): the
  [Spy](https://github.com/tomharris/spy) CLI (`spy`, default) reusing the local Slack desktop
  session (no OAuth/app install), OR `scripts/slack-mcp.sh` (`mcp-proxy`, for Enterprise Grid)
  going through the Keychain OAuth token + Anthropic MCP proxy. Both expose the same interface:
  reads with `<slack> read`/`<slack> thread`/`<slack> search`, posts with `<slack> send`
  (`--thread <ts>` for threaded replies), reacts with `<slack> react`/`unreact` (idempotent in
  both). Same binary works in interactive skills and the headless cron/ntfy scripts.
  Because the MCP-proxy shim runs as one Bash invocation, its internal `curl`/`jq`/`security`
  subprocesses need no separate allowlist entry — a single `Bash(<shim> read:*)`-style rule
  covers the whole call. **But that rule must match the shim's path as the model *actually runs*
  it, and getting there took several corrections, each learned from a real failing poll (transcript
  evidence, not theory):** the skills reference the shim as `${CLAUDE_PLUGIN_ROOT}/scripts/slack-mcp.sh`
  (per `poll-slack`/execute-item), and (1) the **model expands `${CLAUDE_PLUGIN_ROOT}` to an
  absolute path** before Bash ever sees it — it does *not* pass the literal `${CLAUDE_PLUGIN_ROOT}`
  token, so a single-quoted-literal allowlist rule is dead code and never matches (an earlier fix
  that added one did nothing); and (2) **that expanded root is not stable — it has been observed
  resolving to THREE different dirs across runs**: the dev-repo `PLUGIN_ROOT` a script derives from
  its own location (a bare `--plugin-dir` run), the *installed cache* path
  (`~/.claude/plugins/cache/engineer-agent/engineer-agent/<ver>`, when marketplace-installed shadows
  `--plugin-dir`), **and** the *marketplace checkout* path
  (`~/.claude/plugins/marketplaces/engineer-agent`). A rule built from only one or two of these
  misses whenever the runtime picks the third, and any miss denies the Slack call non-interactively
  (a prompt under `-p` is a denial). Fix: `cron-poll.sh` and `approval-listener.sh` allowlist the
  shim's **expanded** abs path for **all three** candidate roots — the script's own `PLUGIN_ROOT`,
  `resolve_installed_plugin_root()` (highest-version installed cache dir), and
  `resolve_marketplace_plugin_root()` (the marketplace checkout) — all three in `lib-paths.sh`, so
  whichever root the runtime resolves, a rule matches. (3) The **poll allowlist must also include
  the `auth` verb, not just `read`/`thread`**: the model runs `slack-mcp.sh auth` as a read-only
  token preflight before reading, and when only `read`/`thread` were allowed that preflight was
  denied — the model then treated the shim as unavailable and cascaded to the direct
  `mcp__claude_ai_Slack__slack_read_channel` connector, which is *also* unlisted, so both Slack
  paths were denied and the poll silently drafted nothing for the affected projects while its
  narrative sometimes still (wrongly) claimed Slack "succeeded" — trust the receipt's `errors:`
  list and the transcript, not the prose summary. `cron-poll.sh` allowlists `read`/`thread`/`auth`
  for every root; `approval-listener.sh` uses a trailing-`*` rule that already covers all verbs.
  (`spy` needs none of this — it is a bare literal identical in rule and invocation; that is the
  pattern the shim's path form can't reach.) (4) **A rule must match the command *form*, not just
  the path — and the durable fix is to stop the model guessing at all.** The root was never the
  only variable: the model also chooses how to *invoke* the shim, and it was observed emitting
  `bash <abs>/scripts/slack-mcp.sh auth 2>&1`, whose executable is `bash` — matching no `<abs>/…`
  rule, so the call is refused outright. That denial is **fatal, not recoverable**: the model
  concludes the shim is unavailable and cascades to the unlisted direct connector, and every Slack
  source errors. Transcript-confirmed on `2026-08-01T15:00Z` and `2026-08-03T13:04Z` — **exactly**
  the two runs out of the last sixteen that emitted a `bash `-prefixed call, and exactly the two
  that failed; the other fourteen used the bare form and succeeded. The form varied run-to-run
  because the model *rediscovers the shim every run*: `${CLAUDE_PLUGIN_ROOT}` is not resolvable
  inside the run (the probe `echo "PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT"` is itself refused with
  `Contains simple_expansion`), so it falls back to `find`/`ls` and improvises. So the **primary**
  fix is a `SLACK:` directive in the poll prompt that pins the exact resolved `${SLACK_BIN}` and
  forbids filesystem discovery, a `bash`/`sh`/`env` prefix, compound commands, and the
  `mcp__claude_ai_Slack__*` fallback — the same pre-expanded-path treatment `notify.sh` already
  got. The allowlist widening (bare **and** `bash `-prefixed, generated as roots × verbs × forms
  in both scripts) is now only defense in depth for when the model improvises anyway. Note the
  connector is deliberately **not** allowlisted: the shim stays the single Slack path so its
  exit-`75` skip-on-expiry semantics remain well-defined. Also allowlist `Bash(echo:*)` — Claude
  Code evaluates each part of a compound command separately, so the model's habitual
  `… auth 2>&1; echo "EXIT:$?"` probe got the *whole* invocation refused; it recovered by retrying,
  so it never failed a poll, but it burned a turn on nearly every run.
- Jira: `mcp__atlassian__*` tools (optional — either Jira or GitHub Issues per project)
- Slite: `mcp__slite__*` tools
- ntfy (optional): push notifications + remote approval via `curl` (publish) and `scripts/approval-listener.sh` (subscribe). Listener requires `jq`. Turn-completion pushes (`hooks/hooks.json` → `scripts/turn-notify-hook.sh`) add **no** hard dependency — jq is used only to decode the message excerpt, and its absence degrades to a label-only push.


