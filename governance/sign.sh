#!/bin/bash
# sign.sh — sign the current manifest state
# Usage: sign.sh
#
# Signs manifest.tsv with the user's subtract signing key.
# Creates the key on first run if it doesn't exist.

set -euo pipefail

SUBTRACT_HOME="${SUBTRACT_HOME:-$HOME/.subtract}"
GOVERNANCE="$SUBTRACT_HOME/governance"
MANIFEST="$GOVERNANCE/manifest.tsv"
MANIFEST_SIG="$GOVERNANCE/manifest.tsv.sig"
KEY="$GOVERNANCE/signing_key"
SIGNERS="$GOVERNANCE/authorized_signers"
NAMESPACE="subtract"

# Ensure manifest exists
[ -f "$MANIFEST" ] || { echo "no manifest - run 'ledger.sh init' first"; exit 1; }

# Create signing key if missing
if [ ! -f "$KEY" ]; then
    echo "creating signing key..."
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "subtract-governance" -q
    echo "user $(cat "$KEY.pub")" > "$SIGNERS"
    echo "key created: $KEY"
fi

# Sign the manifest
rm -f "$MANIFEST_SIG"
ssh-keygen -Y sign -f "$KEY" -n "$NAMESPACE" "$MANIFEST" 2>/dev/null

if [ -f "$MANIFEST_SIG" ]; then
    echo "signed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
else
    echo "signing failed"
    exit 1
fi
