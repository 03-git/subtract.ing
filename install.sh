#!/bin/bash
# subtract installer - works from curl pipe OR cloned repo
# no sudo, no package managers, no system modifications
set -e

SUBTRACT_DIR="$HOME/.subtract"
BASE_URL="https://raw.githubusercontent.com/03-git/subtract.ing/main"

# Detect: are we in the repo or piped from web?
SCRIPT_DIR="$(cd "$(dirname "$0" 2>/dev/null)" && pwd 2>/dev/null)" || SCRIPT_DIR=""

if [ -d "$SCRIPT_DIR/subtract" ]; then
    MODE="local"
else
    MODE="web"
fi

mkdir -p "$SUBTRACT_DIR" "$SUBTRACT_DIR/hooks"

fetch() {
    local file="$1"
    local dest="$2"
    if [ "$MODE" = "local" ]; then
        cp "$SCRIPT_DIR/$file" "$dest"
    else
        curl -sL "$BASE_URL/$file" > "$dest"
    fi
}

fetch_exec() {
    fetch "$1" "$2"
    chmod +x "$2"
}

# Core runtime
fetch "subtract/handler.sh" "$SUBTRACT_DIR/handler.sh"
fetch_exec "subtract/subtract" "$SUBTRACT_DIR/subtract"
fetch "subtract/hooks/bash.sh" "$SUBTRACT_DIR/hooks/bash.sh"
fetch "subtract/hooks/zsh.sh" "$SUBTRACT_DIR/hooks/zsh.sh"
fetch "subtract/motd" "$SUBTRACT_DIR/motd"
fetch "subtract/about" "$SUBTRACT_DIR/about"
fetch_exec "subtract/onboard.sh" "$SUBTRACT_DIR/onboard.sh"
fetch_exec "subtract/embed_match.sh" "$SUBTRACT_DIR/embed_match.sh"
fetch_exec "subtract/skills-rebuild.sh" "$SUBTRACT_DIR/skills-rebuild.sh"

# Signing scripts (optional)
fetch_exec "subtract/sign-lookup.sh" "$SUBTRACT_DIR/sign-lookup.sh" 2>/dev/null || true
fetch_exec "subtract/verify-lookup.sh" "$SUBTRACT_DIR/verify-lookup.sh" 2>/dev/null || true

# lookup.tsv: don't overwrite user edits
if [ ! -f "$SUBTRACT_DIR/lookup.tsv" ]; then
    fetch "subtract/lookup.tsv" "$SUBTRACT_DIR/lookup.tsv"
fi

# Skills: only in local mode (120+ files, can't curl individually)
if [ "$MODE" = "local" ] && [ ! -d "$SUBTRACT_DIR/skills" ]; then
    cp -r "$SCRIPT_DIR/skills" "$SUBTRACT_DIR/skills"
    bash "$SUBTRACT_DIR/skills-rebuild.sh" 2>/dev/null || true
fi

# Add source line to shell rc
BASH_LINE='[ -f ~/.subtract/hooks/bash.sh ] && source ~/.subtract/hooks/bash.sh'
ZSH_LINE='[ -f ~/.subtract/hooks/zsh.sh ] && source ~/.subtract/hooks/zsh.sh'
PATH_LINE='export PATH="$HOME/.subtract:$PATH"'

if [ -f ~/.bashrc ] && ! grep -qF 'subtract/hooks/bash.sh' ~/.bashrc 2>/dev/null; then
    echo "" >> ~/.bashrc
    echo "# subtract" >> ~/.bashrc
    echo "$PATH_LINE" >> ~/.bashrc
    echo "$BASH_LINE" >> ~/.bashrc
fi

if [ -f ~/.zshrc ] && ! grep -qF 'subtract/hooks/zsh.sh' ~/.zshrc 2>/dev/null; then
    echo "" >> ~/.zshrc
    echo "# subtract" >> ~/.zshrc
    echo "$PATH_LINE" >> ~/.zshrc
    echo "$ZSH_LINE" >> ~/.zshrc
fi

# Report
echo ""
echo "subtract installed. ($MODE mode)"
echo ""
echo "T0   lookup table    active"
echo "T0.5 man pages       active"
if [ "$MODE" = "local" ]; then
    echo "     skills         active"
else
    echo "     skills         (requires git clone)"
fi
echo ""
echo "Open a new terminal, or: source ~/.subtract/hooks/bash.sh"
