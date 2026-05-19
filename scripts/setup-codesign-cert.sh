#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing certificate so every
# rebuild of Claude Widget uses the same identity. Keychain "Always Allow"
# decisions then persist across builds — no more repeated prompts.
#
# Usage:
#   bash scripts/setup-codesign-cert.sh
#
# Re-run is safe; it skips if the cert already exists.
set -euo pipefail

CERT_NAME="ClaudeWidget Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "✓ Cert \"$CERT_NAME\" already in login keychain — nothing to do."
    exit 0
fi

echo "▶ Generating self-signed code-signing cert \"$CERT_NAME\"…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CONFIG="$TMP/openssl.cnf"
cat > "$CONFIG" <<'EOF'
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_ca

[req_dn]
CN = ClaudeWidget Dev

[v3_ca]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req \
    -newkey rsa:2048 -nodes \
    -x509 -days 3650 \
    -config "$CONFIG" \
    -keyout "$TMP/cert.key" \
    -out "$TMP/cert.crt" \
    >/dev/null 2>&1

PASSWORD="claudewidget"
# OpenSSL 3.x defaults to PBES2/PBKDF2 PKCS12 which Apple's `security` tool
# can't import. `-legacy` falls back to the PKCS12 v1 MAC format `security`
# understands. Harmless on LibreSSL / older OpenSSL (flag is ignored).
PKCS12_LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q "\-legacy"; then
    PKCS12_LEGACY="-legacy"
fi

openssl pkcs12 -export $PKCS12_LEGACY \
    -inkey "$TMP/cert.key" \
    -in "$TMP/cert.crt" \
    -name "$CERT_NAME" \
    -passout "pass:$PASSWORD" \
    -out "$TMP/cert.p12" \
    >/dev/null 2>&1

echo "▶ Importing to login keychain (may prompt for keychain password)…"
security import "$TMP/cert.p12" \
    -P "$PASSWORD" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "▶ Trusting cert for code signing…"
# `add-trusted-cert` writes the trust setting; -r trustRoot makes macOS treat
# the self-signed cert as trustworthy for the code-signing extended key usage.
security add-trusted-cert \
    -d -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$TMP/cert.crt" 2>/dev/null || true

if security find-identity -p codesigning -v "$KEYCHAIN" | grep -q "\"$CERT_NAME\""; then
    echo
    echo "✓ Cert installed. Rebuild Claude Widget — keychain prompts will be persistent now."
    echo
    echo "Next:"
    echo "  bash scripts/install-to-applications.sh"
else
    echo "✗ Cert install verification failed. Try running again with -x to see errors."
    exit 1
fi
