#!/bin/bash
# subtract installer
# no sudo, no package managers, no system modifications
set -e

SUBTRACT_DIR="$HOME/.subtract"
BASE_URL="https://raw.githubusercontent.com/03-git/subtract.ing/main"

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

fetch "runtime/subtract.sh" "$SUBTRACT_DIR/subtract.sh"
fetch "runtime/hooks/bash.sh" "$SUBTRACT_DIR/hooks/bash.sh"
fetch "runtime/hooks/zsh.sh" "$SUBTRACT_DIR/hooks/zsh.sh"
[ ! -f "$SUBTRACT_DIR/lookdown.universal.tsv" ] && fetch "lookdown.universal.tsv" "$SUBTRACT_DIR/lookdown.universal.tsv"

BASH_LINE='[ -f ~/.subtract/hooks/bash.sh ] && source ~/.subtract/hooks/bash.sh'
ZSH_LINE='[ -f ~/.subtract/hooks/zsh.sh ] && source ~/.subtract/hooks/zsh.sh'

if [ -f ~/.bashrc ] && ! grep -qF 'subtract/hooks' ~/.bashrc; then
    echo -e "\n# subtract\n$BASH_LINE" >> ~/.bashrc
fi

command -v zsh >/dev/null 2>&1 && [ ! -f ~/.zshrc ] && touch ~/.zshrc
if [ -f ~/.zshrc ] && ! grep -qF 'subtract/hooks' ~/.zshrc; then
    echo -e "\n# subtract\n$ZSH_LINE" >> ~/.zshrc
fi

echo "subtract installed. open a new terminal, then type intent."
