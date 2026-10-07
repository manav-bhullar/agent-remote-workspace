#!/bin/bash
# Started by the MCP client on the Mac over SSH:  ssh -T my-server ~/.local/share/remote-runner/run.sh
export RR_SERVER_ROOT="${RR_SERVER_ROOT:-$HOME/Codes}"      # the shared folder on this server
export RR_MAC_ROOT="${RR_MAC_ROOT:-/Volumes/Codes}"          # the same folder as the Mac sees it
exec "$HOME/.local/share/remote-runner/.venv/bin/python" "$HOME/.local/share/remote-runner/server.py"
