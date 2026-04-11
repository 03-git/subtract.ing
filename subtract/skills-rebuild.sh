#!/bin/bash
# rebuild the skills index from all .md files in the skills directory.
# maps normalized tokens from aliases: and tags: frontmatter to file paths.
# called by: skill add, skill rm, handler (when mtime stale).
# output: ~/.subtract/skills/.index (one line per token -> path mapping)
set -e

SUBTRACT_DIR="${SUBTRACT_DIR:-$HOME/.subtract}"
SKILLS_DIR="$SUBTRACT_DIR/skills"
INDEX_FILE="$SKILLS_DIR/.index"

if [ ! -d "$SKILLS_DIR" ]; then
    echo "no skills directory at $SKILLS_DIR"
    exit 0
fi

# stopwords: too common to be useful as search tokens
STOPWORDS="a an and are at be by do for from how i if in is it me my no not of on or so the to up us we"

# generate index: for each .md file, extract aliases and tags, normalize, map to path
: > "$INDEX_FILE"

find "$SKILLS_DIR" -name '*.md' -type f | while read -r filepath; do
    # relative path from skills dir, without .md extension
    relpath="${filepath#"$SKILLS_DIR"/}"
    relpath="${relpath%.md}"

    # extract aliases and tags lines from frontmatter
    local_aliases=""
    local_tags=""
    in_frontmatter=0
    while IFS= read -r line; do
        [ "$line" = "---" ] && { [ "$in_frontmatter" -eq 0 ] && in_frontmatter=1 && continue || break; }
        [ "$in_frontmatter" -eq 0 ] && continue
        case "$line" in
            aliases:*) local_aliases="${line#aliases:}" ;;
            tags:*) local_tags="${line#tags:}" ;;
        esac
    done < "$filepath"

    # also use the filename as a token source
    filename=$(basename "$relpath")
    filename_tokens="${filename//-/ }"

    # combine all token sources, normalize to lowercase, deduplicate
    all_text="$local_aliases, $local_tags, $filename_tokens"
    all_text=$(printf '%s' "$all_text" | tr '[:upper:]' '[:lower:]')

    # split on comma or space, trim, filter stopwords, deduplicate, write one line per token
    echo "$all_text" | tr ',' '\n' | tr ' ' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        grep -v '^$' | sort -u | while read -r token; do
            # skip stopwords and tokens under 3 chars
            [ ${#token} -lt 3 ] && continue
            case " $STOPWORDS " in *" $token "*) continue ;; esac
            printf '%s\t%s\n' "$token" "$relpath"
        done
done >> "$INDEX_FILE"

sort -o "$INDEX_FILE" "$INDEX_FILE"
echo "index rebuilt: $(wc -l < "$INDEX_FILE" | tr -d ' ') entries from $(find "$SKILLS_DIR" -name '*.md' -type f | wc -l | tr -d ' ') files"
