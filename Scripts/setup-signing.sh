#!/bin/bash
# setup-signing.sh — Create a self-signed code-signing certificate for development.
#
# WHY: macOS TCC (permissions database) keys Screen Recording grants to the
#      app's code-signing identity.  Ad-hoc signing (--sign -) generates a
#      different identity every build, so macOS forgets your permission grant
#      each time you rebuild.  A self-signed cert is free, lives in your
#      login keychain, and gives every dev build the same stable identity.
#
# Usage:
#   ./Scripts/setup-signing.sh          # creates cert if missing
#   CERT_NAME="My Cert" ./Scripts/setup-signing.sh   # custom name
#
# After running this once, clean-build-dmg.sh will auto-detect the cert.

set -euo pipefail

CERT_NAME="${CERT_NAME:-MeetingManager-Dev}"

# Check if the certificate already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "✓ Certificate '${CERT_NAME}' already exists in keychain."
    echo "  clean-build-dmg.sh will auto-detect it."
    exit 0
fi

echo "Creating self-signed code-signing certificate '${CERT_NAME}'..."
echo ""
echo "  This certificate is for LOCAL DEVELOPMENT ONLY."
echo "  It keeps your macOS permissions (Screen Recording, Microphone)"
echo "  stable across rebuilds so you don't have to re-grant every time."
echo ""

# Create a temporary certificate signing request config
TMPDIR_CERT=$(mktemp -d)
CONFIG="${TMPDIR_CERT}/cert.cfg"

cat > "${CONFIG}" << 'EOF'
[ req ]
default_bits       = 2048
distinguished_name = req_dn
prompt             = no
[ req_dn ]
CN = MeetingManager-Dev
O  = MeetingManager Development
EOF

# Generate key and self-signed cert
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TMPDIR_CERT}/key.pem" \
    -out "${TMPDIR_CERT}/cert.pem" \
    -days 3650 \
    -config "${CONFIG}" \
    2>/dev/null

# Convert to p12 for Keychain import (empty password)
openssl pkcs12 -export \
    -out "${TMPDIR_CERT}/cert.p12" \
    -inkey "${TMPDIR_CERT}/key.pem" \
    -in "${TMPDIR_CERT}/cert.pem" \
    -passout pass: \
    2>/dev/null

# Import into login keychain and trust for code signing
security import "${TMPDIR_CERT}/cert.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -P "" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Set the cert as trusted for code signing
# This requires the user to authenticate (macOS security prompt)
echo ""
echo "  macOS will ask for your password to trust this certificate."
echo "  This is a one-time setup."
echo ""
security add-trusted-cert -d -r trustRoot \
    -p codeSign \
    -k ~/Library/Keychains/login.keychain-db \
    "${TMPDIR_CERT}/cert.pem" 2>/dev/null || {
    echo "  NOTE: Could not auto-trust the certificate."
    echo "  You may need to manually trust it:"
    echo "    1. Open Keychain Access"
    echo "    2. Find '${CERT_NAME}' in login keychain"
    echo "    3. Double-click → Trust → Code Signing → Always Trust"
}

# Clean up temp files
rm -rf "${TMPDIR_CERT}"

# Verify
echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "✓ Certificate '${CERT_NAME}' created and trusted for code signing."
    echo "  clean-build-dmg.sh will auto-detect it on next build."
    echo ""
    echo "  Your macOS permissions will now persist across rebuilds!"
else
    echo "✗ Certificate was imported but may not be trusted yet."
    echo "  Open Keychain Access → login → Certificates → '${CERT_NAME}'"
    echo "  Double-click → Trust → Code Signing → Always Trust"
    echo ""
    echo "  Then run: security find-identity -v -p codesigning"
    echo "  to verify it shows up."
fi
