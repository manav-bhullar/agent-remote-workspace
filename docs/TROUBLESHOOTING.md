# Troubleshooting

Start with the health check on the Mac:

```bash
~/.scripts/auto-mount-smb.sh --status
```

| Symptom | Likely cause | Fix |
|---|---|---|
| `Network FAIL` | Tailscale down on either side, or server off | `tailscale status` on both machines |
| `SMB 445 FAIL` | Samba not running | On the server: `systemctl status smbd` |
| Notification: "SMB authentication is required" | No saved password in Keychain | Connect once via Finder → Go → Connect to Server, tick *Remember password* |
| Share never mounts, log says `Ghost directory ... is not empty` | Something wrote into `/Volumes/Codes` while unmounted | Move those files elsewhere, then `rmdir /Volumes/Codes` |
| Doorbell doesn't answer | Workspace toggled OFF, or listener not running | Toggle Workspace → ON; check `lsof -nP -iTCP:4455 -sTCP:LISTEN` |
| Server rings, Mac log shows nothing | Ring isn't coming from a Tailscale address | Make sure `MAC_IP` in `mac-wakeup.sh` is the Mac's **Tailscale** IP |
| Toggle says **PARTLY ON** | One background job failed to load | Choose Turn ON again; check `launchctl print gui/$(id -u)/com.remoteworkspace.listener` |
| `localhost:3000` shows nothing | Dev server not running, or SSH connection opened before the forward was configured | `ssh my-server tmux ls`; reset with `ssh -O exit my-server` |
| Agent runs commands on the Mac | Rules file missing or not picked up | Put `AGENTS.md` (and `GEMINI.md` for Antigravity) at the root of the opened folder |
| No notifications appear | macOS attributes them to Script Editor | System Settings → Notifications → Script Editor → Allow |

## Logs

```bash
# Mac: every check, with its result
tail -f ~/Library/Logs/RemoteWorkspace.log

# Server: every ring and whether the Mac answered
journalctl --user -u mac-wakeup -f
```

Log states you'll see: `INIT` (check started), `QUEUED` (wake-up arrived mid-check), `RERUN` (re-check for a queued wake-up), `MOUNT_DEGRADED`/`MOUNT_STALE` (frozen mount detected), `RECOVERING`, `HEALTHY`, `FAILED`.
