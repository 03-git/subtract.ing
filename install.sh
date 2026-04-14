#!/bin/bash
# subtract installer - T0 core only
# no sudo, no package managers, no system modifications
set -e

SUBTRACT_DIR="$HOME/.subtract"
BASE_URL="https://raw.githubusercontent.com/03-git/subtract.ing/main"

# Detect: are we in the repo or piped from web?
SCRIPT_DIR="$(cd "$(dirname "$0" 2>/dev/null)" && pwd 2>/dev/null)" || SCRIPT_DIR=""

if [ -d "$SCRIPT_DIR/runtime" ]; then
    MODE="local"
else
    MODE="web"
fi

mkdir -p "$SUBTRACT_DIR" "$SUBTRACT_DIR/hooks"

fetch() {
    if [ "$MODE" = "local" ]; then
        cp "$SCRIPT_DIR/$1" "$2"
    else
        curl -sL "$BASE_URL/$1" > "$2"
    fi
}

# T0 core
fetch "runtime/handler.sh" "$SUBTRACT_DIR/handler.sh"
fetch "runtime/subtract" "$SUBTRACT_DIR/subtract"
fetch "runtime/ask" "$SUBTRACT_DIR/ask"
fetch "runtime/hooks/bash.sh" "$SUBTRACT_DIR/hooks/bash.sh"
fetch "runtime/hooks/zsh.sh" "$SUBTRACT_DIR/hooks/zsh.sh"
chmod +x "$SUBTRACT_DIR/subtract" "$SUBTRACT_DIR/ask"

# Base lookup.tsv (don't overwrite user's fork)
[ ! -f "$SUBTRACT_DIR/lookup.tsv" ] && fetch "runtime/lookup.tsv" "$SUBTRACT_DIR/lookup.tsv"

# Shell integration
BASH_LINE='[ -f ~/.subtract/hooks/bash.sh ] && source ~/.subtract/hooks/bash.sh'
ZSH_LINE='[ -f ~/.subtract/hooks/zsh.sh ] && source ~/.subtract/hooks/zsh.sh'
PATH_LINE='export PATH="$HOME/.subtract:$PATH"'

if [ -f ~/.bashrc ] && ! grep -qF 'subtract/hooks' ~/.bashrc; then
    echo -e "\n# subtract\n$PATH_LINE\n$BASH_LINE" >> ~/.bashrc
fi

if [ -f ~/.zshrc ] && ! grep -qF 'subtract/hooks' ~/.zshrc; then
    echo -e "\n# subtract\n$PATH_LINE\n$ZSH_LINE" >> ~/.zshrc
fi

echo ""
echo "subtract installed."
echo ""
echo "Open a new terminal, then try:"
echo "  show my files"
echo "  ask \"what compresses files?\""
echo ""
echo "More: https://subtract.ing"
