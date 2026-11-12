#!/bin/bash
# Shared by the implement-next job suites. Run the job with PATH="$TMP/resume-bin:$PATH": its git
# answers the origin URL and ls-remote (the tip is $RESUME_NEW), and its gh says the gh user (tom)
# made the push from $RESUME_OLD to $RESUME_NEW. Everything else falls through to the suite's
# own stubs.
RESUME_OLD=1111111111111111111111111111111111111111 RESUME_NEW=2222222222222222222222222222222222222222

# stopped_pipeline_fixture <job> <item> — <item>'s pipeline stopped on $RESUME_OLD; a second
# ledger item of <job> is pending in drafts/, so the job's guards skip a new pick.
stopped_pipeline_fixture() {
  local d="$EA_AGENT_DIR/state/pr-pipeline/${2%.md}" rb="$TMP/resume-bin"
  mkdir -p "$d" "$rb"
  echo tom/branch > "$d/branch"
  printf 'stopped\tCI still failing\n' > "$d/result"
  echo "$RESUME_OLD" > "$d/stopped_head"; echo "$RESUME_OLD" > "$d/trusted_from"
  printf '%s\t%s\tr\tK-1\n%s\t%s\tr\tK-2\n' "$2" "$1" "pending-$2" "$1" >> "$EA_AGENT_DIR/state/autopilot-items.tsv"
  touch "$Q/drafts/pending-$2"
  cat > "$rb/git" <<EOF
#!/bin/bash
case " \$* " in
  *" ls-remote "*) printf '$RESUME_NEW\trefs/heads/tom/branch\n' ;;
  *" remote.origin.url "*) echo https://github.com/acme/web.git ;;
  *) exec "$TMP/bin/git" "\$@" ;;
esac
EOF
  cat > "$rb/gh" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "api user") echo tom ;;
  "api repos/acme/web/activity"*) echo '[{"before": "$RESUME_OLD", "after": "$RESUME_NEW", "actor": {"login": "tom"}}]' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$rb/git" "$rb/gh"
}
