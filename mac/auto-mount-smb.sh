#!/bin/bash
# ==============================================================================
# Remote Workspace Reconciliation Controller
# ==============================================================================
# Philosophy: Observe -> debounce -> classify -> safe recovery -> verify -> record state.
#
# Modes:
#   (none)        interactive: mount, then open the editor
#   --background  launchd: Mac network change (WatchPaths) or 5-min safety net
#   --wakeup      mac-listener: the server rang the doorbell
#   --status      print diagnostics
# ==============================================================================

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ---- Configure these ---------------------------------------------------------
SERVER="my-server"            # server hostname (Tailscale MagicDNS name works well)
SMB_USER="my-user"            # Samba user on the server
SHARE="Codes"                 # Samba share name
MOUNT_DIR="/Volumes/Codes"    # where macOS mounts the share
VERIFY_DIR="${MOUNT_DIR}"     # a folder that must be readable for "healthy" (e.g. a project)
EDITOR_APP="Antigravity"      # app opened in interactive mode
# ------------------------------------------------------------------------------

SMB_URL="smb://${SMB_USER}@${SERVER}/${SHARE}"

LOCK_DIR="/tmp/remote_workspace.lock"
PID_FILE="${LOCK_DIR}/pid"
PENDING_FILE="/tmp/remote_workspace.pending"
LOG_FILE="${HOME}/Library/Logs/RemoteWorkspace.log"
STATE_FILE="/tmp/remote_workspace.state"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

MODE="${1:-}"
# Default to interactive if no mode provided
if [[ "$MODE" != "--background" && "$MODE" != "--status" && "$MODE" != "--wakeup" ]]; then
    MODE="--interactive"
fi

# ------------------------------------------------------------------------------
# 1. State & Logging
# ------------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
if [ -f "$LOG_FILE" ]; then
    FILE_SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -gt 1048576 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
fi

log_msg() {
    local level=$1
    local state=$2
    local msg=$3
    local ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    echo "[$ts] [$level] [$state] $msg" >> "$LOG_FILE"
    if [ "$MODE" == "--status" ]; then
        echo "[$ts] [$level] [$state] $msg"
    fi
}

notify_user() {
    local msg=$1
    # Escape for osascript
    msg="${msg//\\/\\\\}"
    msg="${msg//\"/\\\"}"
    osascript -e "display notification \"$msg\" with title \"Remote Workspace\""
}

# Read persistent background state
LAST_STATE="UNKNOWN"
FAIL_COUNT=0
LAST_RUN=0
if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE" 2>/dev/null || true
fi

write_state() {
    local new_state=$1
    local new_fail=$2
    local now=$(date +%s)
    echo "LAST_STATE=\"$new_state\"" > "$STATE_FILE"
    echo "FAIL_COUNT=$new_fail" >> "$STATE_FILE"
    echo "LAST_RUN=$now" >> "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# 2. Diagnostic Status Mode (--status)
# ------------------------------------------------------------------------------
if [ "$MODE" == "--status" ]; then
    echo "Remote Workspace Diagnostics"
    echo "────────────────────────────"
    if ping -c 1 -t 2 "$SERVER" >/dev/null 2>&1; then echo "Network       OK"; else echo "Network       FAIL"; fi
    if nc -z -w 3 "$SERVER" 445 >/dev/null 2>&1; then echo "SMB 445       OK"; else echo "SMB 445       FAIL"; fi
    if mount -t smbfs | awk '{print $3}' | grep -Fx "$MOUNT_DIR" >/dev/null; then echo "Mount         OK"; else echo "Mount         ABSENT"; fi
    if stat "$MOUNT_DIR" >/dev/null 2>&1; then echo "Filesystem    OK"; else echo "Filesystem    STALE/ABSENT"; fi
    if stat "$VERIFY_DIR" >/dev/null 2>&1; then echo "Verify dir    OK"; else echo "Verify dir    ABSENT"; fi
    echo "Background    Last State: $LAST_STATE, Fails: $FAIL_COUNT"
    exit 0
fi

# ------------------------------------------------------------------------------
# 3. Bounded Execution
# ------------------------------------------------------------------------------
run_with_timeout() {
    local timeout=$1
    shift
    "$@" >/dev/null 2>&1 &
    local pid=$!
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$elapsed" -ge "$timeout" ]; then
            kill -15 "$pid" 2>/dev/null
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            # Return timeout explicitly, do not wait (prevents parent hang on kernel D-state).
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pid" 2>/dev/null
    return $?
}

# ------------------------------------------------------------------------------
# 4. Concurrency Lock
# ------------------------------------------------------------------------------
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$PID_FILE"
        rm -f "$PENDING_FILE"
        return 0
    fi

    # Lock exists. Validate owner identity.
    if [ -f "$PID_FILE" ]; then
        local lock_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            local cmd=$(ps -p "$lock_pid" -o args= 2>/dev/null || true)
            if [[ "$cmd" == *"auto-mount-smb.sh"* ]]; then
                # Leave a note so the running owner re-checks once it finishes.
                touch "$PENDING_FILE"
                # The owner may have released the lock in the meantime; if so, take over.
                if mkdir "$LOCK_DIR" 2>/dev/null; then
                    echo "$$" > "$PID_FILE"
                    rm -f "$PENDING_FILE"
                    return 0
                fi
                log_msg "INFO" "QUEUED" "Run in progress (PID $lock_pid). Re-check queued."
                if [ "$MODE" == "--interactive" ]; then
                    notify_user "Another workspace operation is running."
                fi
                exit 0
            fi
        fi
    fi

    log_msg "WARN" "LOCKED" "Stale lock detected (owner absent/invalid). Replacing."
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$PID_FILE"
        rm -f "$PENDING_FILE"
        return 0
    else
        log_msg "ERROR" "LOCKED" "Failed to acquire lock"
        exit 1
    fi
}
acquire_lock

# On exit, release the lock. If a wake-up arrived while we were running, run once more
# (exec keeps us inside the same launchd job, so the re-run isn't killed with it).
NO_RERUN=false
on_exit() {
    rm -rf "$LOCK_DIR"
    if [ "$NO_RERUN" = false ] && [ -f "$PENDING_FILE" ]; then
        rm -f "$PENDING_FILE"
        log_msg "INFO" "RERUN" "Wake-up arrived during run. Re-checking."
        sleep 2
        exec /bin/bash "$SCRIPT_PATH" --background
    fi
}
trap on_exit EXIT
trap 'NO_RERUN=true; exit 130' INT TERM HUP

log_msg "INFO" "INIT" "Reconciliation controller started (Mode: $MODE)"

# ------------------------------------------------------------------------------
# Transition Handling
# ------------------------------------------------------------------------------
fail_transition() {
    local state=$1
    local reason=$2
    log_msg "ERROR" "$state" "$reason"

    local new_fail=$((FAIL_COUNT + 1))

    # Notify ONLY on the first persistent failure
    if [ "$LAST_STATE" == "HEALTHY" ] || [ "$LAST_STATE" == "UNKNOWN" ] || [ "$MODE" == "--interactive" ]; then
        if [ "$MODE" == "--background" ]; then
            notify_user "Remote Workspace unavailable. Automatic recovery is waiting for connectivity."
        else
            notify_user "Workspace unavailable: $reason"
        fi
    fi

    write_state "FAILED" "$new_fail"
    exit 1
}

# ------------------------------------------------------------------------------
# 5. Network Reconnaissance
# ------------------------------------------------------------------------------
if ! run_with_timeout 3 ping -c 1 -t 2 "$SERVER"; then
    log_msg "WARN" "NETWORK_UNAVAILABLE" "Ping to $SERVER failed"
    fail_transition "NETWORK_UNAVAILABLE" "Cannot reach $SERVER."
fi

if ! run_with_timeout 3 nc -z -w 3 "$SERVER" 445; then
    log_msg "WARN" "SMB_UNAVAILABLE" "TCP 445 on $SERVER is closed"
    fail_transition "SMB_UNAVAILABLE" "Server reachable, but SMB port is unavailable."
fi

# ------------------------------------------------------------------------------
# 6. Mount State Discovery
# ------------------------------------------------------------------------------
IS_MOUNTED=false
if mount -t smbfs | awk '{print $3}' | grep -Fx "$MOUNT_DIR" >/dev/null; then
    IS_MOUNTED=true
fi

# ------------------------------------------------------------------------------
# 7. Ghost & Stale Handling
# ------------------------------------------------------------------------------
if [ "$IS_MOUNTED" = true ]; then
    # Debounced Health Check (3 strikes)
    STALE=true
    for i in 1 2 3; do
        if run_with_timeout 3 stat "$MOUNT_DIR" >/dev/null; then
            STALE=false
            break
        fi
        log_msg "WARN" "MOUNT_DEGRADED" "stat failed ($i/3). Debouncing..."
        sleep 2
    done

    if [ "$STALE" = true ]; then
        log_msg "WARN" "MOUNT_STALE" "3 consecutive failures. Escalating to recovery."
        if run_with_timeout 15 diskutil unmount force "$MOUNT_DIR"; then
            log_msg "INFO" "RECOVERING" "Forced unmount succeeded."
            IS_MOUNTED=false
            sleep 2
        else
            fail_transition "FAILED" "Stale mount could not be safely force-unmounted."
        fi
    fi
else
    # Check Ghost Directory
    if [ -d "$MOUNT_DIR" ]; then
        if ! mount | awk '{print $3}' | grep -Fx "$MOUNT_DIR" >/dev/null; then
            if [ -z "$(ls -A "$MOUNT_DIR" 2>/dev/null)" ]; then
                log_msg "INFO" "GHOST_DIRECTORY" "Empty ghost directory confirmed. Removing."
                if rmdir "$MOUNT_DIR" 2>/dev/null; then
                    log_msg "INFO" "RECOVERING" "Removed ghost directory successfully."
                else
                    fail_transition "FAILED" "Failed to rmdir empty ghost directory."
                fi
            else
                fail_transition "FAILED" "Ghost directory $MOUNT_DIR is not empty. Safety abort."
            fi
        fi
    elif [ -e "$MOUNT_DIR" ]; then
        fail_transition "FAILED" "$MOUNT_DIR exists but is not a directory."
    fi
fi

# ------------------------------------------------------------------------------
# 8. Normal Mount
# ------------------------------------------------------------------------------
if [ "$IS_MOUNTED" = false ]; then
    log_msg "INFO" "RECOVERING" "Executing osascript mount volume..."
    run_with_timeout 15 osascript -e "mount volume \"$SMB_URL\""
    M_STAT=$?

    if [ $M_STAT -ne 0 ]; then
        if [ $M_STAT -eq 124 ]; then
            if [ "$MODE" == "--interactive" ] || [ "$FAIL_COUNT" -eq 0 ]; then
                notify_user "SMB authentication is required. Connect once via Finder → Go → Connect to Server."
            fi
            fail_transition "FAILED" "SMB authentication timeout."
        else
            fail_transition "FAILED" "osascript mount failed (Code $M_STAT)."
        fi
    fi
    sleep 2 # DiskArbitration settling delay
fi

# ------------------------------------------------------------------------------
# 9. Final Verification
# ------------------------------------------------------------------------------
if ! mount -t smbfs | awk '{print $3}' | grep -Fx "$MOUNT_DIR" >/dev/null; then
    fail_transition "FAILED" "Mount command succeeded but smbfs path is absent."
fi

log_msg "INFO" "VERIFYING" "Validating $VERIFY_DIR readability..."
if ! run_with_timeout 3 stat "$VERIFY_DIR" >/dev/null; then
    fail_transition "FAILED" "$VERIFY_DIR is missing or unreadable."
fi

# ------------------------------------------------------------------------------
# 10. HEALTHY State Reached
# ------------------------------------------------------------------------------
log_msg "INFO" "HEALTHY" "Reconciliation complete. System is in desired state."

if [ "$LAST_STATE" != "HEALTHY" ] && [ "$MODE" == "--background" ]; then
    notify_user "Remote Workspace recovered. SMB connection is healthy."
fi

write_state "HEALTHY" "0"

if [ "$MODE" == "--interactive" ]; then
    if [ "$IS_MOUNTED" = false ]; then
        notify_user "Remote Workspace recovered. Opening $EDITOR_APP."
    else
        notify_user "Remote Workspace connected. Opening $EDITOR_APP."
    fi
    log_msg "INFO" "LAUNCH" "Interactive mode invoking $EDITOR_APP"
    open -a "$EDITOR_APP" "$VERIFY_DIR"
fi

exit 0
