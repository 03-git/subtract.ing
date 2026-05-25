#!/usr/bin/env bash
# hosuni — tool-use daemon for local inference
# listens on a port via nc. receives JSON, checks lookdown,
# routes inference through parsimony (coproc via named pipes),
# parses tool calls, executes, loops, logs. pure bash + jq.
# falls back to curl if parsimony pipes not present.
#
# run:   hosuni.sh [port]
# call:  echo '{"input":"list files","channel":"terminal"}' | nc localhost 8091

set -euo pipefail

export PATH="$HOME/.subtract/bin:$HOME/.subtract:$PATH"

SUBTRACT_DIR="${SUBTRACT_DIR:-$HOME/.subtract}"
HOSUNI_DIR="${HOSUNI_DIR:-$HOME/.hosuni}"
INFERENCE_HOST=$(cat "$SUBTRACT_DIR/inference_host" 2>/dev/null || echo "localhost")
INFERENCE_PORT=$(cat "$SUBTRACT_DIR/inference_port" 2>/dev/null || echo "8085")
RESEARCH_PORT=$(cat "$SUBTRACT_DIR/research_port" 2>/dev/null || echo "")
RESEARCH_HOST=$(cat "$SUBTRACT_DIR/research_host" 2>/dev/null || echo "")
PARSIMONY_IN="$SUBTRACT_DIR/.parsimony.in"
PARSIMONY_OUT="$SUBTRACT_DIR/.parsimony.out"
PARSIMONY_LOCK="$SUBTRACT_DIR/.parsimony.lock"
LOOKDOWN_NODE="$SUBTRACT_DIR/lookdown.$(hostname).tsv"
LOOKDOWN_UNIVERSAL="$SUBTRACT_DIR/lookdown.universal.tsv"
TOOLS_FILE="$HOSUNI_DIR/tools.tsv"
LOG_DIR="$SUBTRACT_DIR/log"
DAEMON_LOG="$HOME/.subtract/log/hosuni.log"
MAX_TURNS=20
TOOL_TIMEOUT=300

SOUL_FILE="$HOME/.subtract/SOUL.txt"
SYSTEM_MSG=$(cat "$SOUL_FILE" 2>/dev/null || echo "")

mkdir -p "$LOG_DIR" "$HOSUNI_DIR"

_sleep_fifo="${TMPDIR:-/tmp}/.hosuni_sleep.$$"
mkfifo "$_sleep_fifo" && exec {_sleep_fd}<>"$_sleep_fifo" && rm "$_sleep_fifo"
_bsleep() { read -t "${1:-0.5}" -u $_sleep_fd -r _ 2>/dev/null || :; }

ts() { TZ=UTC0 printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1; }

log_daemon() { printf "[%s] %s\n" "$(ts)" "$1" >> "$DAEMON_LOG"; }

log_session() {
    local channel="$1" role="$2" content="$3"
    local safe; safe=$(printf '%s' "$content" | tr '\t\n' '  ' | cut -c1-500)
    printf "%s\t%s\t%s\n" "$(ts)" "$role" "$safe" >> "$LOG_DIR/hosuni-${channel}.log"
}

clean_response() {
    local text="$1"
    [[ "$text" == *"<channel|>"* ]] && text="${text#*"<channel|>"}"
    text="${text%%"<|im_end|>"*}"
    text="${text%%"<|im_start|>"*}"
    text="${text%%"<|endoftext|>"*}"
    echo "$text"
}

# --- lookdown check ---

check_lookdown() {
    local input; input=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    local line pattern cmd
    for file in "$LOOKDOWN_NODE" "$LOOKDOWN_UNIVERSAL"; do
        [ -f "$file" ] || continue
        while IFS=$'\t' read -r pattern cmd rest; do
            [ -z "$pattern" ] && continue
            [[ "$pattern" == \#* ]] && continue
            # glob match
            case "$input" in
                $pattern) if [[ "$cmd" == "[player]" || "$cmd" == "[exec]" ]]; then echo "$rest"; else echo "$cmd"; fi; return 0 ;;
            esac
        done < "$file"
    done
    return 1
}

# --- tool loading ---

load_tools() {
    local tools="[]"
    [ -f "$TOOLS_FILE" ] || { echo "$tools"; return; }
    while IFS=$'\t' read -r name desc template; do
        [ -z "$name" ] && continue
        [[ "$name" == \#* ]] && continue
        # check if the command exists on this system
        local bin; bin=$(echo "$template" | awk '{print $1}')
        command -v "$bin" >/dev/null 2>&1 || continue
        tools=$(echo "$tools" | jq --arg n "$name" --arg d "$desc" \
            '. + [{"type":"function","function":{"name":$n,"description":$d,"parameters":{"type":"object","properties":{"input":{"type":"string"}}}}}]')
    done < "$TOOLS_FILE"
    echo "$tools"
}

# --- tool execution ---

execute_tool() {
    local name="$1" args="$2"
    local template
    template=$(awk -F'\t' -v n="$name" '$1==n {print $3}' "$TOOLS_FILE" 2>/dev/null)
    [ -z "$template" ] && { echo "tool not found: $name"; return 1; }

    local input; input=$(echo "$args" | jq -r '.input // empty')
    input="${input/#\~/$HOME}"

    log_daemon "tool: $name (arg: $(echo "$input" | head -c 100))"
    local output
    output=$(HOSUNI_ARG="$input" perl -e 'alarm shift; exec @ARGV' "$TOOL_TIMEOUT" bash -c "$template 2>/dev/null" 2>/dev/null | head -c 65536) || true
    output=${output:-"no results"}
    echo "$output"
}

# --- streaming inference ---

call_inference_streaming() {
    local messages="$1" content_file="$2"
    local payload
    payload=$(jq -n --argjson msgs "$messages" \
        '{messages: $msgs, max_tokens: 262144, stream: true, stop: ["<|im_end|>","<|endoftext|>","<|im_start|>"]}')

    log_daemon "streaming payload: $(echo "$payload" | jq -c '{msg_count: (.messages | length), first_role: .messages[0].role}' 2>/dev/null)"

    if [ -p "$PARSIMONY_IN" ] && [ -p "$PARSIMONY_OUT" ]; then
        local compact; compact=$(echo "$payload" | jq -c .)
        local _lock_tries=0
        while ! mkdir "$PARSIMONY_LOCK" 2>/dev/null; do
            _lock_tries=$((_lock_tries + 1))
            [ "$_lock_tries" -ge 60 ] && {
                printf 'data: {"choices":[{"delta":{"content":"(lock timeout)"},"finish_reason":null}]}\n'
                printf 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n'
                printf 'data: [DONE]\n'
                printf '(lock timeout)' > "$content_file"
                return
            }
            _bsleep
        done
        trap 'rmdir "$PARSIMONY_LOCK" 2>/dev/null' RETURN

        printf '%s\n' "$compact" > "$PARSIMONY_IN"

        local full_content=""
        exec 3< "$PARSIMONY_OUT"
        while IFS= read -r line <&3; do
            printf '%s\n' "$line"
            [[ "$line" == "data: [DONE]" ]] && break
            local delta
            delta=$(echo "${line#data: }" | jq -r '.choices[0].delta.content // empty' 2>/dev/null) || true
            [ -n "$delta" ] && full_content+="$delta"
        done
        exec 3<&-
        printf '%s' "$full_content" > "$content_file"
    else
        local full_content=""
        while IFS= read -r line; do
            printf '%s\n' "$line"
            [[ "$line" == "data: [DONE]" ]] && break
            local delta
            delta=$(echo "${line#data: }" | jq -r '.choices[0].delta.content // empty' 2>/dev/null) || true
            [ -n "$delta" ] && full_content+="$delta"
        done < <(curl -sN --connect-timeout 10 -m 600 \
            -X POST "http://${INFERENCE_HOST}:${INFERENCE_PORT}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$(echo "$payload" | jq -c .)" 2>/dev/null)
        printf '%s' "$full_content" > "$content_file"
    fi
}

# --- inference ---

call_inference() {
    local messages="$1" tools="$2"
    local payload
    if [ "$tools" = "[]" ]; then
        payload=$(jq -n --argjson msgs "$messages" \
            '{messages: $msgs, max_tokens: 262144, stream: false, stop: ["<|im_end|>","<|endoftext|>","<|im_start|>"]}')
    else
        payload=$(jq -n --argjson msgs "$messages" --argjson tools "$tools" \
            '{messages: $msgs, max_tokens: 262144, stream: false, tools: $tools, stop: ["<|im_end|>","<|endoftext|>","<|im_start|>"]}')
    fi

    log_daemon "payload: $(echo "$payload" | jq -c '{msg_count: (.messages | length), has_tools: (.tools != null), first_role: .messages[0].role}' 2>/dev/null)"
    local response
    if [ -p "$PARSIMONY_IN" ] && [ -p "$PARSIMONY_OUT" ]; then
        local compact; compact=$(echo "$payload" | jq -c .)
        local _lock_tries=0
        while ! mkdir "$PARSIMONY_LOCK" 2>/dev/null; do
            _lock_tries=$((_lock_tries + 1))
            [ "$_lock_tries" -ge 60 ] && { response='{"error":"inference lock timeout"}'; break; }
            _bsleep
        done
        if [ -d "$PARSIMONY_LOCK" ]; then
            trap 'rmdir "$PARSIMONY_LOCK" 2>/dev/null' RETURN
            printf '%s\n' "$compact" > "$PARSIMONY_IN"
            read -r response < "$PARSIMONY_OUT"
        fi
    else
        response=$(curl -s --connect-timeout 10 -m 300 \
            -X POST "http://${INFERENCE_HOST}:${INFERENCE_PORT}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null | tr '\n' ' ')
    fi

    echo "$response"
}

# fallback_claude disabled — claude -p is metered after 2026-06-15
# fallback_claude() {
#     local prompt="$1"
#     claude -p "$prompt" 2>/dev/null || true
# }

# --- conversation state ---

get_messages_file() { echo "$LOG_DIR/hosuni-${1}.messages.json"; }

load_messages() {
    local file; file=$(get_messages_file "$1")
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo "[]"
    fi
}

save_messages() {
    local channel="$1" messages="$2"
    # truncate to last MAX_TURNS * 2 entries
    local count; count=$(echo "$messages" | jq 'length')
    if [ "$count" -gt $((MAX_TURNS * 2)) ]; then
        messages=$(echo "$messages" | jq ".[-$((MAX_TURNS * 2)):]")
    fi
    echo "$messages" > "$(get_messages_file "$channel")"
}

# --- core loop ---

handle_request() {
    local request="$1"
    local input channel context
    input=$(echo "$request" | jq -r '.input // empty')
    channel=$(echo "$request" | jq -r '.channel // "default"')
    context=$(echo "$request" | jq -r '.context // empty')

    local stream
    stream=$(echo "$request" | jq -r '.stream // false')

    [ -z "$input" ] && { echo '{"error":"no input"}'; return; }

    log_daemon "[${channel}] input: $input (stream=$stream)"
    log_session "$channel" "Q" "$input"

    # T0: lookdown check (skip for conversational input)
    if [ "${#input}" -lt 120 ]; then
        local lookdown_result
        if lookdown_result=$(check_lookdown "$input"); then
            log_daemon "[${channel}] lookdown hit: $lookdown_result"
            local output
            output=$(eval "$lookdown_result" 2>&1) || true
            [ -z "$output" ] && output="ok"
            log_session "$channel" "A" "$output"
            if [ "$stream" = "true" ]; then
                local sse_esc
                sse_esc=$(printf '%s' "$output" | jq -Rsc '.')
                printf 'data: {"choices":[{"delta":{"content":%s},"finish_reason":null}]}\n' "$sse_esc"
                printf 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n'
                printf 'data: [DONE]\n'
            else
                jq -n --arg r "$output" --arg s "lookdown" \
                    '{response: $r, source: $s}'
            fi
            return
        fi
    fi

    # --- pre-inference context enrichment (no model decision) ---

    # YouTube URLs: fetch transcript before inference
    local yt_ids=""
    yt_ids=$(printf '%s' "$input" | grep -oE '(youtube\.com/watch\?v=|youtu\.be/|youtube\.com/shorts/)([A-Za-z0-9_-]{11})' | grep -oE '[A-Za-z0-9_-]{11}$' || true)
    if [ -n "$yt_ids" ]; then
        local yt_context=""
        for vid in $yt_ids; do
            local url="https://www.youtube.com/watch?v=${vid}"
            log_daemon "[${channel}] fetching transcript for $vid"
            local transcript
            transcript=$("$HOSUNI_DIR/bin/yt-transcript" "$url" 2>/dev/null | head -c 16384) || true
            if [ -n "$transcript" ]; then
                local title
                title=$(yt-dlp --quiet --print title "$url" 2>/dev/null | head -1) || true
                yt_context="${yt_context}

--- YouTube: ${title:-$vid} ---
${transcript}"
                log_daemon "[${channel}] transcript fetched for $vid (${#transcript} chars)"
            else
                log_daemon "[${channel}] no transcript for $vid"
            fi
        done
        if [ -n "$yt_context" ]; then
            local user_text; user_text=$(printf '%s' "$input" | sed 's|https\?://[^ ]*||g' | tr -s ' ' | sed 's/^ //;s/ $//')
            [ -z "$user_text" ] && user_text="Analyze this video."
            context="${context:+$context

}The transcript has been fetched. Do not attempt to access the URL.${yt_context}"
        fi
    fi

    # Web search triggers: fetch results before inference
    local search_query="" _lower
    _lower=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
    case "$_lower" in
        *"search for "*)        search_query="${input##*[Ss]earch [Ff]or }" ;;
        *"latest on "*)         search_query="${input##*[Ll]atest [Oo]n }" ;;
        *"current status of "*) search_query="${input##*[Ss]tatus [Oo]f }" ;;
        *"latest news on "*)    search_query="${input##*[Nn]ews [Oo]n }" ;;
        *"latest news about "*) search_query="${input##*[Aa]bout }" ;;
    esac
    if [ -n "$search_query" ]; then
        log_daemon "[${channel}] pre-search: $search_query"
        local search_results
        search_results=$(HOSUNI_ARG="$search_query" bash -c "$(awk -F'\t' '$1=="web_search" {print $3}' "$TOOLS_FILE")" 2>/dev/null | head -c 4096) || true
        if [ -n "$search_results" ]; then
            context="${context:+$context

}Web search results for: ${search_query}
${search_results}"
            log_daemon "[${channel}] search results: ${#search_results} chars"
        fi
    fi

    # load conversation state
    local messages; messages=$(load_messages "$channel")
    # inject system prompt as first message on first turn
    local user_content="$input"
    local msg_count; msg_count=$(echo "$messages" | jq 'length')
    if [ "$msg_count" -eq 0 ] && [ -n "$SYSTEM_MSG" ]; then
        messages=$(echo "$messages" | jq --arg sys "$SYSTEM_MSG" \
            '[{"role":"system","content":$sys}]')
    fi
    [ -n "$context" ] && user_content="${user_content}

Context:
${context}"
    messages=$(echo "$messages" | jq --arg content "$user_content" \
        '. + [{"role":"user","content":$content}]')

    # enriched context path: skip 7B, send to research model (Gemma) or cloud
    if [ -n "$search_query" ] || [ -n "$yt_ids" ]; then
        log_daemon "[${channel}] enriched context, routing to research model"
        if [ -n "$RESEARCH_PORT" ]; then
            local enriched_payload
            enriched_payload=$(jq -n --argjson msgs "$messages" \
                '{messages: $msgs, max_tokens: 262144, stream: false, stop: ["<|im_end|>","<|endoftext|>","<|im_start|>"]}')
            local enriched_response
            enriched_response=$(curl -s --connect-timeout 10 -m 120 \
                -X POST "http://${RESEARCH_HOST:-${INFERENCE_HOST}}:${RESEARCH_PORT}/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$enriched_payload" 2>/dev/null)
            local content; content=$(echo "$enriched_response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            content=$(clean_response "$content")
            if [ -n "$content" ]; then
                messages=$(echo "$messages" | jq --arg c "$content" \
                    '. + [{"role":"assistant","content":$c}]')
                save_messages "$channel" "$messages"
                log_session "$channel" "A" "$content"
                log_daemon "[${channel}] [research] reply: $(echo "$content" | head -c 200)"
                jq -n --arg r "$content" --arg s "research" \
                    '{response: $r, source: $s}'
                return
            fi
        fi
        log_daemon "[${channel}] no research port, falling through to parsimony pipes"
    fi

    # streaming path: bypass tool loop, stream directly
    if [ "$stream" = "true" ]; then
        local content_file; content_file=$(mktemp)
        call_inference_streaming "$messages" "$content_file"
        local content; content=$(cat "$content_file" 2>/dev/null)
        rm -f "$content_file"
        content=$(clean_response "$content")
        if [ -n "$content" ]; then
            messages=$(echo "$messages" | jq --arg c "$content" \
                '. + [{"role":"assistant","content":$c}]')
            save_messages "$channel" "$messages"
            log_session "$channel" "A" "$content"
            log_daemon "[${channel}] [stream] reply: $(echo "$content" | head -c 200)"
        fi
        return
    fi

    # load tools
    local tools; tools=$(load_tools)

    # inference loop (tool calls may require multiple turns)
    local max_rounds=5 round=0
    local source="local"
    while [ "$round" -lt "$max_rounds" ]; do
        round=$((round + 1))

        local response; response=$(call_inference "$messages" "$tools")
        log_daemon "[${channel}] round $round raw: $(echo "$response" | jq -c '.choices[0].message | {content: (.content // null), tool_calls: (.tool_calls // null) | length, finish: .finish_reason}' 2>/dev/null || echo 'PARSE_FAIL')"

        # check if inference returned anything
        local content; content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        content=$(clean_response "$content")
        local tool_calls; tool_calls=$(echo "$response" | jq -r '.choices[0].message.tool_calls // empty' 2>/dev/null)
        local finish; finish=$(echo "$response" | jq -r '.choices[0].finish_reason // empty' 2>/dev/null)

        # if local failed entirely, cloud fallback
        if [ -z "$content" ] && [ -z "$tool_calls" ] && [ "$round" -eq 1 ]; then
            log_daemon "[${channel}] local empty, no cloud fallback"
            jq -n '{error:"no model available"}'
            return
        fi

        # if tool calls present, execute them
        if [ -n "$tool_calls" ] && [ "$tool_calls" != "null" ]; then
            # append assistant message with tool calls (strip reasoning_content, normalize empty content to null)
            local assistant_msg; assistant_msg=$(echo "$response" | jq '.choices[0].message | del(.reasoning_content) | if .content == "" then .content = null else . end')
            messages=$(echo "$messages" | jq --argjson msg "$assistant_msg" '. + [$msg]')

            # execute each tool call
            local n_calls; n_calls=$(echo "$tool_calls" | jq 'length')
            local i=0
            while [ "$i" -lt "$n_calls" ]; do
                local tc_id; tc_id=$(echo "$tool_calls" | jq -r ".[$i].id")
                local tc_name; tc_name=$(echo "$tool_calls" | jq -r ".[$i].function.name")
                local tc_args; tc_args=$(echo "$tool_calls" | jq -r ".[$i].function.arguments")

                log_daemon "[${channel}] tool call: $tc_name($tc_args)"
                local tc_result; tc_result=$(execute_tool "$tc_name" "$tc_args")
                log_daemon "[${channel}] tool result: $(echo "$tc_result" | head -c 200)"

                # append tool result
                messages=$(echo "$messages" | jq \
                    --arg id "$tc_id" \
                    --arg content "$tc_result" \
                    '. + [{"role":"tool","tool_call_id":$id,"content":$content}]')

                i=$((i + 1))
            done
            # loop back to inference with tool results
            continue
        fi

        # no tool calls — either we have a final response, or model returned nothing
        # if research port available and tools were used, hand off to research model
        # timeout: 20s — if research model is slow, use the primary model's answer
        if [ -n "$RESEARCH_PORT" ] && [ "$round" -gt 1 ]; then
            log_daemon "[${channel}] handing off to research model on port $RESEARCH_PORT (20s timeout)"
            local saved_port="$INFERENCE_PORT" saved_host="$INFERENCE_HOST"
            INFERENCE_PORT="$RESEARCH_PORT"
            [ -n "$RESEARCH_HOST" ] && INFERENCE_HOST="$RESEARCH_HOST"
            local research_resp _research_tmp="${TMPDIR:-/tmp}/.hosuni_research.$$"
            ( call_inference "$messages" "[]" > "$_research_tmp" 2>/dev/null ) &
            local _rpid=$!
            ( _bsleep 20; kill "$_rpid" 2>/dev/null ) &
            local _rwdog=$!
            wait "$_rpid" 2>/dev/null || true
            kill "$_rwdog" 2>/dev/null || true; wait "$_rwdog" 2>/dev/null || true
            research_resp=$(cat "$_research_tmp" 2>/dev/null) || true
            rm -f "$_research_tmp"
            INFERENCE_PORT="$saved_port"
            INFERENCE_HOST="$saved_host"
            local research_content; research_content=$(echo "$research_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            research_content=$(clean_response "$research_content")
            if [ -n "$research_content" ]; then
                content="$research_content"
                source="research"
            else
                log_daemon "[${channel}] research timeout/empty, using primary answer"
            fi
        fi

        if [ -n "$content" ]; then
            messages=$(echo "$messages" | jq --arg c "$content" \
                '. + [{"role":"assistant","content":$c}]')
            save_messages "$channel" "$messages"
            log_session "$channel" "A" "$content"
            log_daemon "[${channel}] [$source] reply: $(echo "$content" | head -c 200)"
            jq -n --arg r "$content" --arg s "$source" \
                '{response: $r, source: $s}'
            return
        fi

        break
    done

    jq -n '{error:"no response after tool loop"}'
}

# --- listener ---

log_daemon "hosuni starting (stdin/stdout mode)"
if [ -p "$PARSIMONY_IN" ] && [ -p "$PARSIMONY_OUT" ]; then
    log_daemon "inference: parsimony (pipes)"
else
    log_daemon "inference: ${INFERENCE_HOST}:${INFERENCE_PORT} (curl)"
fi
log_daemon "lookdown: $LOOKDOWN_NODE $LOOKDOWN_UNIVERSAL"
log_daemon "tools: $TOOLS_FILE"

# stdin/stdout mode: read JSON request, write JSON response
# usage: echo '{"input":"hello","channel":"test"}' | hosuni.sh
#        or spawned by hosuni-discord.ts per message

request=$(cat)
log_daemon "raw request: $(echo "$request" | head -c 200)"
handle_request "$request"
