#!/bin/bash
# Create a stable, self-signed code-signing identity in the login keychain so
# macOS Accessibility / Input Monitoring grants persist across rebuilds.
#
# An ad-hoc signature (codesign -s -) has no stable identity, so TCC drops the
# permission every build — this fixes that. The cert is only trusted for
# *signing*, not by Gatekeeper, which is fine for a locally built tool.
#
# Run once:  ./tools/make-signing-cert.sh
set -euo pipefail

NAME="${SIGN_IDENTITY:-Monitor Brightness Sync Dev}"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Identity \"$NAME\" already exists — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PW="tmp-import-pw"

echo "› Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -nodes \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# Legacy PKCS#12 so Apple's `security` can import it (OpenSSL 3 default fails).
openssl pkcs12 -export -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout "pass:$PW" -legacy -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES >/dev/null 2>&1

echo "› Importing into the login keychain…"
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PW" -T /usr/bin/codesign

# Pre-authorize codesign (and Apple tools) to use the key so builds don't block
# on a keychain prompt. Best-effort: may ask for your login password once.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true

echo "✓ Created signing identity: $NAME"
echo "  Now run ./build.sh — it signs with this identity automatically."
echo "  On the first build, macOS may ask to let codesign use the key — click \"Always Allow\"."
