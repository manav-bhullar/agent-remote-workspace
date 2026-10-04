#!/bin/bash
# Server side of Remote Workspace: SMB share + network watcher that rings the Mac's doorbell.
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ "$(uname)" = Linux ] || { echo "Run this on the Linux server."; exit 1; }
for cmd in ip nc systemctl; do
    command -v "$cmd" >/dev/null || { echo "Missing '$cmd'. Install: sudo apt install iproute2 netcat-openbsd"; exit 1; }
done

say "Remote Workspace: server setup"
read -rp "Mac's Tailscale IP (run 'tailscale ip -4' on the Mac): " MAC_IP
[[ "$MAC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "That doesn't look like an IPv4 address."; exit 1; }
read -rp "Folder to share [$HOME/Codes]: " SHARE_PATH
SHARE_PATH=${SHARE_PATH:-$HOME/Codes}
read -rp "Share name [Codes]: " SHARE_NAME
SHARE_NAME=${SHARE_NAME:-Codes}

# 1. Network watcher --------------------------------------------------------------
say "1/2  Installing the network watcher"
mkdir -p "$HOME/.scripts" "$HOME/.config/systemd/user"
sed "s|^MAC_IP=.*|MAC_IP=\"$MAC_IP\"   # the Mac's Tailscale IP|" server/mac-wakeup.sh > "$HOME/.scripts/mac-wakeup.sh"
chmod +x "$HOME/.scripts/mac-wakeup.sh"
cp server/mac-wakeup.service "$HOME/.config/systemd/user/"
if [ "${SKIP_SERVICES:-0}" != 1 ]; then
    systemctl --user daemon-reload
    systemctl --user enable --now mac-wakeup
    systemctl --user restart mac-wakeup
    loginctl enable-linger "$USER" 2>/dev/null || echo "  (Could not enable linger; run: sudo loginctl enable-linger $USER)"
fi
echo "  Watcher installed: ~/.scripts/mac-wakeup.sh (log: journalctl --user -u mac-wakeup)"

# 2. SMB share --------------------------------------------------------------------
say "2/2  SMB share"
mkdir -p "$SHARE_PATH"
if grep -qs "^\[$SHARE_NAME\]" /etc/samba/smb.conf; then
    echo "  Share [$SHARE_NAME] already exists in /etc/samba/smb.conf; leaving it alone."
else
    read -rp "  Create share [$SHARE_NAME] -> $SHARE_PATH now? Needs sudo. [y/N]: " ok
    if [[ "$ok" =~ ^[Yy]$ ]]; then
        sudo apt-get install -y samba tmux netcat-openbsd
        printf '\n[%s]\n    path = %s\n    read only = no\n    browsable = yes\n    valid users = %s\n' \
            "$SHARE_NAME" "$SHARE_PATH" "$USER" | sudo tee -a /etc/samba/smb.conf >/dev/null
        echo "  Set the SMB password for $USER (used by the Mac to connect):"
        sudo smbpasswd -a "$USER"
        sudo smbpasswd -e "$USER"
        sudo systemctl restart smbd
        echo "  Share created."
    else
        echo "  Skipped. See docs/SETUP.md to add it by hand."
    fi
fi

say "Done."
cat <<EOF
Next:
  - Recommended: allow SMB/SSH only over Tailscale:
      sudo ufw allow in on tailscale0 && sudo ufw default deny incoming && sudo ufw enable
  - Copy agent-rules/AGENTS.md to $SHARE_PATH/ (and as GEMINI.md for Antigravity).
  - Run ./install-mac.sh on the Mac.
EOF
