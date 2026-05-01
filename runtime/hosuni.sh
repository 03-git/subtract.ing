#!/usr/bin/env bash
# hosuni — tool-use daemon for local inference
# listens on a port via nc. receives JSON, checks lookdown,
# routes inference through squared, parses tool calls,
# executes, loops, logs. pure bash + jq + curl.
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
LOOKDOWN_NODE="$SUBTRACT_DIR/lookdown.$(hostname).tsv"
LOOKDOWN_UNIVERSAL="$SUBTRACT_DIR/lookdown.universal.tsv"
TOOLS_FILE="$HOSUNI_DIR/tools.tsv"
LOG_DIR="$SUBTRACT_DIR/log"
DAEMON_LOG="$HOME/human/sessions/hosuni.log"
MAX_TURNS=20
TOOL_TIMEOUT=300

SOUL_FILE="$HOME/subtract.ing/SOUL.txt"
SYSTEM_MSG=$(cat "$SOUL_FILE" 2>/dev/null || echo "")

mkdir -p "$LOG_DIR" "$HOSUNI_DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_daemon() { printf "[%s] %s\n" "$(ts)" "$1" >> "$DAEMON_LOG"; }

log_session() {
    local channel="$1" role="$2" content="$3"
    local safe; safe=$(printf '%s' "$content" | tr '\t\n' '  ' | cut -c1-500)
    printf "%s\t%s\t%s\n" "$(ts)" "$role" "$safe" >> "$LOG_DIR/hosuni-${channel}.log"
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
                $pattern) echo "$cmd"; return 0 ;;
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

    log_daemon "tool: $name (arg: $(echo "$input" | head -c 100))"
    local output
    output=$(HOSUNI_ARG="$input" perl -e 'alarm shift; exec @ARGV' "$TOOL_TIMEOUT" bash -c "$template 2>/dev/null" 2>/dev/null | head -c 4096) || true
    output=${output:-"no results"}
    echo "$output"
}

# --- inference ---

call_inference() {
    local messages="$1" tools="$2"
    local payload
    if [ "$tools" = "[]" ]; then
        payload=$(jq -n --argjson msgs "$messages" \
            '{messages: $msgs, max_tokens: 2048, stream: false}')
    else
        payload=$(jq -n --argjson msgs "$messages" --argjson tools "$tools" \
            '{messages: $msgs, max_tokens: 2048, stream: false, tools: $tools}')
    fi

    log_daemon "payload: $(echo "$payload" | jq -c '{msg_count: (.messages | length), has_tools: (.tools != null), first_role: .messages[0].role}' 2>/dev/null)"
    local response
    if [ "$INFERENCE_HOST" != "localhost" ] && [ -n "$INFERENCE_HOST" ]; then
        response=$(echo "$payload" | ssh -o ConnectTimeout=5 "$INFERENCE_HOST" \
            "curl -s -m 300 -X POST http://localhost:${INFERENCE_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d @-" 2>/dev/null)
    else
        response=$(curl -s --connect-timeout 10 -m 300 \
            -X POST "http://localhost:${INFERENCE_PORT}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)
    fi

    echo "$response"
}

fallback_claude() {
    local prompt="$1"
    claude -p -c "$prompt" 2>/dev/null || true
}

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

    [ -z "$input" ] && { echo '{"error":"no input"}'; return; }

    log_daemon "[${channel}] input: $input"
    log_session "$channel" "Q" "$input"

    # T0: lookdown check
    local lookdown_result
    if lookdown_result=$(check_lookdown "$input"); then
        log_daemon "[${channel}] lookdown hit: $lookdown_result"
        local output
        output=$(eval "$lookdown_result" 2>&1) || true
        [ -z "$output" ] && output="ok"
        log_session "$channel" "A" "$output"
        jq -n --arg r "$output" --arg s "lookdown" \
            '{response: $r, source: $s}'
        return
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
        local tool_calls; tool_calls=$(echo "$response" | jq -r '.choices[0].message.tool_calls // empty' 2>/dev/null)
        local finish; finish=$(echo "$response" | jq -r '.choices[0].finish_reason // empty' 2>/dev/null)

        # if local failed entirely, cloud fallback
        if [ -z "$content" ] && [ -z "$tool_calls" ] && [ "$round" -eq 1 ]; then
            log_daemon "[${channel}] local empty, falling back to cloud"
            content=$(fallback_claude "$user_content")
            source="cloud"
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
            jq -n '{error:"no model available"}'
            return
        fi

        # if tool calls present, execute them
        if [ -n "$tool_calls" ] && [ "$tool_calls" != "null" ]; then
            # append assistant message with tool calls
            local assistant_msg; assistant_msg=$(echo "$response" | jq '.choices[0].message')
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
        if [ -n "$RESEARCH_PORT" ] && [ "$round" -gt 1 ]; then
            log_daemon "[${channel}] handing off to research model on port $RESEARCH_PORT"
            local saved_port="$INFERENCE_PORT" saved_host="$INFERENCE_HOST"
            INFERENCE_PORT="$RESEARCH_PORT"
            [ -n "$RESEARCH_HOST" ] && INFERENCE_HOST="$RESEARCH_HOST"
            local research_resp; research_resp=$(call_inference "$messages" "[]")
            INFERENCE_PORT="$saved_port"
            INFERENCE_HOST="$saved_host"
            local research_content; research_content=$(echo "$research_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            if [ -n "$research_content" ]; then
                content="$research_content"
                source="research"
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
log_daemon "inference: ${INFERENCE_HOST}:${INFERENCE_PORT}"
log_daemon "lookdown: $LOOKDOWN_NODE $LOOKDOWN_UNIVERSAL"
log_daemon "tools: $TOOLS_FILE"

# stdin/stdout mode: read JSON request, write JSON response
# usage: echo '{"input":"hello","channel":"test"}' | hosuni.sh
#        or spawned by hosuni-discord.ts per message

request=$(cat)
log_daemon "raw request: $(echo "$request" | head -c 200)"
handle_request "$request"
