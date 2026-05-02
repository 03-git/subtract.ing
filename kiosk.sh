#!/bin/bash
# kiosk.sh — set up a display node running multiplying.html via cage+cog
# requires: root (for apt + autologin), Debian trixie or later
# usage: sudo ./kiosk.sh [username]
set -e

USER="${1:-media}"
HOME_DIR=$(eval echo "~$USER")
SUBTRACT_DIR="$HOME_DIR/.subtract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root: sudo $0 $USER"
    exit 1
fi

if ! id "$USER" >/dev/null 2>&1; then
    echo "user $USER does not exist"
    exit 1
fi

apt-get update -qq
apt-get install -y -qq cage cog busybox espeak-ng jq chafa python3 >/dev/null

# autologin on tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF
systemctl daemon-reload

# install subtract runtime as the user
su -c "bash '$SCRIPT_DIR/install.sh'" "$USER"

# .bash_profile: cage → cog → multiplying.html on tty1
cat > "$HOME_DIR/.bash_profile" << 'PROFILE'
[ -f ~/.bashrc ] && . ~/.bashrc

if [ "$(tty)" = "/dev/tty1" ] && [ -z "$DISPLAY" ]; then
    WLR_DRM_DEVICES=/dev/dri/card0 exec cage -- cog -P wl http://localhost:8070/multiplying.html
fi
PROFILE
chown "$USER:$USER" "$HOME_DIR/.bash_profile"

# systemd user services for httpd and bridge
UNITS="$HOME_DIR/.config/systemd/user"
mkdir -p "$UNITS"

cat > "$UNITS/subtract-httpd.service" << EOF
[Unit]
Description=subtract static server
[Service]
ExecStart=/usr/bin/busybox httpd -f -p 8070 -h $SUBTRACT_DIR/pages
Restart=always
[Install]
WantedBy=default.target
EOF

cat > "$UNITS/subtract-bridge.service" << EOF
[Unit]
Description=subtract bridge
After=subtract-httpd.service
[Service]
ExecStart=/usr/bin/python3 $SUBTRACT_DIR/pages/bridge.py
Restart=always
[Install]
WantedBy=default.target
EOF

chown -R "$USER:$USER" "$HOME_DIR/.config/systemd"

# enable lingering so user services start at boot
loginctl enable-linger "$USER"
su -c "systemctl --user daemon-reload && systemctl --user enable --now subtract-httpd subtract-bridge" "$USER"

echo ""
echo "kiosk ready."
echo "  display: cage → cog → multiplying.html"
echo "  httpd:   :8070"
echo "  bridge:  :8889"
echo "  reboot or: systemctl restart getty@tty1"
