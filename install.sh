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

# verify manifest signature before installing anything
if [ "$MODE" = "web" ]; then
    fetch "llms.txt" "$SUBTRACT_DIR/llms.txt"
    fetch "llms.txt.sig" "$SUBTRACT_DIR/llms.txt.sig"
    fetch "authorized_signers" "$SUBTRACT_DIR/authorized_signers"
    if ! ssh-keygen -Y verify -f "$SUBTRACT_DIR/authorized_signers" \
        -I hodori@subtract.ing -n subtract.ing \
        -s "$SUBTRACT_DIR/llms.txt.sig" < "$SUBTRACT_DIR/llms.txt" >/dev/null 2>&1; then
        echo "ABORT: manifest signature verification failed."
        echo "The files at $BASE_URL may be compromised or the signing key rotated."
        echo "Verify manually: https://subtract.ing/authorized_signers"
        rm -f "$SUBTRACT_DIR/llms.txt" "$SUBTRACT_DIR/llms.txt.sig" "$SUBTRACT_DIR/authorized_signers"
        exit 1
    fi
    echo "manifest signature verified: hodori@subtract.ing"
elif [ "$MODE" = "local" ]; then
    if [ -f "$SCRIPT_DIR/llms.txt" ] && [ -f "$SCRIPT_DIR/llms.txt.sig" ] && [ -f "$SCRIPT_DIR/authorized_signers" ]; then
        if ! ssh-keygen -Y verify -f "$SCRIPT_DIR/authorized_signers" \
            -I hodori@subtract.ing -n subtract.ing \
            -s "$SCRIPT_DIR/llms.txt.sig" < "$SCRIPT_DIR/llms.txt" >/dev/null 2>&1; then
            echo "WARNING: local manifest signature verification failed. Proceeding from trusted checkout."
        else
            echo "manifest signature verified: hodori@subtract.ing"
        fi
    fi
fi

# T0 core
fetch "runtime/subtract.sh" "$SUBTRACT_DIR/subtract.sh"
fetch "runtime/addition" "$SUBTRACT_DIR/addition"
fetch "runtime/ask" "$SUBTRACT_DIR/ask"
fetch "runtime/cheatsheet.txt" "$SUBTRACT_DIR/cheatsheet.txt"
fetch "runtime/index.html" "$SUBTRACT_DIR/index.html"
fetch "runtime/hooks/bash.sh" "$SUBTRACT_DIR/hooks/bash.sh"
fetch "runtime/hooks/zsh.sh" "$SUBTRACT_DIR/hooks/zsh.sh"
chmod +x "$SUBTRACT_DIR/addition" "$SUBTRACT_DIR/ask"

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

# pages
fetch "runtime/pages/subtracting.html" "$SUBTRACT_DIR/pages/subtracting.html"
fetch "runtime/pages/multiplying.html" "$SUBTRACT_DIR/pages/multiplying.html"
fetch "runtime/pages/bridge.py" "$SUBTRACT_DIR/pages/bridge.py"

# browse command + launchers
fetch "runtime/browse" "$SUBTRACT_DIR/browse"
chmod +x "$SUBTRACT_DIR/browse"

cat > "$SUBTRACT_DIR/pages/serve" <<'SERVE'
#!/bin/bash
cd ~/.subtract/pages
python3 -m http.server 8888 &
echo "Serving on http://localhost:8888"
SERVE
chmod +x "$SUBTRACT_DIR/pages/serve"

for name in subtracting multiplying; do
    cat > "$SUBTRACT_DIR/$name" <<LAUNCHER
#!/bin/bash
exec ~/.subtract/browse $name
LAUNCHER
    chmod +x "$SUBTRACT_DIR/$name"
done

cat > "$SUBTRACT_DIR/browse.aliases" <<ALIASES
kiwix	file://$SUBTRACT_DIR/pages/subtracting.html
subtracting	file://$SUBTRACT_DIR/pages/subtracting.html
multiplying	file://$SUBTRACT_DIR/pages/multiplying.html
ALIASES

# Shell integration
BASH_LINE='[ -f ~/.subtract/hooks/bash.sh ] && source ~/.subtract/hooks/bash.sh'
ZSH_LINE='[ -f ~/.subtract/hooks/zsh.sh ] && source ~/.subtract/hooks/zsh.sh'
PATH_LINE='export PATH="$HOME/.subtract:$PATH"'

if [ -f ~/.bashrc ] && ! grep -qF 'subtract/hooks' ~/.bashrc; then
    echo -e "\n# subtract\n$PATH_LINE\n$BASH_LINE" >> ~/.bashrc
fi

command -v zsh >/dev/null 2>&1 && [ ! -f ~/.zshrc ] && touch ~/.zshrc
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
