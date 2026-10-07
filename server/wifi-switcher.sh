#!/bin/bash
# Switches this server to a clearly stronger saved Wi-Fi network when the current one stays weak.
# Event-driven: sleeps until NetworkManager reports a signal-strength change, and only keeps a
# short timer while the signal is weak.
IFACE="${IFACE:-wlp6s0}"        # Wi-Fi interface (see: nmcli dev)
WEAK_BELOW="${WEAK_BELOW:-45}"         # signal % (about -78 dBm) under which the connection counts as weak
WEAK_FOR="${WEAK_FOR:-20}"           # seconds the signal must stay weak before acting
BETTER_BY="${BETTER_BY:-20}"          # another saved network must be at least this many points stronger
COOLDOWN="${COOLDOWN:-180}"          # seconds to wait after a switch before switching again
SCAN_EVERY="${SCAN_EVERY:-30}"         # seconds between rescans while the signal is weak
QUIET="${QUIET:-2}"               # seconds without new events before evaluating
DRY_RUN="${DRY_RUN:-0}"   # 1 = log what would happen, never switch

log() { echo "$*"; }

# Connection names are assumed to equal their SSID (the NetworkManager default for Wi-Fi).
saved_networks() { nmcli -t -f NAME,TYPE con show | sed -n 's/:802-11-wireless$//p'; }

# Prints "<ssid> <signal>" lines for the strongest AP of every SSID in range.
visible_networks() {
    nmcli -t -f SSID,SIGNAL dev wifi list ifname "$IFACE" --rescan no \
        | sed 's/\\:/:/g' \
        | while IFS= read -r line; do echo "${line%:*}"$'\t'"${line##*:}"; done \
        | sort -t$'\t' -k1,1 -k2,2nr | awk -F'\t' '!seen[$1]++ && $1 != ""'
}

current_network() {   # "<ssid>\t<signal>" of the active AP, empty if not connected
    nmcli -t -f ACTIVE,SSID,SIGNAL dev wifi list ifname "$IFACE" --rescan no \
        | sed -n 's/^yes://p' | sed 's/\\:/:/g' \
        | while IFS= read -r line; do echo "${line%:*}"$'\t'"${line##*:}"; done | head -1
}

weak_since=-1
last_switch=-999999
last_scan=-999999

evaluate() {
    local cur ssid sig
    cur=$(current_network)
    [[ -z "$cur" ]] && { weak_since=-1; return; }   # not connected: NetworkManager handles it
    ssid="${cur%%$'\t'*}"; sig="${cur##*$'\t'}"

    if (( sig >= WEAK_BELOW )); then
        (( weak_since >= 0 )) && log "Signal on '$ssid' recovered to ${sig}%"
        weak_since=-1
        return
    fi
    (( weak_since < 0 )) && { weak_since=$SECONDS; log "Signal on '$ssid' is weak (${sig}%); watching"; }
    (( SECONDS - weak_since < WEAK_FOR )) && return

    if (( SECONDS - last_scan >= SCAN_EVERY )); then
        last_scan=$SECONDS
        nmcli dev wifi rescan ifname "$IFACE" >/dev/null 2>&1 || log "Rescan not permitted (see server/50-wifi-switcher.rules)"
        return   # results arrive asynchronously; decide on the next evaluation
    fi
    (( SECONDS - last_switch < COOLDOWN )) && return

    local best="" best_sig=0 name nsig
    while IFS=$'\t' read -r name nsig; do
        [[ "$name" == "$ssid" ]] && continue
        grep -qxF -- "$name" <(saved_networks) || continue
        (( nsig > best_sig )) && { best="$name"; best_sig=$nsig; }
    done < <(visible_networks)

    if [[ -n "$best" ]] && (( best_sig >= sig + BETTER_BY )); then
        log "Switching '$ssid' (${sig}%) -> '$best' (${best_sig}%)"
        last_switch=$SECONDS; weak_since=-1
        if [[ "$DRY_RUN" == "1" ]]; then log "(dry run, not switching)"; return; fi
        nmcli -w 20 con up id "$best" ifname "$IFACE" >/dev/null 2>&1 \
            && log "Switched to '$best'" || log "Switch to '$best' failed"
    fi
}

evaluate
while true; do
    if (( weak_since >= 0 )); then to=5; else to=0; fi
    if (( to > 0 )); then read -r -t "$to" _ ; else read -r _; fi
    rc=$?
    if (( rc == 0 )); then
        while read -r -t "$QUIET" _; do :; done   # swallow the rest of the burst
    elif (( rc <= 128 )); then
        exit 1   # EOF: dbus-monitor stopped; systemd restarts us
    fi
    evaluate
done < <(dbus-monitor --system "type='signal',sender='org.freedesktop.NetworkManager',member='PropertiesChanged'" \
            | grep --line-buffered '"Strength"')
