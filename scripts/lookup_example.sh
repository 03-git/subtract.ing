#!/usr/bin/env bash
# lookup_example.sh
# Scan shell history for wrappers that cover a kernel primitive, add
# redirect rows to ~/.subtract/lookdown.personal.tsv so you see the
# primitive next time instead of reaching for the wrapper.
#
# Adopt: cp lookup_example.sh ~/scripts/lookup.sh && chmod +x ~/scripts/lookup.sh
# Edit the map below to your taste. Run when you want to reseed.
# No daemon. No cron. Invocation is intentional.

set -u

HIST="${HISTFILE:-$HOME/.bash_history}"
OUT="$HOME/.subtract/lookdown.personal.tsv"
THRESHOLD=3

mkdir -p "$(dirname "$OUT")"
touch "$OUT"

# wrapper:primitive pairs. remove any you disagree with; add your own.
# space-separated so this runs on macOS bash 3.2 without associative arrays.
PAIRS="
bat:cat
exa:ls
eza:ls
lsd:ls
fd:find
rg:grep
ripgrep:grep
http:curl
httpie:curl
xh:curl
curlie:curl
dust:du
duf:df
btm:top
procs:ps
dog:dig
sd:sed
z:cd
zoxide:cd
tldr:man
"

added=0
tab=$(printf '\t')
for pair in $PAIRS; do
    wrapper="${pair%:*}"
    primitive="${pair#*:}"
    count=$(awk -v w="$wrapper" '$1==w' "$HIST" | wc -l)
    [ "$count" -lt "$THRESHOLD" ] && continue
    grep -q "^${wrapper}${tab}" "$OUT" && continue
    printf '%s\t%s\n' "$wrapper" "$primitive" >> "$OUT"
    printf 'added: %s -> %s  (observed %dx)\n' "$wrapper" "$primitive" "$count"
    added=$((added + 1))
done

if [ "$added" -eq 0 ]; then
    echo "no wrappers above threshold ($THRESHOLD). nothing to add."
fi
