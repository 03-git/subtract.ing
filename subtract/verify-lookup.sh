#!/bin/bash
# Verify a signed lookup table.
# Usage: verify-lookup.sh [signers-file] [principal]
# Defaults: ~/.ssh/authorized_signers, $(whoami)
SIGNERS="${1:-$HOME/.ssh/authorized_signers}"
PRINCIPAL="${2:-$(whoami)}"
ssh-keygen -Y verify -f "$SIGNERS" -I "$PRINCIPAL" -n subtract -s ~/.subtract/lookup.tsv.sig < ~/.subtract/lookup.tsv
