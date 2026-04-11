#!/bin/bash
# ledger.sh — state tracking for subtract installation
# Usage: ledger.sh [init|status|verify]
#
# Tracks subtract's own state, not the user's home.
# On install: init creates baseline manifest
# On boot: status surfaces drift since last signoff
# On exit: init + sign.sh authorizes new state

set -euo pipefail

SUBTRACT_HOME="${SUBTRACT_HOME:-$HOME/.subtract}"
GOVERNANCE="$SUBTRACT_HOME/governance"
MANIFEST="$GOVERNANCE/manifest.tsv"
MANIFEST_SIG="$GOVERNANCE/manifest.tsv.sig"

mkdir -p "$GOVERNANCE"

# Colors (optional, degrade gracefully)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

cmd_init() {
    local tmp=$(mktemp)
    echo -e "type\tpath\thash" > "$tmp"

    # Core subtract files
    for f in "$SUBTRACT_HOME"/*.sh "$SUBTRACT_HOME"/*.tsv; do
        [ -f "$f" ] || continue
        local name=$(basename "$f")
        local hash=$(sha256sum "$f" | cut -d' ' -f1)
        echo -e "file\t$name\t$hash" >> "$tmp"
    done

    # Skills directory
    if [ -d "$SUBTRACT_HOME/skills" ]; then
        for f in "$SUBTRACT_HOME/skills"/*; do
            [ -f "$f" ] || continue
            local name="skills/$(basename "$f")"
            local hash=$(sha256sum "$f" | cut -d' ' -f1)
            echo -e "file\t$name\t$hash" >> "$tmp"
        done
    fi

    # Governance scripts (self-tracking)
    for f in "$GOVERNANCE"/*.sh; do
        [ -f "$f" ] || continue
        local name="governance/$(basename "$f")"
        local hash=$(sha256sum "$f" | cut -d' ' -f1)
        echo -e "file\t$name\t$hash" >> "$tmp"
    done

    # Lookup tables
    if [ -d "$SUBTRACT_HOME/lookup" ]; then
        for f in "$SUBTRACT_HOME/lookup"/*.tsv; do
            [ -f "$f" ] || continue
            local name="lookup/$(basename "$f")"
            local hash=$(sha256sum "$f" | cut -d' ' -f1)
            echo -e "file\t$name\t$hash" >> "$tmp"
        done
    fi

    mv "$tmp" "$MANIFEST"
    local count=$(tail -n +2 "$MANIFEST" | wc -l)
    echo "manifest: $count entries"
}

cmd_status() {
    [ -f "$MANIFEST" ] || { echo "no manifest - run 'ledger.sh init' first"; exit 1; }

    local drift=0

    # Check signature first
    if [ -f "$MANIFEST_SIG" ] && [ -f "$GOVERNANCE/authorized_signers" ]; then
        if ! ssh-keygen -Y verify \
            -f "$GOVERNANCE/authorized_signers" \
            -I user \
            -n subtract \
            -s "$MANIFEST_SIG" \
            < "$MANIFEST" >/dev/null 2>&1; then
            echo -e "${YELLOW}signature invalid or missing${NC}"
            drift=1
        fi
    else
        echo -e "${YELLOW}unsigned state${NC}"
        drift=1
    fi

    # Check each tracked file
    tail -n +2 "$MANIFEST" | while IFS=$'\t' read -r type path hash; do
        local full="$SUBTRACT_HOME/$path"

        case "$type" in
            file)
                if [ ! -f "$full" ]; then
                    echo -e "${RED}GONE${NC}    $path"
                elif [ "$(sha256sum "$full" | cut -d' ' -f1)" != "$hash" ]; then
                    echo -e "${YELLOW}DRIFT${NC}   $path"
                fi
                ;;
        esac
    done

    # Check for new files not in manifest
    for f in "$SUBTRACT_HOME"/*.sh "$SUBTRACT_HOME"/*.tsv; do
        [ -f "$f" ] || continue
        local name=$(basename "$f")
        grep -q "^file	$name	" "$MANIFEST" 2>/dev/null || echo -e "${GREEN}NEW${NC}     $name"
    done

    return $drift
}

cmd_verify() {
    [ -f "$MANIFEST" ] || { echo "no manifest"; exit 1; }
    [ -f "$MANIFEST_SIG" ] || { echo "no signature"; exit 1; }
    [ -f "$GOVERNANCE/authorized_signers" ] || { echo "no authorized_signers"; exit 1; }

    if ssh-keygen -Y verify \
        -f "$GOVERNANCE/authorized_signers" \
        -I user \
        -n subtract \
        -s "$MANIFEST_SIG" \
        < "$MANIFEST" >/dev/null 2>&1; then
        echo "verified"
        exit 0
    else
        echo "verification failed"
        exit 1
    fi
}

case "${1:-status}" in
    init)   cmd_init ;;
    status) cmd_status ;;
    verify) cmd_verify ;;
    *)      echo "usage: ledger.sh [init|status|verify]"; exit 1 ;;
esac
