#!/bin/bash
# Rings the Mac's doorbell (mac-listener on :4455) when this server's network changes.
# Waits for the burst of network events to settle, then rings every second until the Mac answers.
MAC_IP="100.x.y.z"   # the Mac's Tailscale IP
MAC_PORT="4455"
QUIET=2         # seconds without new network events before ringing
RETRY_FOR=300   # keep ringing (every 1s) for up to this many seconds

ring_until_answered() {
    local start=$SECONDS
    while (( SECONDS - start < RETRY_FOR )); do
        if nc -z -w 1 "$MAC_IP" "$MAC_PORT" 2>/dev/null; then
            echo "Mac answered after $((SECONDS - start))s"
            return 0
        fi
        sleep 1
    done
    echo "Mac did not answer for ${RETRY_FOR}s; waiting for next network change"
}

# Ring on startup
ring_until_answered

ip monitor address route | while true; do
    read -r line || exit 1   # ip monitor stopped; systemd restarts us
    # Swallow the rest of the burst: wait until QUIET seconds pass with no new events
    while read -r -t "$QUIET" line; do :; done
    echo "Network change settled; ringing Mac"
    ring_until_answered
done
