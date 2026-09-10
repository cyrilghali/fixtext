#!/bin/bash
# Create a self-signed code-signing certificate "FixText Dev" in the login keychain and trust it for code signing.
# Run once, by hand (it writes to the keychain and pops one password dialog). build.sh signs with it when present.
set -euo pipefail
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cs.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=FixText Dev
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cs.cnf" -keyout "$tmp/cs.key" -out "$tmp/cs.crt" 2>/dev/null
openssl pkcs12 -export -inkey "$tmp/cs.key" -in "$tmp/cs.crt" -out "$tmp/cs.p12" -passout pass:x -name "FixText Dev" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1   # the only PKCS12 flavour macOS `security import` reads
security import "$tmp/cs.p12" -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign -A
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$tmp/cs.crt"
security find-identity -v -p codesigning | grep "FixText Dev"
