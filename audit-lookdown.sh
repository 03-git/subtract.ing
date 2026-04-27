#!/bin/bash
# audit-lookdown.sh — test lookdown.tsv patterns and commands across platforms
# usage: audit-lookdown.sh [lookdown.tsv]
# runs on: macOS, Linux, WSL

set -uo pipefail

LOOKDOWN="${1:-${SUBTRACT_DIR:-$HOME/.subtract}/lookdown.tsv}"

if [[ ! -f "$LOOKDOWN" ]]; then
    echo "not found: $LOOKDOWN" >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux)
        grep -qi microsoft /proc/version 2>/dev/null && PLATFORM=wsl || PLATFORM=linux ;;
    *) PLATFORM=unknown ;;
esac

if [[ -t 1 ]]; then
    RED='\033[31m' YEL='\033[33m' DIM='\033[90m' RST='\033[0m'
else
    RED='' YEL='' DIM='' RST=''
fi

TOTAL=0 GREEDY=0 CMD_MISS=0 MATCH_FAIL=0

lower() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

glob_keywords() {
    local p="$1"
    p="${p#\*}"; p="${p%\*}"
    echo "${p//\*/ }"
}

glob_match() {
    # shellcheck disable=SC2254
    [[ "$1" == $2 ]]
}

gen_tests() {
    local pattern="$1"
    local kw words joined n first last
    kw=$(glob_keywords "$pattern")
    read -ra words <<< "$kw"
    joined="${words[*]}"
    n=${#words[@]}
    first="${words[0]}"
    last="${words[$((n-1))]}"

    printf 'match\t%s\tcanonical\n' "$joined"

    if [[ "$pattern" == \** ]]; then
        printf 'match\t%s\tleading * accepts prefix\n' "please $joined"
    else
        printf 'miss\t%s\tno leading * rejects prefix\n' "please $joined"
    fi

    if [[ "$pattern" == *\* ]]; then
        printf 'match\t%s\ttrailing * accepts suffix\n' "$joined right now"
    else
        printf 'miss\t%s\tno trailing * rejects suffix\n' "$joined right now"
    fi

    if (( n > 1 )); then
        local inner="${pattern#\*}"; inner="${inner%\*}"
        if [[ "$inner" == *\** ]]; then
            local seg1="${inner%%\**}" seg2="${inner#*\*}"
            printf 'match\t%s\tinternal * accepts filler\n' "${seg1} really ${seg2}"
        fi
        printf 'miss\t%s\tbare keyword without verb\n' "$last"
    fi

    if [[ "$pattern" == \**\* ]] && (( n == 1 )); then
        printf 'greedy\t%s\tsentence intercepts kiwix\n' "what is $joined"
        printf 'greedy\t%s\tquestion intercepts kiwix\n' "tell me about $joined"
        printf 'greedy\t%s\taction prefix intercepts verb+noun\n' "play $joined"
    fi
}

first_binary() {
    local cmd="$1"
    while [[ "$cmd" =~ ^[A-Z_]+= ]]; do cmd="${cmd#* }"; done
    cmd="${cmd#\(}"; cmd="${cmd# }"
    local bin="${cmd%% *}"
    echo "${bin##*/}"
}

check_cmd() {
    local cmd="$1"
    [[ "$cmd" =~ ^ssh\  ]] && { echo "remote"; return 0; }

    local -a alts
    local i=0 alt
    while IFS= read -r alt; do
        alt="${alt## }"; alt="${alt%% }"
        [[ -n "$alt" ]] && alts[i++]="$alt"
    done <<< "$(sed 's/ || /\n/g' <<< "$cmd")"

    local any_ok=0 missing="" bin first_seg
    for alt in "${alts[@]}"; do
        first_seg="${alt%%|*}"
        first_seg="${first_seg## }"; first_seg="${first_seg%% 2>*}"
        bin=$(first_binary "$first_seg")
        case "$bin" in
            echo|printf|read|eval|cd|export|return|true|false|test|cat|bash|sh|"") any_ok=1; continue ;;
        esac
        if command -v "$bin" >/dev/null 2>&1; then
            any_ok=1
        else
            missing="${missing:+$missing, }$bin"
        fi
    done

    if (( any_ok )); then echo "ok"; else echo "$missing"; return 1; fi
}

audit_entry() {
    local lineno="$1" pattern="$2" tag="$3" cmd="$4"
    local pattern_lower expect input reason input_lower actual result
    pattern_lower=$(lower "$pattern")

    while IFS=$'\t' read -r expect input reason; do
        [[ -z "$expect" ]] && continue
        input_lower=$(lower "$input")
        glob_match "$input_lower" "$pattern_lower" && actual="match" || actual="miss"

        case "$expect" in
            match)
                if [[ "$actual" != "match" ]]; then
                    printf "${RED}FAIL${RST}    L%-4d  %-35s  \"%s\" should match (%s)\n" \
                        "$lineno" "$pattern" "$input" "$reason"
                    ((MATCH_FAIL++))
                fi ;;
            miss)
                if [[ "$actual" != "miss" ]]; then
                    printf "${YEL}WIDE${RST}    L%-4d  %-35s  \"%s\" matches (%s)\n" \
                        "$lineno" "$pattern" "$input" "$reason"
                fi ;;
            greedy)
                if [[ "$actual" == "match" ]]; then
                    printf "${YEL}GREEDY${RST}  L%-4d  %-35s  catches \"%s\" (%s)\n" \
                        "$lineno" "$pattern" "$input" "$reason"
                    ((GREEDY++))
                fi ;;
        esac
    done <<< "$(gen_tests "$pattern")"

    result=$(check_cmd "$cmd") || true
    if [[ "$result" != "ok" && "$result" != "remote" ]]; then
        printf "${RED}NOCMD${RST}   L%-4d  %-35s  not found: %s [%s]\n" \
            "$lineno" "$pattern" "$result" "$PLATFORM"
        ((CMD_MISS++))
    fi
}

main() {
    printf 'platform: %s\nfile:     %s\n---\n' "$PLATFORM" "$LOOKDOWN"

    local lineno=0 line pattern rest tag cmd
    while IFS= read -r line; do
        ((lineno++))
        [[ "$line" =~ ^#|^$ ]] && continue
        ((TOTAL++))

        pattern="${line%%	*}"
        rest="${line#*	}"
        if [[ "$rest" == \[*\]* ]]; then
            tag="${rest#\[}"; tag="${tag%%\]*}"
            cmd="${rest#*\]}"
            cmd="${cmd#	}"
        else
            tag="stdout"
            cmd="$rest"
        fi

        audit_entry "$lineno" "$pattern" "$tag" "$cmd"
    done < "$LOOKDOWN"

    printf '%s\n' "---"
    printf 'entries: %d  greedy: %d  missing-cmd: %d  match-fail: %d\n' \
        "$TOTAL" "$GREEDY" "$CMD_MISS" "$MATCH_FAIL"

    (( MATCH_FAIL + CMD_MISS > 0 )) && return 1
    return 0
}

main
