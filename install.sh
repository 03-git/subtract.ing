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

mkdir -p "$SUBTRACT_DIR" "$SUBTRACT_DIR/hooks" "$SUBTRACT_DIR/bin" "$SUBTRACT_DIR/pages"

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
fetch "runtime/cheatsheet.txt" "$SUBTRACT_DIR/cheatsheet.txt"
fetch "runtime/index.html" "$SUBTRACT_DIR/index.html"
fetch "runtime/hooks/bash.sh" "$SUBTRACT_DIR/hooks/bash.sh"
fetch "runtime/hooks/zsh.sh" "$SUBTRACT_DIR/hooks/zsh.sh"
chmod +x "$SUBTRACT_DIR/subtract" "$SUBTRACT_DIR/ask"

# mark as onboarded (fat lookdown.tsv makes interactive setup unnecessary)
touch "$SUBTRACT_DIR/.onboarded"

# Base lookdown.tsv (don't overwrite user's fork)
[ ! -f "$SUBTRACT_DIR/lookdown.tsv" ] && fetch "runtime/lookdown.tsv" "$SUBTRACT_DIR/lookdown.tsv"

# Browser shell (ttyd) - for new users who know browser but not terminal
TTYD_VERSION="1.7.7"
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  TTYD_BIN="ttyd.x86_64" ;;
    Linux-aarch64) TTYD_BIN="ttyd.aarch64" ;;
    Darwin-arm64)  TTYD_BIN="ttyd.darwin-arm64" ;;
    Darwin-x86_64) TTYD_BIN="ttyd.darwin-x86_64" ;;
    *) TTYD_BIN="" ;;
esac

if [ -n "$TTYD_BIN" ] && [ ! -f "$SUBTRACT_DIR/bin/ttyd" ]; then
    echo "Installing browser shell (ttyd)..."
    curl -sL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${TTYD_BIN}" \
        -o "$SUBTRACT_DIR/bin/ttyd" && chmod +x "$SUBTRACT_DIR/bin/ttyd"
fi

fetch "runtime/bin/shell-web" "$SUBTRACT_DIR/bin/shell-web"
chmod +x "$SUBTRACT_DIR/bin/shell-web"

# kiwix landing page
fetch "runtime/pages/kiwix.html" "$SUBTRACT_DIR/pages/kiwix.html" 2>/dev/null || true

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
echo "Browser shell: shell-web start"
echo "  then open http://localhost:7681"
echo ""
echo "More: https://subtract.ing"
