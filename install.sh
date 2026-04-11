#!/bin/bash
# subtract installer
# lands beside your shell. no sudo, no package managers, no system modifications.
# copies files to ~/.subtract/, adds one line to your shell rc. that's it.
set -e

SUBTRACT_DIR="$HOME/.subtract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- copy files ---

mkdir -p "$SUBTRACT_DIR"
mkdir -p "$SUBTRACT_DIR/hooks"

cp "$SCRIPT_DIR/subtract/handler.sh" "$SUBTRACT_DIR/"
cp "$SCRIPT_DIR/subtract/embed_match.sh" "$SUBTRACT_DIR/"
cp "$SCRIPT_DIR/subtract/motd" "$SUBTRACT_DIR/"
cp "$SCRIPT_DIR/subtract/skills-rebuild.sh" "$SUBTRACT_DIR/"
cp "$SCRIPT_DIR/subtract/about" "$SUBTRACT_DIR/"
cp "$SCRIPT_DIR/subtract/subtract" "$SUBTRACT_DIR/"
cp "$SCRIPT_DIR/subtract/hooks/bash.sh" "$SUBTRACT_DIR/hooks/"
cp "$SCRIPT_DIR/subtract/hooks/zsh.sh" "$SUBTRACT_DIR/hooks/"
cp "$SCRIPT_DIR/onboard.sh" "$SUBTRACT_DIR/"

# signing scripts
cp "$SCRIPT_DIR/subtract/sign-lookup.sh" "$SUBTRACT_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/subtract/verify-lookup.sh" "$SUBTRACT_DIR/" 2>/dev/null || true
chmod +x "$SUBTRACT_DIR/"*.sh 2>/dev/null || true

# lookup.tsv: don't overwrite user edits
if [ ! -f "$SUBTRACT_DIR/lookup.tsv" ]; then
    cp "$SCRIPT_DIR/subtract/lookup.tsv" "$SUBTRACT_DIR/"
fi

# skills: don't overwrite user edits
if [ ! -d "$SUBTRACT_DIR/skills" ]; then
    cp -r "$SCRIPT_DIR/skills" "$SUBTRACT_DIR/skills"
    bash "$SUBTRACT_DIR/skills-rebuild.sh" 2>/dev/null || true
fi

# --- add source line to shell rc ---

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

# --- report status ---

echo ""
echo "subtract installed."
echo ""
echo "T0   lookup table    active"
echo "T0.5 man pages       active"
echo ""
echo "Try: type subtract"
echo ""
echo "Run 'subtract upgrade' for optional tiers."
echo ""
echo "Open a new terminal, or: source ~/.subtract/hooks/bash.sh"
