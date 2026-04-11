#!/bin/bash
# Local embedding similarity match against intents.tsv corpus.
# Called by handler.sh for T1. Returns: score<TAB>matched_text<TAB>hint_command
# Requires: ollama with nomic-embed-text, pre-computed embeddings.json, jq, curl.
# Requires: ollama with nomic-embed-text, pre-computed embeddings.json, jq, curl.

SUBTRACT_DIR="${1:-.}"
EMBEDDINGS_FILE="$SUBTRACT_DIR/embeddings.json"
OLLAMA_URL="http://localhost:11434/api/embeddings"
MODEL="nomic-embed-text"

[ -f "$EMBEDDINGS_FILE" ] || exit 1

intent=$(cat)
intent="${intent%%[[:space:]]}"
[ -z "$intent" ] && exit 1

# get input embedding from ollama
input_emb=$(curl -s --connect-timeout 3 -X POST -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$MODEL" --arg prompt "$intent" '{model:$model,prompt:$prompt}')" \
    "$OLLAMA_URL" 2>/dev/null | jq -r '.embedding // empty')
[ -z "$input_emb" ] && exit 1

# compute cosine similarity in a single awk pass:
# feed input embedding as first line, then each entry as: text<TAB>command<TAB>emb_csv
{
    echo "$input_emb" | jq -r '[.[] | tostring] | join(",")'
    jq -r '.[] | [.text, .command, (.embedding | map(tostring) | join(","))] | @tsv' "$EMBEDDINGS_FILE"
} | awk -F'\t' '
NR == 1 {
    n = split($1, input_vec, ",")
    next
}
{
    text = $1
    cmd = $2
    m = split($3, emb, ",")
    dot = 0; mag_a = 0; mag_b = 0
    for (i = 1; i <= n; i++) {
        a = input_vec[i] + 0
        b = emb[i] + 0
        dot += a * b
        mag_a += a * a
        mag_b += b * b
    }
    mag_a = sqrt(mag_a)
    mag_b = sqrt(mag_b)
    if (mag_a == 0 || mag_b == 0) next
    score = dot / (mag_a * mag_b)
    if (score > best_score) {
        best_score = score
        best_text = text
        best_cmd = cmd
    }
}
END {
    if (best_score > 0) printf "%.4f\t%s\t%s\n", best_score, best_text, best_cmd
    else exit 1
}
'
