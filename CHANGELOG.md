# Changelog

## 2026-10-07: Commands can't leak onto the Mac; the server picks the best Wi-Fi

### Added
- **`remote-runner` MCP tool** (`mcp/`). The agent gets `run_on_server`, `start_background`, `read_background`, `stop_background` and `list_background`. The tool runs **on the server**, started by the agent's MCP client over SSH, so nothing new runs on the Mac. Commands are passed as an argv list (`["npm","run","build"]`) or a bash script, so there is no `ssh '...'` quoting layer to break. Mac paths (`/Volumes/Codes/...`) are mapped to server paths automatically. Idea suggested on the [Google AI Developers Forum](https://discuss.ai.google.dev/t/187327).
- **Shell safety net** (`mac/rw-guard.zsh`). Inside the share, `npm`, `node`, `python`, `pip`, `git`, `cargo`, `docker` and friends typed on the Mac are forwarded to the server, even if an agent forgets its rules in a long session. Outside the share nothing changes. `RW_LOCAL=1` bypasses it, `RW_DRYRUN=1` previews it.
- **Wi-Fi switcher** (`server/wifi-switcher.sh`). When the server's Wi-Fi stays below 45% for 20 s and a saved network is at least 20 points stronger, it switches. Event-driven (NetworkManager signal events), with a 3-minute cooldown so it never flaps.
- **Measured footprint** in the docs: the Mac doorbell used 0.25 s of CPU in 5¾ hours; the server's ringer 1.5 s in 2½ hours.

### Changed
- `install-server.sh` installs the MCP tool; `install-mac.sh` installs the safety net and prints the MCP config entry.
- `agent-rules/AGENTS.md`: use `run_on_server` first, plain SSH only as a fallback; dev servers via `start_background`.

## 2026-10-04: First public release

### Reliability fixes from daily use
- **Event-driven reconnect instead of polling.** The server rings the Mac when its network comes back; the Mac also reacts to its own network changes; a 5-minute check catches anything missed. In a live test the share was back and verified **12 seconds** after the ring.
- **The doorbell can't silently die.** Every socket call is checked; on failure it exits so launchd restarts it, instead of spinning at 100% CPU. Rings are only accepted from Tailscale addresses.
- **Wake-ups are never lost.** A ring that arrives while a check is running is queued and triggers exactly one re-check.
- **One ring per network burst.** The server waits for 2 quiet seconds instead of ringing on each of the dozens of events a reconnect produces, then retries every second until the Mac answers (up to 5 minutes).
- **Safe OFF switch.** Toggle Workspace ejects politely and asks before force-disconnecting (a forced unmount mid-save can corrupt a file), reports honest ON / OFF / PARTLY ON status, and confirms the result.
- **Frozen and ghost mounts repaired.** A mount that stops responding is detected and remounted; an empty leftover folder that made macOS mount the share as `Codes-1` is cleaned up first.

### Developer experience
- `localhost:3000` / `localhost:5173` on the Mac open dev servers running on the server (SSH port forwarding).
- One reused SSH connection, so agent commands start instantly.
- Agent rules for dev servers in tmux and for leaving `node_modules` and other heavy folders alone.

### Repo
- Value-first README, architecture, setup and troubleshooting docs, interactive installers, MIT license.
