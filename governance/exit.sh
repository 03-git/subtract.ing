#!/bin/bash
# exit.sh — governance signoff at subtract session end
# Called by handler.sh on exit or explicitly by user
#
# Updates manifest and signs the new state

set -euo pipefail

SUBTRACT_HOME="${SUBTRACT_HOME:-$HOME/.subtract}"
GOVERNANCE="$SUBTRACT_HOME/governance"

echo "=== subtract signoff ==="

# Update manifest
"$GOVERNANCE/ledger.sh" init

# Sign
"$GOVERNANCE/sign.sh"

echo "session state authorized"
