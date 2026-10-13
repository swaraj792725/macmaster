#!/bin/zsh
# One-time: creates a self-signed code-signing identity "MacMaster Local Signing" in your
# login keychain so rebuilt apps keep the same signature and macOS privacy permissions
# (Accessibility, Screen Recording, Full Disk Access) don't need re-granting after every build.
set -euo pipefail
NAME="MacMaster Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "Already exists"; exit 0; fi
TMP=$(mktemp -d)
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:macmaster 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:macmaster
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P macmaster -T /usr/bin/codesign
rm -rf "$TMP"
echo "Created '$NAME'. Rebuild with scripts/build-app.sh"
