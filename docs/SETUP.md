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

Copy [`agent-rules/AGENTS.md`](../agent-rules/AGENTS.md) to the root of the share. Also save it as `GEMINI.md` for Antigravity or `CLAUDE.md` for Claude Code. Adjust the host alias (`my-server`) and the path (`~/Codes`).

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

## Optional: Wi-Fi switcher (server)

If the server sits on hotspots or several Wi-Fi networks, `server/wifi-switcher.sh` moves it to a clearly stronger **saved** network when the current one stays weak. It sleeps until NetworkManager reports a signal change (no polling while the signal is fine). The existing doorbell rings the Mac after each switch.

Defaults (override with environment variables): weak below **45%** (about -78 dBm) for **20 s**, switch only to a network at least **20 points** stronger, rescan every **30 s** while weak, wait **3 min** between switches. Test first with `DRY_RUN=1`.

```bash
# one-time permission (a headless server can't show NetworkManager's password prompt)
sed 's/YOUR_USER/'"$USER"'/' server/50-wifi-switcher.rules | sudo tee /etc/polkit-1/rules.d/50-wifi-switcher.rules
# install
install -m 755 server/wifi-switcher.sh ~/.scripts/ && install -m 644 server/wifi-switcher.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now wifi-switcher
```

Assumes each saved connection is named after its SSID (the NetworkManager default). Logs: `journalctl --user -u wifi-switcher`.

## 4. Make the agent run commands on the server (remote-runner + safety net)

**remote-runner (MCP tool).** On the server (the installer does this):

```bash
mkdir -p ~/.local/share/remote-runner
cp mcp/server.py mcp/run.sh ~/.local/share/remote-runner/
cd ~/.local/share/remote-runner && uv venv .venv && uv pip install --python .venv/bin/python mcp
# edit run.sh: RR_SERVER_ROOT = the shared folder here, RR_MAC_ROOT = where the Mac mounts it
```

On the Mac, add the entry from [`mac/mcp_config.example.json`](../mac/mcp_config.example.json) to your agent's MCP config (Antigravity: **Settings → Customizations → Open MCP Config**, file `~/.gemini/config/mcp_config.json`). The agent then has five tools: `run_on_server`, `start_background`, `read_background`, `stop_background`, `list_background`. Nothing new runs on the Mac: the client starts the tool **on the server** through SSH.

Check it from the Mac:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
  | /usr/bin/ssh -T -o BatchMode=yes my-server '~/.local/share/remote-runner/run.sh' | head -c 120
```

**Safety net.** Edit the three `RW_` lines in [`mac/rw-guard.zsh`](../mac/rw-guard.zsh), then:

```bash
cp mac/rw-guard.zsh ~/.scripts/rw-guard.zsh
echo '[[ -f ~/.scripts/rw-guard.zsh ]] && source ~/.scripts/rw-guard.zsh' >> ~/.zshenv
# open a new terminal, then preview without running anything:
cd /Volumes/Codes/<project> && RW_DRYRUN=1 npm run build
```

Inside the share, `npm npx node pnpm yarn bun python python3 pip pip3 uv pytest cargo go make docker git` are forwarded to the server. Outside it, nothing changes. Bypass once with `RW_LOCAL=1`.
