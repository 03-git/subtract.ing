#!/bin/bash
# subtract OS onboarding
# runs after install.sh on a working subtract system.
# via negativa: what do you want to remove, not what do you want to configure.
SUBTRACT_DIR="$HOME/.subtract"
SUBTRACT_KIWIX_PORT="${SUBTRACT_KIWIX_PORT:-8888}"

# clinical mode: skip cloud AI activation entirely
# set SUBTRACT_CLINICAL=1 or pass --clinical flag
SUBTRACT_CLINICAL="${SUBTRACT_CLINICAL:-0}"
for _arg in "$@"; do
    [ "$_arg" = "--clinical" ] && SUBTRACT_CLINICAL=1
done

# sudo wrapper: skip sudo if already root
_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# --- preflight ---

if [ ! -f "$SUBTRACT_DIR/handler.sh" ]; then
    echo "subtract not installed. run install.sh first."
    exit 1
fi

echo ""
echo "subtract OS onboarding"
echo "======================"
echo ""
echo "this walks you through setup by subtraction."
echo "default answer is always: change nothing."
echo ""

# --- step 1: via negativa admin ---

echo "--- step 1: via negativa ---"
echo ""
echo "packages installed that subtract doesn't need."
echo "you choose what to remove. default: remove nothing."
echo ""

# detect removable candidates
candidates=()
labels=()

# editor: pick one, remove the other
if command -v nano &>/dev/null && command -v vim &>/dev/null; then
    candidates+=("nano" "vim")
    labels+=("nano (text editor, vim also installed)" "vim (text editor, nano also installed)")
fi

# man-db: optional on a minimal system
if dpkg -l man-db &>/dev/null 2>&1; then
    candidates+=("man-db")
    labels+=("man-db (manual pages, 40MB+)")
fi

# desktop packages that snuck in
for pkg in x11-common xserver-common gdm3 lightdm gnome-shell plasma-desktop; do
    if dpkg -l "$pkg" &>/dev/null 2>&1; then
        candidates+=("$pkg")
        labels+=("$pkg (desktop component)")
    fi
done

if [ ${#candidates[@]} -eq 0 ]; then
    echo "nothing to subtract. system is already minimal."
else
    for i in "${!candidates[@]}"; do
        echo "  [$((i+1))] ${labels[$i]}"
    done
    echo ""
    echo "enter numbers to remove (space-separated), or press enter to skip:"
    read -r selections
    if [ -n "$selections" ]; then
        to_remove=()
        for sel in $selections; do
            if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
                echo "skipping invalid input: $sel"
                continue
            fi
            idx=$((sel - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#candidates[@]}" ]; then
                to_remove+=("${candidates[$idx]}")
            fi
        done
        if [ ${#to_remove[@]} -gt 0 ]; then
            echo ""
            echo "will remove: ${to_remove[*]}"
            read -r -p "confirm? [y/n] " confirm_remove
            if [[ "$confirm_remove" =~ ^[Yy] ]]; then
                _sudo apt-get remove -y "${to_remove[@]}" || echo "some packages failed to remove."
                _sudo apt-get autoremove -y || true
            else
                echo "skipping removal."
            fi
        fi
    else
        echo "keeping everything."
    fi
fi

# --- step 2: cloud AI activation (sovereign branch only) ---

if [ "$SUBTRACT_CLINICAL" = "1" ]; then
    echo ""
    echo "--- step 2: cloud AI ---"
    echo ""
    echo "clinical mode: skipping cloud AI activation."
    echo "this device stays local-only. no outbound connections."
    echo "1" > "$SUBTRACT_DIR/clinical"
    # clean up any prior sovereign state
    if [ -f "$SUBTRACT_DIR/cloud_ai" ] || [ -f "$SUBTRACT_DIR/api_key" ]; then
        echo "removing prior cloud AI configuration."
        rm -f "$SUBTRACT_DIR/cloud_ai" "$SUBTRACT_DIR/api_key"
    fi
    ai_name=""
    api_key=""
else

echo ""
echo "--- step 2: cloud AI ---"
echo ""
echo "subtract works offline with a local model."
echo "optionally connect a cloud AI for escalation."
echo ""

if command -v claude &>/dev/null; then
    echo "detected: Claude Code (installed)"
    echo ""
fi

echo "activate Claude for cloud escalation (T4)?"
echo "  [1] yes"
echo "  [0] no -- stay local-only"
echo ""
read -r -p "choice [0]: " ai_choice
ai_choice="${ai_choice:-0}"

case "$ai_choice" in
    1)
        ai_name="claude"
        if ! command -v claude &>/dev/null; then
            echo "claude not found. install it first:"
            echo "  curl -fsSL https://claude.ai/install.sh | bash"
            echo "then re-run onboard.sh."
        fi
        echo ""
        read -rs -p "enter your Anthropic API key (or press enter to skip): " api_key
        echo ""
        ;;
    *)
        ai_name=""
        api_key=""
        echo "staying local-only."
        ;;
esac

if [ -n "$api_key" ]; then
    (umask 077 && printf '%s' "$api_key" > "$SUBTRACT_DIR/api_key")
    echo "api key stored in $SUBTRACT_DIR/api_key"
fi
unset api_key

if [ -n "$ai_name" ]; then
    echo "$ai_name" > "$SUBTRACT_DIR/cloud_ai"
    echo "cloud AI set to: $ai_name"
fi

fi  # end sovereign-only block

# --- step 3: kiwix ---

echo ""
echo "--- step 3: offline knowledge ---"
echo ""
echo "kiwix serves offline wikipedia. no internet needed after setup."
echo ""

# clinical mode: kiwix must be pre-installed and ZIMs pre-loaded before air-gap
if [ "$SUBTRACT_CLINICAL" = "1" ]; then
    echo "clinical mode: kiwix must be pre-installed. skipping."
    echo "(pre-load ZIM files into $SUBTRACT_DIR/zim/ before air-gapping.)"
    kiwix_yn="n"
else
    read -r -p "install kiwix? [y/n] " kiwix_yn
fi
if [[ "$kiwix_yn" =~ ^[Yy] ]]; then
    if ! [[ "$SUBTRACT_KIWIX_PORT" =~ ^[0-9]+$ ]] || [ "$SUBTRACT_KIWIX_PORT" -lt 1 ] || [ "$SUBTRACT_KIWIX_PORT" -gt 65535 ]; then
        echo "invalid kiwix port: $SUBTRACT_KIWIX_PORT"
        kiwix_yn="n"
    fi
fi
if [[ "$kiwix_yn" =~ ^[Yy] ]]; then
    if ! command -v kiwix-serve &>/dev/null; then
        echo "installing kiwix-tools..."
        if ! _sudo apt-get install -y kiwix-tools; then
            echo "kiwix-tools install failed (no network?). skipping."
            kiwix_yn="n"
        fi
    fi

    ZIM_DIR="$SUBTRACT_DIR/zim"
    mkdir -p "$ZIM_DIR"

    shopt -s nullglob
    zim_files=("$ZIM_DIR"/*.zim)
    shopt -u nullglob
    if [ ${#zim_files[@]} -eq 0 ]; then
        echo ""
        echo "downloading simple english wikipedia (~1GB)..."
        echo "this is the offline knowledge floor."
        # find current ZIM URL
        ZIM_URL="https://download.kiwix.org/zim/wikipedia/wikipedia_en_simple_all_maxi_2026-02.zim"
        echo "source: $ZIM_URL"
        curl -L -o "$ZIM_DIR/wikipedia_en_simple.zim" "$ZIM_URL"
    else
        echo "ZIM file already present."
    fi

    # find the zim file
    ZIM_FILE=
    for _f in "$ZIM_DIR"/*.zim; do
        [ -f "$_f" ] && ZIM_FILE="$_f" && break
    done

    if [ -n "$ZIM_FILE" ]; then
        # systemd unit for kiwix
        if [ -d /etc/systemd/system ] && command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
            echo "creating kiwix systemd service..."
            _sudo tee /etc/systemd/system/kiwix.service > /dev/null <<UNIT
[Unit]
Description=Kiwix offline library
After=network.target

[Service]
ExecStart=/usr/bin/kiwix-serve --port $SUBTRACT_KIWIX_PORT $ZIM_FILE
Restart=on-failure
User=$USER

[Install]
WantedBy=multi-user.target
UNIT
            _sudo systemctl daemon-reload
            _sudo systemctl enable kiwix.service
            if _sudo systemctl start kiwix.service; then
                echo "kiwix running on port $SUBTRACT_KIWIX_PORT."
            else
                echo "kiwix service failed to start. check: systemctl status kiwix"
            fi
        else
            # no systemd (WSL, container): run directly in background
            kiwix-serve --port "$SUBTRACT_KIWIX_PORT" "$ZIM_FILE" &
            echo "kiwix running on port $SUBTRACT_KIWIX_PORT (background process)."
        fi

        # persist port for handler.sh integration
        echo "$SUBTRACT_KIWIX_PORT" > "$SUBTRACT_DIR/kiwix_port"

        # validate
        sleep 1
        if curl -s --connect-timeout 2 localhost:"$SUBTRACT_KIWIX_PORT" > /dev/null 2>&1; then
            echo "kiwix validated: localhost:${SUBTRACT_KIWIX_PORT} responding."
        else
            echo "kiwix may still be starting. check: curl localhost:${SUBTRACT_KIWIX_PORT}"
        fi
    else
        echo "no ZIM file found. kiwix installed but not serving."
    fi
else
    echo "skipping kiwix."
fi

# --- done ---

echo ""
echo "======================"
echo "onboarding complete."
echo ""
[ -f "$SUBTRACT_DIR/cloud_ai" ] && echo "cloud AI: $(cat "$SUBTRACT_DIR/cloud_ai")"
[ -f "$SUBTRACT_DIR/api_key" ] && echo "api key: stored"
command -v kiwix-serve &>/dev/null && echo "kiwix: installed"
echo ""
touch "$SUBTRACT_DIR/.onboarded"
echo "type what you want the computer to do."
