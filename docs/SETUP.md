# Manual setup

The install scripts do all of this for you. Use this page if you prefer to do it by hand or want to understand each piece.

Replace `my-server`, `my-user`, `100.x.y.z` and paths with your own values.

## Prerequisites

- **Mac** with Xcode Command Line Tools (`xcode-select --install`)
- **Ubuntu server** with OpenSSH
- **Tailscale** on both machines, signed in to the same tailnet
- SSH key login from the Mac to the server (`ssh-copy-id my-user@my-server`)

## 1. Server

### Share the code folder over SMB

```bash
sudo apt install samba tmux netcat-openbsd
mkdir -p ~/Codes
# edit path/user in the example first
sudo tee -a /etc/samba/smb.conf < server/smb.conf.example
sudo smbpasswd -a my-user && sudo smbpasswd -e my-user
sudo systemctl restart smbd
```

### Network watcher (rings the Mac)

Set `MAC_IP` at the top of `server/mac-wakeup.sh` to the Mac's Tailscale IP (`tailscale ip -4` on the Mac), then:

```bash
mkdir -p ~/.scripts ~/.config/systemd/user
cp server/mac-wakeup.sh ~/.scripts/ && chmod +x ~/.scripts/mac-wakeup.sh
cp server/mac-wakeup.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now mac-wakeup
loginctl enable-linger "$USER"   # keep user services running without a login session
```

### Recommended: allow SMB/SSH only over Tailscale

```bash
sudo ufw allow in on tailscale0
sudo ufw default deny incoming
sudo ufw enable
```

## 2. Mac

### SSH

Append [`mac/ssh_config.example`](../mac/ssh_config.example) to `~/.ssh/config` (edit host, user, IP), then:

```bash
mkdir -p ~/.ssh/sockets
ssh my-server true    # first connection; accept the host key
```

### Reconciler

Edit the **Configure these** block at the top of `mac/auto-mount-smb.sh`, then:

```bash
mkdir -p ~/.scripts
cp mac/auto-mount-smb.sh ~/.scripts/ && chmod +x ~/.scripts/auto-mount-smb.sh
```

### Doorbell

```bash
swiftc -O mac/mac-listener.swift -o ~/.scripts/mac-listener
```

### Background jobs

```bash
for f in mac/launchagents/*.plist; do
  sed "s|__HOME__|$HOME|g" "$f" > ~/Library/LaunchAgents/"$(basename "$f")"
done
```

### Save the SMB password

Finder → **Go → Connect to Server** → `smb://my-user@my-server/Codes` → tick **Remember this password in my keychain**.

### On/off switch

Edit `mountDir` / `editorBundleId` at the top of `mac/toggle-workspace.applescript` if needed, then:

```bash
osacompile -o ~/Desktop/"Toggle Workspace.app" mac/toggle-workspace.applescript
```

Double-click it → **Turn ON**. This loads both background jobs; the share mounts within a few seconds.

## 3. Agent rules

Copy [`agent-rules/AGENTS.md`](../agent-rules/AGENTS.md) to the root of the share. For Antigravity, also save it as `GEMINI.md`. Adjust the host alias (`my-server`) and the path (`~/Codes`).

## Verify

```bash
# Mac
~/.scripts/auto-mount-smb.sh --status
lsof -nP -iTCP:4455 -sTCP:LISTEN

# Server: ring the doorbell by hand
nc -z -w 2 100.x.y.z 4455 && echo answered

# Mac: the ring should appear as "(Mode: --wakeup)" followed by HEALTHY
tail -5 ~/Library/Logs/RemoteWorkspace.log
```
