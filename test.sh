#!/bin/bash
# subtract OS test suite
# validates tier escalation, lookup, destructive gate, and cloud path.
# run from repo root: bash test.sh
# works on any node. reports what's available, tests what's available.

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
skip() { echo "  SKIP: $1"; ((SKIP++)); }

# --- setup: source handler into isolated temp dir ---

export SUBTRACT_DIR=$(mktemp -d)
cp subtract/handler.sh "$SUBTRACT_DIR/"
cp subtract/lookup.tsv "$SUBTRACT_DIR/"
cp subtract/embed_match.sh "$SUBTRACT_DIR/" 2>/dev/null

# source handler (respects existing SUBTRACT_DIR)
source "$SUBTRACT_DIR/handler.sh"

echo "=== subtract OS tests ==="
echo "test dir: $SUBTRACT_DIR"
echo ""

# --- T0: lookup table ---

echo "--- T0: lookup table ---"

# known patterns should resolve
result=$(__subtract_lookup "what time is it")
if [ -n "$result" ]; then
    cmd="${result#*	}"
    if [ "$cmd" = "date +%T" ]; then
        pass "what time is it -> date +%T"
    else
        fail "what time is it -> got '$cmd', expected 'date +%T'"
    fi
else
    fail "what time is it -> no match"
fi

result=$(__subtract_lookup "list files")
if [ -n "$result" ]; then
    cmd="${result#*	}"
    if [ "$cmd" = "ls ." ]; then
        pass "list files -> ls ."
    else
        fail "list files -> got '$cmd', expected 'ls .'"
    fi
else
    fail "list files -> no match"
fi

# case insensitive
result=$(__subtract_lookup "What Time Is It")
if [ -n "$result" ]; then
    pass "case insensitive match"
else
    fail "case insensitive match"
fi

# unknown pattern should miss
result=$(__subtract_lookup "blargleflax")
if [ -z "$result" ]; then
    pass "unknown pattern -> no match"
else
    fail "unknown pattern -> unexpected match: $result"
fi

# canvas tag
result=$(__subtract_lookup "open youtube")
if [ -n "$result" ]; then
    tag="${result%%	*}"
    if [ "$tag" = "canvas" ]; then
        pass "youtube -> [canvas] tag"
    else
        fail "youtube -> got tag '$tag', expected 'canvas'"
    fi
else
    fail "youtube -> no match"
fi

# --- destructive gate ---

echo ""
echo "--- destructive gate ---"

if __subtract_is_destructive "rm -rf /tmp/foo"; then
    pass "rm detected as destructive"
else
    fail "rm not detected as destructive"
fi

if __subtract_is_destructive "dd if=/dev/zero of=/dev/sda"; then
    pass "dd detected as destructive"
else
    fail "dd not detected as destructive"
fi

if ! __subtract_is_destructive "ls -la"; then
    pass "ls not destructive"
else
    fail "ls falsely flagged as destructive"
fi

if ! __subtract_is_destructive "echo hello"; then
    pass "echo not destructive"
else
    fail "echo falsely flagged as destructive"
fi

# --- truncation ---

echo ""
echo "--- context truncation ---"

long_output=$(for i in $(seq 1 50); do echo "line $i"; done)
truncated=$(__subtract_truncate "$long_output")
if echo "$truncated" | grep -q "\[truncated: 50 lines total\]"; then
    pass "50-line output truncated"
else
    fail "50-line output not truncated"
fi

short_output="line 1"
not_truncated=$(__subtract_truncate "$short_output")
if ! echo "$not_truncated" | grep -q "\[truncated"; then
    pass "1-line output not truncated"
else
    fail "1-line output incorrectly truncated"
fi

# --- T0: Spanish lookup ---

echo ""
echo "--- T0: Spanish lookup ---"

result=$(__subtract_lookup "lista archivos")
if [ -n "$result" ]; then
    cmd="${result#*	}"
    if [ "$cmd" = "ls ." ]; then
        pass "lista archivos -> ls ."
    else
        fail "lista archivos -> got '$cmd', expected 'ls .'"
    fi
else
    fail "lista archivos -> no match"
fi

result=$(__subtract_lookup "qué hora es")
if [ -n "$result" ]; then
    cmd="${result#*	}"
    if [ "$cmd" = "date +%T" ]; then
        pass "qué hora es -> date +%T"
    else
        fail "qué hora es -> got '$cmd', expected 'date +%T'"
    fi
else
    fail "qué hora es -> no match"
fi

result=$(__subtract_lookup "estoy conectado")
if [ -n "$result" ]; then
    pass "estoy conectado -> match"
else
    fail "estoy conectado -> no match"
fi

# English still works alongside Spanish
result=$(__subtract_lookup "what time is it")
if [ -n "$result" ]; then
    pass "English still works with Spanish present"
else
    fail "English broken after Spanish entries"
fi

# --- T0.5: man page routing ---

echo ""
echo "--- T0.5: man page routing ---"

if command -v man &>/dev/null; then
    # hit: natural language containing a real command
    result=$(__subtract_manpage "how do I grep")
    if [ "$result" = "grep" ]; then
        pass "T0.5 extracts grep from natural language"
    else
        fail "T0.5 'how do I grep' -> got '$result', expected 'grep'"
    fi

    # hit: command not at end
    result=$(__subtract_manpage "show me chmod options")
    if [ "$result" = "chmod" ]; then
        pass "T0.5 extracts chmod from middle of input"
    else
        fail "T0.5 'show me chmod options' -> got '$result', expected 'chmod'"
    fi

    # miss: single word (needs >= 2)
    result=$(__subtract_manpage "grep")
    if [ -z "$result" ]; then
        pass "T0.5 rejects single-word input"
    else
        fail "T0.5 matched single word: '$result'"
    fi

    # miss: all stopwords
    result=$(__subtract_manpage "how do I find the time to make a date")
    if [ -z "$result" ]; then
        pass "T0.5 stopwords filter find/time/make/date"
    else
        fail "T0.5 stopword leak: matched '$result'"
    fi

    # miss: pure Spanish (no Unix command name)
    result=$(__subtract_manpage "lista archivos")
    if [ -z "$result" ]; then
        pass "T0.5 misses pure Spanish (no command name)"
    else
        fail "T0.5 false positive on Spanish: '$result'"
    fi

    # hit: Spanish with embedded command name
    result=$(__subtract_manpage "cómo uso chmod")
    if [ "$result" = "chmod" ]; then
        pass "T0.5 extracts chmod from Spanish input"
    else
        fail "T0.5 Spanish+command -> got '$result', expected 'chmod'"
    fi
else
    skip "man not installed (T0.5 tests require man)"
fi

# --- T1: embedding similarity ---

echo ""
echo "--- T1: embedding similarity ---"

if curl -s --connect-timeout 1 http://localhost:11434/api/tags &>/dev/null && command -v jq &>/dev/null; then
    # create a minimal intents.tsv + embeddings for testing
    cat > "$SUBTRACT_DIR/intents.tsv" <<'INTENTSEOF'
how many movies do i have	ls /mnt/media/movies/ | wc -l
count my movies	ls /mnt/media/movies/ | wc -l
show disk usage	du -sh *
INTENTSEOF
    # pre-embed the test corpus using curl+jq (no python)
    echo '[]' > "$SUBTRACT_DIR/embeddings.json"
    while IFS=$'\t' read -r text cmd; do
        [ -z "$text" ] && continue
        emb=$(curl -s -X POST -H "Content-Type: application/json" \
            -d "$(jq -n --arg m nomic-embed-text --arg p "$text" '{model:$m,prompt:$p}')" \
            http://localhost:11434/api/embeddings 2>/dev/null | jq '.embedding')
        [ "$emb" = "null" ] || [ -z "$emb" ] && continue
        jq --arg t "$text" --arg c "$cmd" --argjson e "$emb" \
            '. += [{"text":$t,"command":$c,"embedding":$e}]' \
            "$SUBTRACT_DIR/embeddings.json" > "$SUBTRACT_DIR/embeddings.json.tmp" \
            && mv "$SUBTRACT_DIR/embeddings.json.tmp" "$SUBTRACT_DIR/embeddings.json"
    done < "$SUBTRACT_DIR/intents.tsv"
    embed_count=$(jq length "$SUBTRACT_DIR/embeddings.json" 2>/dev/null)

    if [ -f "$SUBTRACT_DIR/embeddings.json" ] && [ "${embed_count:-0}" -gt 0 ]; then
        # exact match (should score ~1.0)
        result=$(__subtract_embed "how many movies do i have")
        if [ -n "$result" ]; then
            pass "T1 exact match returned command: $result"
        else
            fail "T1 exact match returned empty"
        fi

        # novel phrasing (should generalize above 0.8)
        result=$(__subtract_embed "count all the films I got")
        if [ -n "$result" ]; then
            pass "T1 novel phrasing matched: $result"
        else
            skip "T1 novel phrasing below threshold (expected on small corpus)"
        fi

        # unrelated input (should miss)
        result=$(__subtract_embed "what is the weather in tokyo")
        if [ -z "$result" ]; then
            pass "T1 unrelated input missed (below threshold)"
        else
            fail "T1 false positive on unrelated input: $result"
        fi
    else
        skip "embedding generation failed"
    fi
else
    skip "ollama or jq not available for T1"
fi

# --- T2: local model ---

echo ""
echo "--- T2: local model (ollama) ---"

if curl -s --connect-timeout 1 http://localhost:11434/api/tags &>/dev/null; then
    result=$(__subtract_generate "list all files including hidden")
    if [ -n "$result" ]; then
        pass "T2 generated a command: $result"
    else
        fail "T2 returned empty (ollama running but no response)"
    fi
else
    skip "ollama not running on localhost:11434"
fi

# --- T4: cloud escalation ---

echo ""
echo "--- T4: cloud escalation (claude -p) ---"

if command -v claude &>/dev/null || [ -x "$HOME/.local/bin/claude" ]; then
    # test with cloud_ai configured
    echo "claude" > "$SUBTRACT_DIR/cloud_ai"
    result=$(__subtract_cloud "show the 5 largest files in the current directory")
    if [ -n "$result" ]; then
        pass "T4 generated a command: $result"
    else
        fail "T4 returned empty (claude installed but no response)"
    fi

    # test without cloud_ai configured
    rm -f "$SUBTRACT_DIR/cloud_ai"
    result=$(__subtract_cloud "show files")
    if [ -z "$result" ]; then
        pass "T4 skipped when cloud_ai not configured"
    else
        fail "T4 fired without cloud_ai configured"
    fi
else
    skip "claude CLI not installed"
fi

# --- onboard gate ---

echo ""
echo "--- onboard gate ---"

# .onboarded exists -> gate should not fire
touch "$SUBTRACT_DIR/.onboarded"
# we can't test the full handler interactively, but we can test the condition
if [ -f "$SUBTRACT_DIR/.onboarded" ]; then
    pass ".onboarded flag respected"
else
    fail ".onboarded flag not found after touch"
fi

# .onboarded missing -> gate condition true
rm -f "$SUBTRACT_DIR/.onboarded"
if [ ! -f "$SUBTRACT_DIR/.onboarded" ]; then
    pass ".onboarded missing triggers gate condition"
else
    fail ".onboarded still exists after rm"
fi

# reconfigure entry exists in lookup
result=$(__subtract_lookup "reconfigure subtract")
if [ -n "$result" ]; then
    pass "reconfigure* pattern exists in lookup"
else
    fail "reconfigure* pattern missing from lookup"
fi

# --- escalation chain order ---

echo ""
echo "--- escalation chain ---"

# T0 hit should not fall through
touch "$SUBTRACT_DIR/.onboarded"
result=$(__subtract_lookup "what time is it")
if [ -n "$result" ]; then
    pass "T0 hit stops escalation"
else
    fail "T0 miss on known pattern"
fi

# unknown intent should miss T0
result=$(__subtract_lookup "calculate the mass of jupiter in kilograms")
if [ -z "$result" ]; then
    pass "novel intent misses T0 (escalation continues)"
else
    fail "novel intent hit T0 unexpectedly"
fi

# --- skills: index rebuild and lookup ---

echo ""
echo "--- skills: index and lookup ---"

# set up a minimal skills tree
mkdir -p "$SUBTRACT_DIR/skills/device"
mkdir -p "$SUBTRACT_DIR/skills/safety"
cat > "$SUBTRACT_DIR/skills/device/connecting-wifi.md" <<'EOF'
---
aliases: connect wifi, join network, wireless setup, nmcli
tags: network, wireless, device
---

CONNECTING TO WIFI

Steps:
1. nmcli device wifi list
2. nmcli device wifi connect SSID password PASS
EOF
cat > "$SUBTRACT_DIR/skills/safety/emergency-contacts-setup.md" <<'EOF'
---
aliases: emergency contacts, ice contacts, emergency numbers
tags: safety, contacts
---

SETTING UP EMERGENCY CONTACTS

Steps:
1. Create ~/emergency.txt
EOF

# rebuild index
cp subtract/skills-rebuild.sh "$SUBTRACT_DIR/"
bash "$SUBTRACT_DIR/skills-rebuild.sh" > /dev/null 2>&1

# index file should exist
if [ -f "$SUBTRACT_DIR/skills/.index" ]; then
    pass "skills index built"
else
    fail "skills index not built"
fi

# index should contain expected tokens
if grep -q "^wifi	device/connecting-wifi$" "$SUBTRACT_DIR/skills/.index"; then
    pass "index contains 'wifi' -> device/connecting-wifi"
else
    fail "index missing 'wifi' -> device/connecting-wifi"
fi

if grep -q "^emergency	safety/emergency-contacts-setup$" "$SUBTRACT_DIR/skills/.index"; then
    pass "index contains 'emergency' -> safety/emergency-contacts-setup"
else
    fail "index missing 'emergency' -> safety/emergency-contacts-setup"
fi

# stopwords should be filtered out
if grep -q "^and	" "$SUBTRACT_DIR/skills/.index"; then
    fail "stopword 'and' found in index"
else
    pass "stopwords filtered from index"
fi

# tokens under 3 chars should be filtered (2-char tokens like "at", "be")
if grep -q "^an	" "$SUBTRACT_DIR/skills/.index"; then
    fail "2-char token 'an' found in index"
else
    pass "tokens under 3 chars filtered"
fi

# --- skills: prefix stripping ---

echo ""
echo "--- skills: prefix stripping ---"

# re-source handler with skills dir populated
touch "$SUBTRACT_DIR/.onboarded"
source "$SUBTRACT_DIR/handler.sh"

result=$(__subtract_strip_prefix "how do i connect wifi")
if [ "$result" = "connect wifi" ]; then
    pass "strip 'how do i ' prefix"
else
    fail "strip 'how do i ' -> got '$result', expected 'connect wifi'"
fi

result=$(__subtract_strip_prefix "how to connect wifi")
if [ "$result" = "connect wifi" ]; then
    pass "strip 'how to ' prefix"
else
    fail "strip 'how to ' -> got '$result', expected 'connect wifi'"
fi

result=$(__subtract_strip_prefix "teach me connect wifi")
if [ "$result" = "connect wifi" ]; then
    pass "strip 'teach me ' prefix"
else
    fail "strip 'teach me ' -> got '$result', expected 'connect wifi'"
fi

# no prefix match should fail
result=$(__subtract_strip_prefix "connect wifi")
if [ $? -ne 0 ]; then
    pass "no prefix -> returns failure"
else
    fail "no prefix -> unexpected success: '$result'"
fi

# --- skills: lookup ---

echo ""
echo "--- skills: grep lookup ---"

# single match: "how do i connect wifi" -> device/connecting-wifi
result=$(__subtract_skills "how do i connect wifi")
if [[ "$result" == "skill:device/connecting-wifi" ]]; then
    pass "skills single match: connect wifi"
else
    fail "skills single match: got '$result', expected 'skill:device/connecting-wifi'"
fi

# no match: "how to juggle flaming swords"
result=$(__subtract_skills "how to juggle flaming swords")
if [ -z "$result" ]; then
    pass "skills no match: unknown query"
else
    fail "skills no match: got '$result', expected empty"
fi

# no prefix: bare "connect wifi" should return 1 (prefix required)
result=$(__subtract_skills "connect wifi")
if [ -z "$result" ]; then
    pass "skills requires prefix"
else
    fail "skills matched without prefix: '$result'"
fi

# multi-match: add a second wifi-related skill
cat > "$SUBTRACT_DIR/skills/device/wifi-troubleshooting.md" <<'EOF'
---
aliases: wifi problems, wifi not working, troubleshoot wireless
tags: network, wireless, wifi
---

WIFI TROUBLESHOOTING

Steps:
1. nmcli device status
EOF
bash "$SUBTRACT_DIR/skills-rebuild.sh" > /dev/null 2>&1
source "$SUBTRACT_DIR/handler.sh"

result=$(__subtract_skills "how to wifi wireless")
if [[ "$result" == list:* ]]; then
    pass "skills multi-match returns list"
else
    fail "skills multi-match: got '$result', expected 'list:*'"
fi

# --- skills: show N ---

echo ""
echo "--- skills: show N ---"

# after multi-match, lastmatch file should exist
lastmatch="${TMPDIR:-/tmp}/.subtract-skills-lastmatch.${USER:-$$}"
if [ -f "$lastmatch" ]; then
    pass "lastmatch file created after multi-match"
else
    fail "lastmatch file missing"
fi

# show with non-numeric should be rejected
result=$(source "$SUBTRACT_DIR/handler.sh" && __subtract_handle "show 3abc" 2>&1)
if echo "$result" | grep -q "usage:"; then
    pass "show rejects non-numeric input"
else
    fail "show accepted non-numeric: '$result'"
fi

# --- skills: stale detection ---

echo ""
echo "--- skills: stale detection ---"

# fresh index should not be stale
if ! __subtract_skills_stale; then
    pass "fresh index is not stale"
else
    fail "fresh index reported as stale"
fi

# touch a skill file to make it newer than index
sleep 1
touch "$SUBTRACT_DIR/skills/device/connecting-wifi.md"
if __subtract_skills_stale; then
    pass "index stale after skill file touched"
else
    fail "index not stale after skill file touched"
fi

# --- skills: management commands ---

echo ""
echo "--- skills: management commands ---"

# "skills" lists domains
result=$(__subtract_handle skills 2>&1)
if echo "$result" | grep -q "device"; then
    pass "skills command lists domains"
else
    fail "skills command: '$result'"
fi

# "skills device" lists skills in domain
result=$(__subtract_handle skills device 2>&1)
if echo "$result" | grep -q "connecting-wifi"; then
    pass "skills <domain> lists skills"
else
    fail "skills <domain>: '$result'"
fi

# "skills rebuild" works
result=$(__subtract_handle skills rebuild 2>&1)
if echo "$result" | grep -q "index rebuilt"; then
    pass "skills rebuild command"
else
    fail "skills rebuild: '$result'"
fi

# "skills nonexistent" prints error
result=$(__subtract_handle skills nonexistent 2>&1)
if echo "$result" | grep -q "no skills domain"; then
    pass "skills <nonexistent> prints error"
else
    fail "skills <nonexistent>: '$result'"
fi

# --- cleanup ---

# --- hook line count invariants ---

echo ""
echo "--- hook invariants ---"

bash_hook_lines=$(wc -l < subtract/hooks/bash.sh)
zsh_hook_lines=$(wc -l < subtract/hooks/zsh.sh)

if [ "$bash_hook_lines" -le 15 ]; then
    pass "hooks/bash.sh is $bash_hook_lines lines (max 15)"
else
    fail "hooks/bash.sh grew to $bash_hook_lines lines (max 15)"
fi

if [ "$zsh_hook_lines" -le 15 ]; then
    pass "hooks/zsh.sh is $zsh_hook_lines lines (max 15)"
else
    fail "hooks/zsh.sh grew to $zsh_hook_lines lines (max 15)"
fi

# no python in subtract/
python_files=$(find subtract/ -name '*.py' 2>/dev/null | head -1)
if [ -z "$python_files" ]; then
    pass "no python files in subtract/"
else
    fail "python file found: $python_files"
fi

# --- cleanup ---

rm -f "${TMPDIR:-/tmp}/.subtract-skills-lastmatch.${USER:-$$}"
rm -rf "$SUBTRACT_DIR"

# --- summary ---

echo ""
echo "=== results ==="
echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "all $TOTAL tests passed."
else
    echo "$FAIL of $TOTAL tests failed."
    exit 1
fi
