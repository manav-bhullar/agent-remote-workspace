"""remote-runner: an MCP server that runs commands on this Linux server.

Antigravity (or any MCP client) on the Mac starts it over SSH:
    ssh -T my-server ~/.local/share/remote-runner/run.sh
so the tool itself lives on the server and commands never touch the Mac.

Commands are passed as an argv list or as a bash script sent on stdin,
so there is no `ssh '...'` quoting layer at all.
"""

import asyncio
import os
import re
import signal

from mcp.server.mcpserver import MCPServer

HOME = os.path.expanduser("~")
MAC_ROOT = os.environ.get("RR_MAC_ROOT", "/Volumes/Codes")  # path the agent sees on the Mac
SERVER_ROOT = os.path.expanduser(os.environ.get("RR_SERVER_ROOT", "~/Codes"))  # same folder here
MAX_OUT = 15000  # characters kept from the end of stdout / stderr

ENV = dict(
    os.environ,
    PATH=f"{HOME}/.local/bin:" + os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
    CI="1",
    GIT_TERMINAL_PROMPT="0",
    PAGER="cat",
    GIT_PAGER="cat",
)

mcp = MCPServer(
    "remote-runner",
    instructions=(
        "The project files live on a Linux server and are mounted on the Mac. "
        "Use run_on_server for EVERY shell command (builds, installs, tests, git, scripts). "
        "Never use the local terminal. Pass Mac paths as they appear; they are mapped to the server. "
        "Use start_background for dev servers and watchers."
    ),
)


def to_server_path(text: str) -> str:
    """Map Mac paths (/Volumes/Codes/...) to the same folder on the server."""
    return text.replace(MAC_ROOT, SERVER_ROOT)


def resolve_cwd(cwd: str) -> str:
    path = os.path.expanduser(to_server_path(cwd or SERVER_ROOT))
    if not os.path.isabs(path):
        path = os.path.join(SERVER_ROOT, path)
    if not os.path.isdir(path):
        raise ValueError(f"cwd does not exist on the server: {path}")
    return path


def tail(text: str) -> str:
    return text if len(text) <= MAX_OUT else f"[... {len(text) - MAX_OUT} earlier characters cut ...]\n" + text[-MAX_OUT:]


def check_name(name: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", name):
        raise ValueError("name must be 1-40 letters, digits, '-' or '_'")
    return name


async def tmux(*args: str) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_exec(
        "tmux", *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, env=ENV
    )
    out, _ = await proc.communicate()
    return proc.returncode, out.decode(errors="replace").strip()


@mcp.tool()
async def run_on_server(
    cwd: str,
    command: list[str] | None = None,
    script: str | None = None,
    timeout_seconds: int = 600,
) -> str:
    """Run a command on the Linux server and return its exit code and output.

    Give exactly one of:
    - command: an argv list, e.g. ["npm", "run", "build"] (no shell, no quoting needed)
    - script: bash code, e.g. "npm test 2>&1 | tail -20". Pipes, quotes, heredocs and
      awk '{print $1}' work as written; nothing needs extra escaping.
    cwd: the project folder, as a Mac path (/Volumes/Codes/...) or a server path.
    For servers/watchers that never exit (npm run dev), use start_background instead.
    """
    if (command is None) == (script is None):
        return "Error: give exactly one of `command` or `script`."
    try:
        workdir = resolve_cwd(cwd)
    except ValueError as e:
        return f"Error: {e}"

    if command is not None:
        argv = [to_server_path(a) for a in command]
        proc = await asyncio.create_subprocess_exec(
            *argv, cwd=workdir, env=ENV, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, start_new_session=True,
        )
        stdin_data = None
    else:
        proc = await asyncio.create_subprocess_exec(
            "bash", "-l", "-s", cwd=workdir, env=ENV, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, start_new_session=True,
        )
        stdin_data = to_server_path(script).encode()

    try:
        out, err = await asyncio.wait_for(proc.communicate(stdin_data), timeout=timeout_seconds)
    except asyncio.TimeoutError:
        os.killpg(proc.pid, signal.SIGKILL)
        await proc.wait()
        return (f"Timed out after {timeout_seconds}s and was stopped (cwd: {workdir}). "
                "If this is a long-running server, use start_background.")

    parts = [f"exit code: {proc.returncode}  (ran on server in {workdir})"]
    if out:
        parts.append("--- stdout ---\n" + tail(out.decode(errors="replace")))
    if err:
        parts.append("--- stderr ---\n" + tail(err.decode(errors="replace")))
    return "\n".join(parts)


@mcp.tool()
async def start_background(name: str, cwd: str, script: str) -> str:
    """Start a long-running command (dev server, watcher) on the server in a tmux session.

    The output stays readable with read_background even after the process exits.
    Dev servers on ports 3000/5173 open on the Mac at http://localhost:<port>.
    """
    try:
        name, workdir = check_name(name), resolve_cwd(cwd)
    except ValueError as e:
        return f"Error: {e}"
    # Subshell so an `exit` in the script can't skip the trailer that keeps the output readable
    body = "(\n" + to_server_path(script) + '\n)\nec=$?; echo; echo "[process exited with code $ec]"; exec sleep infinity'
    code, out = await tmux("new-session", "-d", "-s", name, "-c", workdir, "bash", "-l", "-c", body)
    return f"Started '{name}' in {workdir}." if code == 0 else f"Error starting '{name}': {out}"


@mcp.tool()
async def read_background(name: str, lines: int = 60) -> str:
    """Show the last lines of output from a background session."""
    try:
        name = check_name(name)
    except ValueError as e:
        return f"Error: {e}"
    code, out = await tmux("capture-pane", "-p", "-t", name, "-S", f"-{max(1, min(lines, 2000))}")
    return out if code == 0 else f"No session '{name}': {out}"


@mcp.tool()
async def stop_background(name: str) -> str:
    """Stop a background session."""
    try:
        name = check_name(name)
    except ValueError as e:
        return f"Error: {e}"
    code, out = await tmux("kill-session", "-t", name)
    return f"Stopped '{name}'." if code == 0 else f"No session '{name}': {out}"


@mcp.tool()
async def list_background() -> str:
    """List background sessions running on the server."""
    code, out = await tmux("list-sessions")
    return out if code == 0 and out else "No background sessions."


if __name__ == "__main__":
    mcp.run("stdio")
