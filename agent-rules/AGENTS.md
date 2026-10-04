# CRITICAL SYSTEM RULE: 100% REMOTE TERMINAL EXECUTION VIA SSH

This entire codebase is hosted on a remote Ubuntu Server.
Running ANY terminal commands on the local Mac is strictly prohibited to prevent Mac overheating, CPU spikes, and sync issues.

### Mandatory Rules for All Agents & Projects:
1. **NEVER run terminal commands on the local Mac.**
   - All build commands (`npm run build`, `npm run dev`, `cargo`, `python`), package installs (`npm install`, `pnpm`, `pip`), and git operations (`git add`, `git commit`, `git push`) MUST be executed remotely on the Ubuntu server.
2. **Execution Format:**
   - Always run commands over SSH using the `my-server` host alias (from ~/.ssh/config):
     `ssh my-server 'cd ~/Codes/<current_project> && <your_command>'`
3. **Local Tools:**
   - Only native file reading and editing tools (`view_file`, `write_to_file`, `replace_file_content`, `list_dir`) are permitted to run locally on the mounted files.
4. **Dev Servers & Long-Running Commands:**
   - Never run `npm run dev` (or any server/watcher) directly over SSH; it blocks the terminal and dies when the command ends.
   - Start it in a detached tmux session named after the project, and check its output instead:
     `ssh my-server 'cd ~/Codes/<current_project> && tmux new -d -s <project> "npm run dev"'`
     `ssh my-server 'tmux capture-pane -pt <project> | tail -20'`   (view output)
     `ssh my-server 'tmux kill-session -t <project>'`              (stop it)
   - Previews open on the Mac at `http://localhost:3000` (Next.js) and `http://localhost:5173` (Vite); these ports are forwarded to the server over SSH.
5. **Heavy Folders (`node_modules`, `.next`, `venv`/`.venv`, `__pycache__`, `dist`, `build`):**
   - Default: do NOT read, list, or search these folders. They are hidden in the IDE on purpose (scanning them over the network heats the Mac).
   - Only when a dependency is suspected broken/corrupted, inspect it ON THE SERVER via SSH, never through the mounted files:
     `ssh my-server 'cd ~/Codes/<current_project> && ls node_modules/<pkg> && grep -rn "<text>" node_modules/<pkg> | head'`
   - Prefer reinstalling over inspecting: `ssh my-server 'cd ~/Codes/<current_project> && rm -rf node_modules && npm install'` (or recreate the venv with `uv venv && uv pip install -r requirements.txt`).
