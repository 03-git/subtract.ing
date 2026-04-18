# subtract -- translation layer
# type what you mean. the computer figures out the command.
#
# T0: lookup table. instant, local, no dependencies.
# T0.5: man page routing (direct command match) + apropos fallback (discovery queries).
# T1: embedding similarity (optional).
# T2: local generative model (optional). requires ollama + a pulled model.
# T4: cloud escalation (optional). requires claude CLI.
# kiwix: questions (input ending in ?) route to local kiwix corpus.
#
# everything lives in ~/.subtract/. read it, edit it, delete it.

SUBTRACT_DIR="${SUBTRACT_DIR:-$HOME/.subtract}"

# bash hangs on unclosed quotes (what's, don't, can't) with a bare "> " prompt.
# user doesn't know what happened. replace PS2 with an explanation.
PS2="(unclosed quote -- press ctrl-c and rephrase without apostrophes) "
SUBTRACT_LOOKUP="$SUBTRACT_DIR/lookdown.tsv"
SUBTRACT_SKILLS="$SUBTRACT_DIR/skills"
SUBTRACT_KIWIX="${SUBTRACT_KIWIX:-http://localhost:8888}"
SUBTRACT_LAST_OUTPUT=""
SUBTRACT_MAX_CONTEXT=20

# skills prefix patterns: procedural queries ("how do I X", "teach me X")
# matched after T0, before kiwix. triggers grep against skills index.
SUBTRACT_SKILLS_PREFIXES="how do i |how to |teach me |steps to |guide to |tutorial |tutorial for "

# destructive verbs that always gate behind explicit confirmation
# array, not string: zsh doesn't word-split unquoted $var
SUBTRACT_DESTRUCTIVE=(rm rmdir dd mkfs chmod chown shred truncate)

# upgrade injection state file
SUBTRACT_STATE="$SUBTRACT_DIR/.state"

# --- state helpers (upgrade injection) ---

__subtract_state_read() {
    # read key from state file, default to $2 if missing
    local key="$1" default="${2:-}"
    if [ -f "$SUBTRACT_STATE" ]; then
        local val
        val=$(grep "^${key}=" "$SUBTRACT_STATE" 2>/dev/null | cut -d= -f2-)
        [ -n "$val" ] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

__subtract_state_write() {
    # write key=value to state file
    local key="$1" value="$2"
    mkdir -p "$(dirname "$SUBTRACT_STATE")"
    if [ -f "$SUBTRACT_STATE" ]; then
        # remove existing key, append new
        grep -v "^${key}=" "$SUBTRACT_STATE" > "${SUBTRACT_STATE}.tmp" 2>/dev/null || true
        mv "${SUBTRACT_STATE}.tmp" "$SUBTRACT_STATE"
    fi
    echo "${key}=${value}" >> "$SUBTRACT_STATE"
}

__subtract_is_intent() {
    # returns 0 if input looks like intent (2+ words AND 10+ chars)
    local input="$1"
    local words chars
    words=$(echo "$input" | wc -w | tr -d ' ')
    chars=${#input}
    [ "$words" -ge 2 ] && [ "$chars" -ge 10 ]
}

__subtract_upgrade_hint() {
    # called on intent miss: track strikes, maybe suggest upgrade
    local input="$1"
    local now misses last_miss suggested no_nags decay_days

    # check flags first
    no_nags=$(__subtract_state_read "no_nags" "false")
    [ "$no_nags" = "true" ] && return

    suggested=$(__subtract_state_read "suggested" "false")
    [ "$suggested" = "true" ] && return

    # already have local model? skip
    [ -f "$SUBTRACT_DIR/model" ] && return

    now=$(date +%s)
    misses=$(__subtract_state_read "misses" "0")
    last_miss=$(__subtract_state_read "last_miss" "0")

    # decay: reset if >7 days since last miss
    decay_days=604800  # 7 days in seconds
    if [ "$last_miss" -gt 0 ] && [ $((now - last_miss)) -gt $decay_days ]; then
        misses=0
    fi

    # increment
    misses=$((misses + 1))
    __subtract_state_write "misses" "$misses"
    __subtract_state_write "last_miss" "$now"

    # at strike 3, show upgrade suggestion
    if [ "$misses" -eq 3 ]; then
        echo ""
        echo "subtract: couldn't match that intent."
        echo "Local inference not installed. Run 'subtract upgrade' for offline T1+T2."
        echo "(Run 'subtract config --no-nags' to silence this.)"
        __subtract_state_write "suggested" "true"
    fi
}

# --- internal helpers ---

__subtract_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# shell compat: split string into words array
# bash word-splits unquoted $var; zsh does not. this normalizes both.
if [ -n "$ZSH_VERSION" ]; then
    __subtract_to_words() { eval "$1=(\${=2})"; }
else
    __subtract_to_words() { eval "read -ra $1 <<< \"\$2\""; }
fi

__subtract_truncate() {
    local lines
    lines=$(echo "$1" | wc -l | tr -d ' ')
    if [ "$lines" -gt "$SUBTRACT_MAX_CONTEXT" ]; then
        echo "$1" | tail -n "$SUBTRACT_MAX_CONTEXT"
        echo "[truncated: $lines lines total]"
    else
        echo "$1"
    fi
}

__subtract_capture() {
    if [ -z "$_SUBTRACT_FROM_HANDLER" ]; then
        SUBTRACT_LAST_OUTPUT="last command: $(fc -ln -1 2>/dev/null | sed "s/^[[:space:]]*//")"
    fi
    _SUBTRACT_FROM_HANDLER=""
}
# PROMPT_COMMAND (bash) and precmd_functions (zsh) set in hooks/bash.sh and hooks/zsh.sh

# --- skills: procedural knowledge lookup ---

__subtract_skills_stale() {
    # check if index needs rebuild: any .md file newer than index
    local index="$SUBTRACT_SKILLS/.index"
    [ ! -f "$index" ] && return 0
    local newer
    newer=$(find "$SUBTRACT_SKILLS" -name '*.md' -newer "$index" -print -quit 2>/dev/null)
    [ -n "$newer" ] && return 0
    return 1
}

__subtract_strip_prefix() {
    local input
    input=$(__subtract_lower "$1")
    local prefix
    local -a prefixes
    # split pipe-delimited prefix string into array (bash: read -ra, zsh: parameter expansion)
    if [ -n "$ZSH_VERSION" ]; then
        prefixes=("${(s:|:)SUBTRACT_SKILLS_PREFIXES}")
    else
        IFS='|' read -ra prefixes <<< "$SUBTRACT_SKILLS_PREFIXES"
    fi
    for prefix in "${prefixes[@]}"; do
        prefix="${prefix# }"
        [ -z "$prefix" ] && continue
        if [[ "$input" == ${prefix}* ]]; then
            echo "${input#$prefix}"
            return 0
        fi
    done
    return 1
}

__subtract_skills() {
    local input="$1"
    [ ! -d "$SUBTRACT_SKILLS" ] && return 1

    local index="$SUBTRACT_SKILLS/.index"

    # auto-rebuild if stale
    if __subtract_skills_stale; then
        bash "$SUBTRACT_DIR/skills-rebuild.sh" > /dev/null 2>&1 || true
    fi
    [ ! -f "$index" ] && return 1

    # strip prefix to get query terms
    local residual
    residual=$(__subtract_strip_prefix "$input") || return 1
    [ -z "$residual" ] && return 1

    # tokenize residual, filter stopwords, grep index for each token
    local -a tokens matches
    local token
    __subtract_to_words tokens "$residual"

    # find files matching ALL non-stopword tokens
    local stopwords=" a an and are at be by do for from how i if in is it me my no not of on or so the to up us we "
    local -a search_tokens
    for token in "${tokens[@]}"; do
        token=$(__subtract_lower "$token")
        [ ${#token} -lt 3 ] && continue
        case "$stopwords" in *" $token "*) continue ;; esac
        search_tokens+=("$token")
    done
    [ ${#search_tokens[@]} -eq 0 ] && return 1

    # intersect candidate files across all tokens (avoids 0-vs-1 index difference between bash/zsh)
    local candidates="" first=1
    for token in "${search_tokens[@]}"; do
        if [ "$first" -eq 1 ]; then
            candidates=$(grep -i "^${token}	" "$index" 2>/dev/null | cut -f2 | sort -u)
            [ -z "$candidates" ] && return 1
            first=0
        else
            local next_candidates
            next_candidates=$(grep -i "^${token}	" "$index" 2>/dev/null | cut -f2 | sort -u)
            candidates=$(comm -12 <(echo "$candidates") <(echo "$next_candidates"))
            [ -z "$candidates" ] && return 1
        fi
    done

    # count matches
    local count
    count=$(echo "$candidates" | wc -l | tr -d ' ')

    if [ "$count" -eq 1 ]; then
        # single match: display it
        local filepath="$SUBTRACT_SKILLS/${candidates}.md"
        if [ -f "$filepath" ]; then
            echo "skill:${candidates}"
            return 0
        else
            # index references deleted file, rebuild and retry
            bash "$SUBTRACT_DIR/skills-rebuild.sh" > /dev/null 2>&1 || true
            return 1
        fi
    else
        # multi-match: return list for handler to display
        local list=""
        local n=1
        while IFS= read -r match; do
            list="${list}${n}. ${match}"$'\n'
            n=$((n+1))
        done <<< "$candidates"
        # cache for "show N" retrieval
        echo "$candidates" > ${TMPDIR:-/tmp}/.subtract-skills-lastmatch.${USER:-$$}
        echo "list:${count}"$'\n'"${list}"
        return 0
    fi
}

# --- T0: lookup table ---

__subtract_lookup() {
    local input_lower
    input_lower=$(__subtract_lower "$1")
    local pattern tag cmd rest pattern_lower
    while IFS=$'\t' read -r pattern rest; do
        [[ "$pattern" =~ ^#.*$ || -z "$pattern" ]] && continue
        pattern_lower=$(__subtract_lower "$pattern")
        # shellcheck disable=SC2254
        # zsh needs $~ for glob expansion in variables
        if [ -n "$ZSH_VERSION" ]; then
            [[ "$input_lower" == $~pattern_lower ]] || continue
        else
            [[ "$input_lower" == $pattern_lower ]] || continue
        fi
        # three-column: pattern<TAB>[tag]<TAB>command
        # two-column:   pattern<TAB>command (backwards compat)
        if [[ "$rest" =~ ^\[([a-z]+)\] ]]; then
            if [ -n "$ZSH_VERSION" ]; then tag="${match[1]}"; else tag="${BASH_REMATCH[1]}"; fi
            cmd="${rest#*$'\t'}"
        else
            tag="stdout"
            cmd="$rest"
        fi
        echo "${tag}	${cmd}"
        return 0
    done < "$SUBTRACT_LOOKUP"
    return 1
}

# --- T0.5: man page routing ---
# input contains a known command name but isn't a bare invocation.
# "how do I rsync" or "rsync help" -> man rsync
# bare "rsync" never reaches here (shell runs it or T0 catches it).

__subtract_manpage() {
    local input_lower
    input_lower=$(__subtract_lower "$1")
    local -a words
    __subtract_to_words words "$input_lower"
    [ ${#words[@]} -lt 2 ] && return 1

    local word
    for word in "${words[@]}"; do
        # skip short words and common filler
        [ ${#word} -lt 2 ] && continue
        case "$word" in
            # filler and interrogatives
            how|do|does|did|the|what|when|where|which|who|help|use|using|with|for|can|you|a|an|in|to|is|it|my|me|i) continue ;;
            # commands that are common English words
            make|time|find|sort|date|watch|read|test|file|head|tail|type|open|top|more|less) continue ;;
            cat|tee|cut|paste|join|split|nice|kill|echo|touch|sleep|wait|true|false) continue ;;
            set|get|run|env|man|list|print|move|copy|link|diff|exec) continue ;;
        esac
        # is this word a real command with a man page?
        if command -v "$word" >/dev/null 2>&1 && man -w "$word" >/dev/null 2>&1; then
            echo "$word"
            return 0
        fi
    done
    return 1
}

# T0.5 fallback: apropos for discovery-shaped queries
# "what tool compresses files" -> apropos compress -> list of commands
__subtract_apropos() {
    local input_lower
    input_lower=$(__subtract_lower "$1")

    # fire on discovery and definitional patterns
    case "$input_lower" in
        what*tool*|what*command*|how*find*tool*|find*tool*|command*for*|tool*for*) ;;
        what*is*|what*are*|define*|explain*) ;;
        *) return 1 ;;
    esac

    # extract search terms: skip filler, keep action words
    local -a words search_terms
    __subtract_to_words words "$input_lower"
    local word
    local stopwords=" a an and are at be by can could do does for from have how i if in is it me my no not of on or so that the them there to up us was we what which will with would you your tool tools command commands find "
    for word in "${words[@]}"; do
        [ ${#word} -lt 3 ] && continue
        case "$stopwords" in *" $word "*) continue ;; esac
        search_terms+=("$word")
    done
    [ ${#search_terms[@]} -eq 0 ] && return 1

    # try apropos with each term, section 1 only
    local term results
    for term in "${search_terms[@]}"; do
        results=$(apropos -s 1 "$term" 2>/dev/null | head -5)
        [ -n "$results" ] && break
    done

    # no results: still answer for definitional queries
    if [ -z "$results" ]; then
        case "$input_lower" in
            what*is*|what*are*|define*|explain*)
                echo "none:${search_terms[*]}"
                return 0
                ;;
        esac
        return 1
    fi

    # count and format
    local count
    count=$(echo "$results" | wc -l | tr -d ' ')
    rm -f "${TMPDIR:-/tmp}/.subtract-apropos-lastmatch.${USER:-$$}"

    local list="" n=1
    while IFS= read -r line; do
        local cmd_name desc
        cmd_name=$(echo "$line" | awk '{print $1}')
        desc=$(echo "$line" | sed 's/^[^-]*- //')
        list="${list}${n}. ${cmd_name} - ${desc}"$'\n'
        echo "$cmd_name" >> "${TMPDIR:-/tmp}/.subtract-apropos-lastmatch.${USER:-$$}"
        n=$((n+1))
    done <<< "$results"

    if [ "$count" -eq 1 ]; then
        echo "single:$(echo "$results" | awk '{print $1}')"
    else
        echo "list:${count}"$'\n'"${list}"
    fi
    return 0
}

# --- T1: embedding similarity (optional) ---

__subtract_embed() {
    # requires: ollama with nomic-embed-text, embeddings.json, jq, curl
    [ -f "$SUBTRACT_DIR/embeddings.json" ] || return 1
    command -v jq &>/dev/null || return 1
    curl -s --connect-timeout 1 http://localhost:11434/api/tags &>/dev/null || return 1

    local input="$1"
    local match
    match=$(printf '%s' "$input" | bash "$SUBTRACT_DIR/embed_match.sh" "$SUBTRACT_DIR" 2>/dev/null)
    [ -z "$match" ] && return 1

    local score matched_text hint_cmd
    score=$(printf '%s' "$match" | cut -f1)
    matched_text=$(printf '%s' "$match" | cut -f2)
    hint_cmd=$(printf '%s' "$match" | cut -f3)

    # threshold: 0.8. below this, hints mislead the model.
    local above
    above=$(awk "BEGIN {print ($score >= 0.8) ? 1 : 0}")
    [ "$above" != "1" ] && return 1

    # T1 hit: generate command using matched entry as hint
    local context=""
    if [ -n "$SUBTRACT_LAST_OUTPUT" ]; then
        context=$(__subtract_truncate "$SUBTRACT_LAST_OUTPUT")
    fi

    local model
    model=$(/usr/bin/head -1 "$SUBTRACT_DIR/model" 2>/dev/null)
    [ -z "$model" ] && model="qwen2.5:7b"

    local ctx_str=""
    [ -n "$context" ] && ctx_str=" Previous output: $context."

    local prompt="Translate to a single bash command. Output ONLY the command, nothing else. No explanation. No markdown. No code fences. A similar intent \"${matched_text}\" maps to: ${hint_cmd}. Use that as a hint but generate the exact command for this intent.${ctx_str} Input: ${input}"

    local payload result
    payload=$(jq -n --arg model "$model" --arg prompt "$prompt" \
        '{model: $model, prompt: $prompt, stream: false}')
    result=$(curl -s --connect-timeout 3 -X POST -H "Content-Type: application/json" \
        -d "$payload" http://localhost:11434/api/generate 2>/dev/null)
    [ -z "$result" ] && return 1

    result=$(echo "$result" | jq -r '.response // empty')
    [ -z "$result" ] && return 1

    result="${result//\`\`\`bash/}"
    result="${result//\`\`\`/}"
    result=$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "$result"
}

# --- ask llama.cpp/cloud: direct answers (not command translation) ---

__subtract_ask_local() {
    local inference_host inference_port
    inference_host=$(cat "$SUBTRACT_DIR/inference_host" 2>/dev/null)
    inference_port=$(cat "$SUBTRACT_DIR/inference_port" 2>/dev/null)
    [ -z "$inference_port" ] && inference_port="8081"

    local input="$1"
    local prompt="Answer concisely. /no_think ${input}"
    local payload result

    payload=$(jq -n --arg content "$prompt" \
        '{messages: [{role: "user", content: $content}], max_tokens: 500}')

    if [ -n "$inference_host" ] && [ "$inference_host" != "localhost" ]; then
        result=$(ssh -o ConnectTimeout=5 "$inference_host" \
            "curl -s http://localhost:${inference_port}/v1/chat/completions -H 'Content-Type: application/json' --data-binary @-" <<<"$payload" 2>/dev/null)
    else
        curl -s --connect-timeout 1 "http://localhost:${inference_port}/v1/models" &>/dev/null || return 1
        result=$(curl -s --connect-timeout 10 -X POST -H "Content-Type: application/json" \
            --data-binary "$payload" "http://localhost:${inference_port}/v1/chat/completions" 2>/dev/null)
    fi

    [ -z "$result" ] && return 1
    result=$(echo "$result" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    [ -z "$result" ] && return 1
    echo "$result"
}

__subtract_ask_cloud() {
    local cloud_ai
    cloud_ai=$(cat "$SUBTRACT_DIR/cloud_ai" 2>/dev/null)
    [ -z "$cloud_ai" ] && return 1

    local input="$1"
    local result

    case "$cloud_ai" in
        claude)
            command -v claude &>/dev/null || [ -x "$HOME/.local/bin/claude" ] || return 1
            result=$(claude -p "Answer concisely: $input" 2>/dev/null)
            ;;
        *)
            return 1
            ;;
    esac

    [ -z "$result" ] && return 1
    echo "$result"
}

# --- T2: local generative model (optional) ---

__subtract_generate() {
    # requires: llama-server (local or remote via inference_host)
    local inference_host inference_port
    inference_host=$(cat "$SUBTRACT_DIR/inference_host" 2>/dev/null)
    inference_port=$(cat "$SUBTRACT_DIR/inference_port" 2>/dev/null)
    [ -z "$inference_port" ] && inference_port="8081"

    local input="$1"
    local prompt="Translate to a single bash command. Output ONLY the command, nothing else. No explanation. No markdown. No code fences. /no_think Input: ${input}"
    local payload result

    payload=$(jq -n --arg content "$prompt" \
        '{messages: [{role: "user", content: $content}], max_tokens: 500}')

    # remote inference: SSH to host and curl llama-server there
    if [ -n "$inference_host" ] && [ "$inference_host" != "localhost" ]; then
        result=$(ssh -o ConnectTimeout=5 "$inference_host" \
            "curl -s http://localhost:${inference_port}/v1/chat/completions -H 'Content-Type: application/json' --data-binary @-" <<<"$payload" 2>/dev/null)
    else
        # local inference: llama-server on localhost
        curl -s --connect-timeout 1 "http://localhost:${inference_port}/v1/models" &>/dev/null || return 1
        result=$(curl -s --connect-timeout 10 -X POST -H "Content-Type: application/json" \
            --data-binary "$payload" "http://localhost:${inference_port}/v1/chat/completions" 2>/dev/null)
    fi

    [ -z "$result" ] && return 1

    # extract response from OpenAI-compatible format
    result=$(echo "$result" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    [ -z "$result" ] && return 1

    # strip markdown fences
    result="${result//\`\`\`bash/}"
    result="${result//\`\`\`/}"
    result=$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "$result"
}

# --- tier 4: cloud escalation (optional) ---

__subtract_cloud() {
    local cloud_ai
    cloud_ai=$(cat "$SUBTRACT_DIR/cloud_ai" 2>/dev/null)
    [ -z "$cloud_ai" ] && return 1

    local input="$1"
    local context=""
    if [ -n "$SUBTRACT_LAST_OUTPUT" ]; then
        context=$(__subtract_truncate "$SUBTRACT_LAST_OUTPUT")
    fi

    local ctx_str=""
    [ -n "$context" ] && ctx_str=" Context: $context."

    local prompt="Translate to a single bash command. Output ONLY the command, nothing else. No explanation. No markdown. No code fences.${ctx_str} Input: ${input}"

    local result
    case "$cloud_ai" in
        claude)
            command -v claude &>/dev/null || [ -x "$HOME/.local/bin/claude" ] || return 1
            # timeout: prefer GNU timeout, fall back to background+kill for macOS
            if command -v timeout &>/dev/null; then
                result=$(timeout 30 claude -p "$prompt" 2>/dev/null)
            else
                local _tmp="${TMPDIR:-/tmp}/.subtract_cloud.$$"
                claude -p "$prompt" > "$_tmp" 2>/dev/null &
                local _pid=$!
                ( sleep 30; kill $_pid 2>/dev/null ) &
                local _watchdog=$!
                wait $_pid 2>/dev/null
                kill $_watchdog 2>/dev/null
                wait $_watchdog 2>/dev/null
                result=$(cat "$_tmp" 2>/dev/null)
                rm -f "$_tmp"
            fi
            ;;
        *)
            # codex, gemini: stub for when CLIs exist
            return 1
            ;;
    esac

    [ -z "$result" ] && return 1

    # strip markdown fences if model ignores the instruction
    result="${result//\`\`\`bash/}"
    result="${result//\`\`\`/}"
    result=$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "$result"
}

# --- destructive command check ---

__subtract_is_destructive() {
    local cmd="$1"
    local -a cmd_words
    __subtract_to_words cmd_words "$cmd"
    local word verb
    for word in "${cmd_words[@]}"; do
        for verb in "${SUBTRACT_DESTRUCTIVE[@]}"; do
            [ "$word" = "$verb" ] && return 0
        done
    done
    return 1
}

# --- real-time query detection ---

__subtract_is_realtime() {
    local input_lower
    input_lower=$(__subtract_lower "$1")
    local -a signals=(price stock stocks weather forecast score scores current today tonight yesterday latest breaking live trading market markets ticker)
    local -a input_words
    __subtract_to_words input_words "$input_lower"
    local word signal
    for word in "${input_words[@]}"; do
        for signal in "${signals[@]}"; do
            [ "$word" = "$signal" ] && return 0
        done
    done
    return 1
}

# --- possession/existence query detection ---

__subtract_is_possession() {
    local input_lower
    input_lower=$(__subtract_lower "$1")
    case "$input_lower" in
        "are there "*|"is there "*|"do i have "*|"do we have "*|"have i got "*|"any "*|"got any "*|"how many "*) return 0 ;;
    esac
    return 1
}

# --- kiwix: local corpus lookup for questions ---

__subtract_kiwix() {
    local query="$1"
    [ -z "$query" ] && return 1
    local encoded
    encoded=$(printf '%s' "$query" | jq -sRr @uri 2>/dev/null)
    [ -z "$encoded" ] && return 1
    # search for the article URL, then fetch the first paragraph
    local article_path
    article_path=$(curl -s --connect-timeout 1 --max-time 3 "$SUBTRACT_KIWIX/search?pattern=${encoded}&pageLength=1" 2>/dev/null \
        | sed -n 's/.*href="\(\/content\/[^"]*\)".*/\1/p' | head -1)
    [ -z "$article_path" ] && return 1
    local snippet
    snippet=$(curl -s --connect-timeout 1 --max-time 3 "$SUBTRACT_KIWIX${article_path}" 2>/dev/null \
        | sed 's/<p/\n<p/g' \
        | sed -n 's/<p[^>]*>\(.*\)<\/p>/\1/p' \
        | sed 's/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&#39;/'"'"'/g; s/&quot;/"/g' \
        | head -1)
    [ -z "$snippet" ] && return 1
    [ ${#snippet} -lt 20 ] && return 1
    echo "$snippet"
}

# --- core handler ---

__subtract_handle() {
    local input="$*"
    local cmd tier tag output result

    # onboard gate: if not yet configured, run onboard first (interactive only)
    if [ ! -f "$SUBTRACT_DIR/.onboarded" ] && [[ -t 0 ]]; then
        bash "$SUBTRACT_DIR/onboard.sh" < /dev/tty
        if [ -f "$SUBTRACT_DIR/.onboarded" ]; then
            echo "you said: $input"
            printf '[enter to run / ctrl-c to skip] '; read -r _ < /dev/tty
            __subtract_handle "$@"
        else
            echo "setup deferred. type 'reconfigure' when ready."
        fi
        return
    fi

    # --- skill management commands (before main routing chain) ---
    local input_lower
    input_lower=$(__subtract_lower "$input")
    case "$input_lower" in
        "skills")
            echo "[skill] domains:"
            ls "$SUBTRACT_SKILLS/" 2>/dev/null | grep -v '^\.' || echo "  (none)"
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "skills rebuild")
            bash "$SUBTRACT_DIR/skills-rebuild.sh"
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "skills "*)
            local domain="${input_lower#skills }"
            if [ -d "$SUBTRACT_SKILLS/$domain" ]; then
                echo "[skill] $domain:"
                ls "$SUBTRACT_SKILLS/$domain/" 2>/dev/null | sed 's/\.md$//'
            else
                echo "no skills domain: $domain"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "skill add "*)
            local skill_path="${input#* add }"
            local skill_dir="$SUBTRACT_SKILLS/$(dirname "$skill_path")"
            local skill_file="$SUBTRACT_SKILLS/${skill_path}.md"
            mkdir -p "$skill_dir"
            if [ ! -f "$skill_file" ]; then
                cat > "$skill_file" <<'TMPL'
---
aliases:
tags:
---

TITLE

Steps:
1.
TMPL
            fi
            ${EDITOR:-vi} "$skill_file"
            bash "$SUBTRACT_DIR/skills-rebuild.sh"
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "skill rm "*)
            local skill_path="${input#* rm }"
            local skill_file="$SUBTRACT_SKILLS/${skill_path}.md"
            if [ -f "$skill_file" ]; then
                echo "[DESTRUCTIVE] remove skill: $skill_path"
                printf '[y/n] '; read -r confirm
                if [ "$confirm" = "y" ]; then
                    rm "$skill_file"
                    bash "$SUBTRACT_DIR/skills-rebuild.sh"
                    echo "removed."
                else
                    echo "kept."
                fi
            else
                echo "skill not found: $skill_path"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "show "[0-9]*)
            local num="${input_lower#show }"
            if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                echo "usage: show N (where N is a number)"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
            local lastmatch="${TMPDIR:-/tmp}/.subtract-skills-lastmatch.${USER:-$$}"
            if [ -f "$lastmatch" ]; then
                local match
                match=$(sed -n "${num}p" "$lastmatch")
                if [ -n "$match" ] && [ -f "$SUBTRACT_SKILLS/${match}.md" ]; then
                    echo "[skill:${match}]"
                    awk '/^---$/{if(!fm){fm=1;next}else if(fm==1){fm=2;next}} fm==1{next} fm==0||fm==2{print}' "$SUBTRACT_SKILLS/${match}.md"
                    SUBTRACT_LAST_OUTPUT="skill lookup: $match"
                else
                    echo "no match at position $num"
                fi
            else
                echo "no recent skill search to show from"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "man "[0-9]*)
            local num="${input_lower#man }"
            if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                echo "usage: man N (select from apropos results)"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
            local lastmatch="${TMPDIR:-/tmp}/.subtract-apropos-lastmatch.${USER:-$$}"
            if [ -f "$lastmatch" ]; then
                local match
                match=$(sed -n "${num}p" "$lastmatch")
                if [ -n "$match" ]; then
                    echo "[T0.5] man $match"
                    LC_ALL=C man "$match"
                    SUBTRACT_LAST_OUTPUT="man page for '$match' (from apropos selection)"
                else
                    echo "no match at position $num"
                fi
            else
                echo "no recent apropos search to select from"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        [0-9]|[0-9][0-9])
            # bare number: select from apropos results
            local num="$input_lower"
            local lastmatch="${TMPDIR:-/tmp}/.subtract-apropos-lastmatch.${USER:-$$}"
            if [ -f "$lastmatch" ]; then
                local match
                match=$(sed -n "${num}p" "$lastmatch")
                if [ -n "$match" ]; then
                    echo "[T0.5] man $match"
                    LC_ALL=C man "$match"
                    SUBTRACT_LAST_OUTPUT="man page for '$match' (from apropos selection)"
                else
                    echo "no match at position $num"
                fi
            else
                echo "not found: $input"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "ask local "*)
            # backwards compat alias
            __subtract_handle "ask llama.cpp ${input#ask local }"
            return
            ;;
        "ask llama.cpp "*)
            local query="${input#ask llama.cpp }"
            if [ -z "$query" ]; then
                echo "usage: ask llama.cpp <your question>"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
            local answer
            answer=$(__subtract_ask_local "$query")
            if [ -n "$answer" ]; then
                echo "$answer"
            else
                echo "local model not available"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
        "ask curl "*)
            local query="${input#ask curl }"
            if [ -z "$query" ]; then
                echo "usage: ask curl <your question>"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
            local answer
            answer=$(__subtract_ask_cloud "$query")
            if [ -n "$answer" ]; then
                echo "$answer"
            else
                echo "cloud model not available"
            fi
            _SUBTRACT_FROM_HANDLER=1
            return 0
            ;;
    esac

    # --- routing chain: T0(raw) > T0(stripped) > Skills > T0.5(man) > T0.5(apropos) > Kiwix > T1 > T2 > T4 ---

    # T0 pass 1: exact lookup on raw input
    result=$(__subtract_lookup "$input")
    if [ -n "$result" ]; then
        tier="T0"
        tag="${result%%	*}"
        cmd="${result#*	}"
    fi

    # T0 pass 2: strip skills prefix, re-lookup
    # catches "how do I list my files" -> "list my files" -> T0 match
    if [ -z "$cmd" ]; then
        local stripped
        stripped=$(__subtract_strip_prefix "$input")
        if [ -n "$stripped" ]; then
            result=$(__subtract_lookup "$stripped")
            if [ -n "$result" ]; then
                tier="T0"
                tag="${result%%	*}"
                cmd="${result#*	}"
            fi
        fi
    fi

    # skills: procedural knowledge lookup (prefix match + grep index)
    if [ -z "$cmd" ]; then
        local skills_result
        skills_result=$(__subtract_skills "$input")
        if [ -n "$skills_result" ]; then
            if [[ "$skills_result" == skill:* ]]; then
                # single match: display the skill file
                local skill_path="${skills_result#skill:}"
                local skill_file="$SUBTRACT_SKILLS/${skill_path}.md"
                echo "[skill:${skill_path}]"
                # strip frontmatter, display content
                awk '/^---$/{if(!fm){fm=1;next}else if(fm==1){fm=2;next}} fm==1{next} fm==0||fm==2{print}' "$skill_file"
                SUBTRACT_LAST_OUTPUT="skill lookup: $skill_path"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            elif [[ "$skills_result" == list:* ]]; then
                # multi-match: show numbered list
                local header="${skills_result%%$'\n'*}"
                local count="${header#list:}"
                echo "[skill] ${count} matches:"
                echo "$skills_result" | tail -n +2
                echo "type: show N"
                SUBTRACT_LAST_OUTPUT="skills search returned ${count} matches"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
        fi
    fi

    # T0.5: man page routing -- input contains a real command but isn't a bare invocation
    if [ -z "$cmd" ]; then
        local man_cmd
        man_cmd=$(__subtract_manpage "$input")
        if [ -n "$man_cmd" ]; then
            echo "[T0.5] man $man_cmd"
            LC_ALL=C man "$man_cmd"
            SUBTRACT_LAST_OUTPUT="man page for '$man_cmd' (from: '$input')"
            _SUBTRACT_FROM_HANDLER=1
            return 0
        fi
    fi

    # T0.5 fallback: apropos for discovery queries ("what tool", "command for")
    if [ -z "$cmd" ]; then
        local apropos_result
        apropos_result=$(__subtract_apropos "$input")
        if [ -n "$apropos_result" ]; then
            if [[ "$apropos_result" == single:* ]]; then
                local cmd_name="${apropos_result#single:}"
                echo "[T0.5] man $cmd_name"
                man "$cmd_name"
                SUBTRACT_LAST_OUTPUT="man page for '$cmd_name' (from apropos: '$input')"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            elif [[ "$apropos_result" == list:* ]]; then
                local header="${apropos_result%%$'\n'*}"
                local count="${header#list:}"
                echo "[apropos] ${count} matches:"
                echo "$apropos_result" | tail -n +2
                echo "(man N | ask llama.cpp ... | ask curl ...)"
                SUBTRACT_LAST_OUTPUT="apropos for '$input' returned ${count} matches"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            elif [[ "$apropos_result" == none:* ]]; then
                local terms="${apropos_result#none:}"
                echo "UNIX has a tool called apropos that searches for commands."
                echo "It did not recognize: $terms"
                echo "(try different words | ask llama.cpp ... | ask curl ...)"
                SUBTRACT_LAST_OUTPUT="apropos found nothing for '$input'"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
        fi
    fi

    # kiwix: questions route to local corpus (skip real-time and possession queries)
    if [ -z "$cmd" ] && [[ "$input" == *\? ]] && ! __subtract_is_realtime "$input" && ! __subtract_is_possession "$input"; then
        local query="${input%\?}"
        local query_lower
        query_lower=$(__subtract_lower "$query")
        query_lower="${query_lower#what is }"
        query_lower="${query_lower#what are }"
        query_lower="${query_lower#who is }"
        query_lower="${query_lower#who was }"
        query_lower="${query_lower#how do i }"
        query_lower="${query_lower#how to }"
        query="$query_lower"
        local snippet
        snippet=$(__subtract_kiwix "$query")
        if [ -n "$snippet" ]; then
            echo "[kiwix] $snippet"
            SUBTRACT_LAST_OUTPUT="kiwix answer for '$input': $(__subtract_truncate "$snippet")"
            _SUBTRACT_FROM_HANDLER=1
            return 0
        fi
    fi

    # kiwix: also try bare "what is" / "who is" without trailing ?
    if [ -z "$cmd" ] && ! __subtract_is_realtime "$input"; then
        local kiwix_query=""
        input_lower=$(__subtract_lower "$input")
        case "$input_lower" in
            "what is "*) kiwix_query="${input_lower#what is }" ;;
            "what are "*) kiwix_query="${input_lower#what are }" ;;
            "who is "*) kiwix_query="${input_lower#who is }" ;;
            "who was "*) kiwix_query="${input_lower#who was }" ;;
            "when was "*) kiwix_query="${input_lower#when was }" ;;
            "when did "*) kiwix_query="${input_lower#when did }" ;;
            "where is "*) kiwix_query="${input_lower#where is }" ;;
            "define "*) kiwix_query="${input_lower#define }" ;;
            "how does "*) kiwix_query="${input_lower#how does }" ;;
            "how do "*) kiwix_query="${input_lower#how do }" ;;
            "how did "*) kiwix_query="${input_lower#how did }" ;;
        esac
        if [ -n "$kiwix_query" ]; then
            local snippet
            snippet=$(__subtract_kiwix "$kiwix_query")
            if [ -n "$snippet" ]; then
                echo "[kiwix] $snippet"
                SUBTRACT_LAST_OUTPUT="kiwix answer for '$input': $(__subtract_truncate "$snippet")"
                _SUBTRACT_FROM_HANDLER=1
                return 0
            fi
        fi
    fi

    # T1: embedding similarity (if available)
    if [ -z "$cmd" ]; then
        cmd=$(__subtract_embed "$input")
        if [ -n "$cmd" ]; then
            tier="T1"
            tag="stdout"
        fi
    fi

    # T2: local generative model (if available)
    if [ -z "$cmd" ]; then
        cmd=$(__subtract_generate "$input")
        if [ -n "$cmd" ]; then
            tier="T2"
            tag="stdout"
        fi
    fi

    # T4: cloud escalation (if configured)
    if [ -z "$cmd" ]; then
        cmd=$(__subtract_cloud "$input")
        if [ -n "$cmd" ]; then
            tier="T4"
            tag="stdout"
        fi
    fi

    if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
        if __subtract_is_destructive "$cmd"; then
            echo "[DESTRUCTIVE] $cmd"
            printf '[y/n] '; read -r confirm
            [ "$confirm" != "y" ] && { echo "aborted."; return 1; }
        else
            echo "[$tier:$tag] $cmd"
            printf '[enter/n] '; read -r confirm
            [ "$confirm" = "n" ] && return 1
        fi

        case "$tag" in
            player)
                eval "$cmd"
                ;;
            *)
                local _subtract_tmp="${TMPDIR:-/tmp}/.subtract_out.$$"
                eval "$cmd" > "$_subtract_tmp" 2>&1
                local exit_code=$?
                cat "$_subtract_tmp"
                if [ $exit_code -eq 0 ]; then
                    SUBTRACT_LAST_OUTPUT="output of '$cmd': $(__subtract_truncate "$(cat "$_subtract_tmp")")"
                fi
                rm -f "$_subtract_tmp"
                ;;
        esac
        _SUBTRACT_FROM_HANDLER=1
    else
        echo "not found: $input"
        # upgrade injection: suggest local inference on repeated intent misses
        if __subtract_is_intent "$input"; then
            __subtract_upgrade_hint "$input"
        fi
    fi
}

# command_not_found_handle (bash) and command_not_found_handler (zsh)
# defined in hooks/bash.sh and hooks/zsh.sh respectively
