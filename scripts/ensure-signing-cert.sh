#!/bin/bash
# Creates a stable local code-signing identity. Ad-hoc signatures change every build,
# and macOS then treats the permission switch as belonging to a different app.
set -euo pipefail

NAME="Highlight Copy Local"
KEYCHAIN="${HOME}/Library/Keychains/highlight-copy.keychain-db"
PASSWORD="highlight-copy"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cfg" << 'EOF'
[ req ]
distinguished_name = req_dn
x509_extensions = codesign_ext
prompt = no
[ req_dn ]
CN = Highlight Copy Local
[ codesign_ext ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
  -config "$WORK/cert.cfg"
openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/cert.p12" \
  -name "$NAME" -passout pass:temp

if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
# Trusting this cert as a root waits on an admin password dialog and is unnecessary.
# codesign accepts the identity from this keychain, and the designated requirement is the certificate hash.

CURRENT="$(security list-keychains -d user | tr -d '"')"
case "$CURRENT" in
  *highlight-copy.keychain-db*) ;;
  *) security list-keychains -d user -s "$KEYCHAIN" $CURRENT ;;
esac
