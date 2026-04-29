#!/usr/bin/env bash
# routing-table-test.sh — dispatch five prompts through hosuni, log tool use
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPTS="$SCRIPT_DIR/routing-table-prompts.tsv"
HOSUNI="$SCRIPT_DIR/hosuni.sh"
RESULTS_DIR="$HOME/.subtract/log/routing-table-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RESULTS_DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "=== routing table test $(ts) ==="
echo "results: $RESULTS_DIR"
echo ""

tail -n+2 "$PROMPTS" | while IFS=$'\t' read -r name prompt; do
    [ -z "$name" ] && continue
    echo "--- $name ---"
    outfile="$RESULTS_DIR/${name}.json"
    logfile="$RESULTS_DIR/${name}.log"

    request=$(jq -n --arg input "$prompt" --arg channel "routing-test-${name}" \
        '{input: $input, channel: $channel}')

    echo "$request" | bash "$HOSUNI" > "$outfile" 2>"$logfile"

    source=$(jq -r '.source // "unknown"' "$outfile" 2>/dev/null || echo "error")
    response=$(jq -r '.response // .error // "no response"' "$outfile" 2>/dev/null || echo "parse error")

    # check daemon log for tool calls from this channel
    daemon_log="$HOME/human/sessions/hosuni.log"
    tool_calls=""
    if [ -f "$daemon_log" ]; then
        tool_calls=$(grep "routing-test-${name}" "$daemon_log" | grep "tool:" | tail -5 || true)
    fi
    channel_log="$HOME/.subtract/log/hosuni-routing-test-${name}.log"
    if [ -f "$channel_log" ]; then
        tool_calls="$tool_calls$(grep "tool" "$channel_log" 2>/dev/null || true)"
    fi

    # summary row
    used_curl="no"
    echo "$response" | grep -qi "curl" && used_curl="mentioned"
    [ -n "$tool_calls" ] && echo "$tool_calls" | grep -q "curl" && used_curl="executed"

    printf "%s\t%s\t%s\t%s\n" "$(ts)" "$name" "$source" "curl=$used_curl" >> "$RESULTS_DIR/summary.tsv"
    echo "  source=$source curl=$used_curl"
    echo "  response: $(echo "$response" | head -c 200)"
    echo ""
done

echo "=== summary ==="
cat "$RESULTS_DIR/summary.tsv"
echo ""
echo "full results: $RESULTS_DIR"
