#!/bin/bash
# boot.sh — governance check at subtract startup
# Called by handler.sh before processing commands
#
# Returns 0 if state is clean or user acknowledges drift
# Returns 1 if user aborts

set -euo pipefail

SUBTRACT_HOME="${SUBTRACT_HOME:-$HOME/.subtract}"
GOVERNANCE="$SUBTRACT_HOME/governance"

# Run status check
output=$("$GOVERNANCE/ledger.sh" status 2>&1)
status=$?

if [ $status -eq 0 ] && [ -z "$output" ]; then
    # Clean state, signed, no drift
    exit 0
fi

# There's drift or unsigned state
echo "=== subtract governance ==="
echo ""
echo "$output"
echo ""

# Check if signature exists at all
if [ ! -f "$GOVERNANCE/manifest.tsv.sig" ]; then
    echo "first run - initializing governance..."
    "$GOVERNANCE/ledger.sh" init
    "$GOVERNANCE/sign.sh"
    exit 0
fi

# Drift exists - surface it
echo "unsigned changes detected since last session."
echo "review above, then:"
echo "  continue  - proceed with current state"
echo "  sign      - authorize changes and proceed"
echo "  abort     - exit without proceeding"
echo ""
read -p "> " choice

case "$choice" in
    continue|c)
        echo "proceeding with unsigned state"
        exit 0
        ;;
    sign|s)
        "$GOVERNANCE/ledger.sh" init
        "$GOVERNANCE/sign.sh"
        exit 0
        ;;
    abort|a|*)
        echo "aborted"
        exit 1
        ;;
esac
