#!/bin/bash
# Mac side of Remote Workspace: reconciler, doorbell, background jobs, on/off app.
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ "$(uname)" = Darwin ] || { echo "Run this on the Mac."; exit 1; }
command -v swiftc >/dev/null || { echo "Install Xcode Command Line Tools first: xcode-select --install"; exit 1; }

say "Remote Workspace: Mac setup"
read -rp "Server hostname (Tailscale name or IP): " SERVER
[ -n "$SERVER" ] || { echo "Server is required."; exit 1; }
read -rp "Server user [$USER]: " SMB_USER
SMB_USER=${SMB_USER:-$USER}
read -rp "Share name [Codes]: " SHARE
SHARE=${SHARE:-Codes}
MOUNT_DIR="/Volumes/$SHARE"
read -rp "Editor app name [Antigravity]: " EDITOR_APP
EDITOR_APP=${EDITOR_APP:-Antigravity}
EDITOR_ID=$(osascript -e "id of app \"$EDITOR_APP\"" 2>/dev/null || echo "com.google.antigravity")

mkdir -p "$HOME/.scripts" "$HOME/.ssh/sockets" "$HOME/Library/LaunchAgents"

# 1. Reconciler -------------------------------------------------------------------
say "1/4  Reconciler"
sed -e "s|^SERVER=.*|SERVER=\"$SERVER\"|" \
    -e "s|^SMB_USER=.*|SMB_USER=\"$SMB_USER\"|" \
    -e "s|^SHARE=.*|SHARE=\"$SHARE\"|" \
    -e "s|^MOUNT_DIR=.*|MOUNT_DIR=\"$MOUNT_DIR\"|" \
    -e "s|^EDITOR_APP=.*|EDITOR_APP=\"$EDITOR_APP\"|" \
    mac/auto-mount-smb.sh > "$HOME/.scripts/auto-mount-smb.sh"
chmod +x "$HOME/.scripts/auto-mount-smb.sh"
echo "  ~/.scripts/auto-mount-smb.sh"

# 2. Doorbell ---------------------------------------------------------------------
say "2/4  Building the doorbell (takes ~20 s)"
swiftc -O mac/mac-listener.swift -o "$HOME/.scripts/mac-listener"
echo "  ~/.scripts/mac-listener"

# 3. On/off app -------------------------------------------------------------------
say "3/4  Toggle Workspace app"
TMP_SCRIPT=$(mktemp -t toggle).applescript
sed -e "s|^set mountDir to .*|set mountDir to \"$MOUNT_DIR\"|" \
    -e "s|^set editorBundleId to .*|set editorBundleId to \"$EDITOR_ID\"|" \
    mac/toggle-workspace.applescript > "$TMP_SCRIPT"
rm -rf "$HOME/Desktop/Toggle Workspace.app"
osacompile -o "$HOME/Desktop/Toggle Workspace.app" "$TMP_SCRIPT"
rm -f "$TMP_SCRIPT"
echo "  ~/Desktop/Toggle Workspace.app"

# 4. Background jobs --------------------------------------------------------------
say "4/4  Background jobs"
for f in mac/launchagents/*.plist; do
    label=$(basename "$f" .plist)
    dest="$HOME/Library/LaunchAgents/$label.plist"
    sed "s|__HOME__|$HOME|g" "$f" > "$dest"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null && sleep 1 || true
    launchctl bootstrap "gui/$(id -u)" "$dest"
    echo "  $label loaded"
done

say "Done."
cat <<EOF
Next:
  1. Save the SMB password once: Finder > Go > Connect to Server >
       smb://$SMB_USER@$SERVER/$SHARE   (tick "Remember this password in my keychain")
  2. Add mac/ssh_config.example to ~/.ssh/config (host alias, connection reuse, localhost previews).
  3. Check:  ~/.scripts/auto-mount-smb.sh --status
  Then use "Toggle Workspace" on the Desktop to switch on/off.
EOF
