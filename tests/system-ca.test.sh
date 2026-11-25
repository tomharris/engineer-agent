#!/bin/bash
# Tests for ea_trust_system_ca (scripts/lib-paths.sh).
# Run: bash tests/system-ca.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export EA_AGENT_DIR="$TMP/agent"
. "$REPO_ROOT/scripts/lib-paths.sh"
CA="$EA_AGENT_DIR/state/system-ca.pem"

# Fakes: uname reports FAKE_OS; security logs each call and prints one cert naming the keychain,
# or nothing when FAKE_PEM=none.
mkdir -p "$TMP/bin"
printf '#!/bin/bash\necho "${FAKE_OS:-Darwin}"\n' > "$TMP/bin/uname"
cat > "$TMP/bin/security" <<SH
#!/bin/bash
echo "\$*" >> "$TMP/security.calls"
[ "\${FAKE_PEM:-}" = none ] && exit 0
printf -- '-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n' "\${@: -1}"
SH
chmod +x "$TMP/bin/uname" "$TMP/bin/security"
export PATH="$TMP/bin:$PATH"

# trust — run ea_trust_system_ca in a subshell; prints SSL_CERT_FILE afterwards.
trust() { ( ea_trust_system_ca; printf '%s' "${SSL_CERT_FILE:-}" ); }
calls() { if [ -f "$TMP/security.calls" ]; then grep -c . "$TMP/security.calls"; else echo 0; fi; }
reset() { rm -rf "$EA_AGENT_DIR" "$TMP/security.calls"; }

echo "== macOS"
reset; unset SSL_CERT_FILE
eq "exports the bundle" "$CA" "$(trust)"
eq "bundle holds the system roots and the System keychain" \
  "/System/Library/Keychains/SystemRootCertificates.keychain|/Library/Keychains/System.keychain" \
  "$(grep -v -- ----- "$CA" | paste -sd'|' -)"
eq "a fresh bundle is reused" "2|$CA" "$(trust >/dev/null; echo "$(calls)|$(trust)")"
touch -t 202001010000 "$CA"
eq "a bundle over a day old is rebuilt" 4 "$(trust >/dev/null; calls)"

echo "== left alone"
reset
eq "a set SSL_CERT_FILE is kept" "/etc/my-ca.pem|0" "$(SSL_CERT_FILE=/etc/my-ca.pem trust)|$(calls)"
reset
eq "not macOS: nothing exported" "|0" "$(FAKE_OS=Linux trust)|$(calls)"
reset
eq "no certificates found: nothing exported" "" "$(FAKE_PEM=none trust)"
[ -e "$CA" ] && bad "an empty bundle was kept" || ok "no empty bundle is kept"
eq "no temp file is left" "" "$(ls "$EA_AGENT_DIR/state" 2>/dev/null)"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" = 0 ]
