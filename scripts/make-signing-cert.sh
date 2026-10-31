#!/bin/bash
# Creates a self-signed code-signing certificate, "Mac TV Local Signing", in the login keychain.
#
# Builds signed with the same certificate keep the same identity, so macOS remembers permissions
# like Accessibility across rebuilds and updates. Ad-hoc signing changes identity on every build.
# This doesn't notarize anything: Gatekeeper still shows the first-launch warning.
set -euo pipefail

NAME="${1:-Mac TV Local Signing}"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="$(openssl rand -hex 16)"

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$PASS" 2>/dev/null
# -T lets codesign use the key without asking each time.
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" \
    -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\" in the login keychain."
