#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

STATE=/var/db/macos-agent-network
HELPER=/usr/local/libexec/macos-agent-network
ANCHOR=/etc/pf.anchors/macos-agent
BOOT=/Library/LaunchDaemons/local.macos-agent.firewall.plist
WATCH=/Library/LaunchDaemons/local.macos-agent.rollback.plist

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
valid_ipv4() {
    local value=$1 octet
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local old_ifs=$IFS
    IFS=.
    for octet in $value; do
        if [ "${#octet}" -gt 3 ] || [ "$((10#$octet))" -gt 255 ]; then
            IFS=$old_ifs
            return 1
        fi
    done
    IFS=$old_ifs
}

render_rules() {
    valid_ipv4 "$1" || die 'DNS server must be a literal IPv4 address.'
    cat <<EOF
# Managed by macos-agent. Tailscale ACLs are configured separately.
table <private4> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }
pass quick on lo0 all
# Reserve the usual Tailscale UDP transport port as a firewall exception.
pass in quick proto udp from any to any port 41641 keep state
pass out quick proto udp from any port 41641 to any keep state
pass in quick inet proto udp from any port 67 to any port 68 keep state
pass out quick inet proto udp from any port 68 to any port 67 keep state
pass in quick inet6 proto udp from any port 547 to any port 546 keep state
pass out quick inet6 proto udp from any port 546 to any port 547 keep state
# IPv6 router/neighbor discovery must keep working for public IPv6 internet.
pass quick inet6 proto icmp6 icmp6-type { 133, 134, 135, 136 }
pass out quick inet proto { tcp, udp } to $1 port 53 keep state
# Tailnet IPv6 is inside fc00::/7, so it needs an exception before the LAN block.
pass out quick inet6 to fd7a:115c:a1e0::/48 keep state
block drop out quick inet to <private4>
block drop out quick inet6 to { fc00::/7, fe80::/10 }
pass in quick inet from 100.64.0.0/10 to 100.64.0.0/10 keep state
pass in quick inet6 from fd7a:115c:a1e0::/48 to fd7a:115c:a1e0::/48 keep state
pass out all keep state
block drop in quick all
EOF
}

render_plist() {
    local label=$1 action=$2
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$HELPER</string><string>$action</string></array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/var/log/macos-agent-network.log</string>
<key>StandardErrorPath</key><string>/var/log/macos-agent-network.log</string>
</dict></plist>
EOF
}

restore_file() {
    local name=$1 destination=$2
    if [ -f "$STATE/$name" ]; then cp -p "$STATE/$name" "$destination"; else rm -f "$destination"; fi
}
enable_pf() {
    if ! pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then pfctl -e; fi
}
rollback() {
    [ -f "$STATE/pending" ] || { echo 'No firewall change is pending.'; return; }
    mkdir "$STATE/decision" 2>/dev/null || die 'Another confirmation or rollback is in progress.'
    cp -p "$STATE/pf.conf" /etc/pf.conf
    restore_file anchor "$ANCHOR"
    launchctl bootout system/local.macos-agent.firewall 2>/dev/null || true
    restore_file boot.plist "$BOOT"
    pfctl -f /etc/pf.conf
    # Reloading the parent does not necessarily empty its old child anchor.
    if [ ! -f "$STATE/anchor" ]; then pfctl -a macos-agent -F rules; fi
    if [ -f "$BOOT" ]; then launchctl bootstrap system "$BOOT"; fi
    # Do not disable PF globally. Another macOS service may now depend on it.
    rm -f "$STATE/pending" "$WATCH"
    rmdir "$STATE/decision"
    echo 'Restored the previous firewall configuration. PF remains enabled.'
}

ACTION=${1:-help}
case "$ACTION" in
    render) [ "$#" -eq 2 ] || die 'render needs a DNS IPv4 address'; render_rules "$2"; exit 0 ;;
    render-plist) render_plist local.macos-agent.firewall boot; exit 0 ;;
esac
[ "$(uname -s)" = Darwin ] || die 'This command requires macOS.'
[ "$(id -u)" -eq 0 ] || die 'Run through setup.sh or sudo.'
case "$ACTION" in
    boot)
        pfctl -nf /etc/pf.conf
        pfctl -f /etc/pf.conf
        enable_pf
        ;;
    watch)
        sleep 180
        rollback
        ;;
    rollback)
        rollback
        launchctl bootout system/local.macos-agent.rollback 2>/dev/null || true
        ;;
    confirm)
        [ -f "$STATE/pending" ] || die 'No firewall change is pending.'
        mkdir "$STATE/decision" 2>/dev/null || die 'Rollback is already in progress.'
        # Validate again before making the change permanent.
        if ! pfctl -nf /etc/pf.conf; then rmdir "$STATE/decision"; die 'PF validation failed'; fi
        rm "$STATE/pending"
        rm -f "$WATCH"
        rmdir "$STATE/decision"
        launchctl bootout system/local.macos-agent.rollback 2>/dev/null || true
        echo 'Firewall confirmed. The boot job will load it after restart.'
        ;;
    install)
        [ "$#" -eq 2 ] || die 'install needs a DNS IPv4 address.'
        valid_ipv4 "$2" || die 'install needs a DNS IPv4 address.'
        [ ! -f "$STATE/pending" ] || die 'A firewall change is already pending. Confirm or roll it back first.'
        [ ! -d "$STATE/decision" ] || die 'A previous rollback needs attention. Inspect /var/db/macos-agent-network.'
        [ -f /etc/pf.conf ] || die '/etc/pf.conf is missing.'
        # This insertion point preserves Apple's NAT and normalization sections.
        grep -Fq 'anchor "com.apple/*"' /etc/pf.conf || die 'Custom pf.conf layout. Review it manually before installing.'
        umask 077
        mkdir -p "$STATE"
        chmod 700 "$STATE"
        cp -p /etc/pf.conf "$STATE/pf.conf"
        rm -f "$STATE/anchor" "$STATE/boot.plist"
        [ ! -f "$ANCHOR" ] || cp -p "$ANCHOR" "$STATE/anchor"
        [ ! -f "$BOOT" ] || cp -p "$BOOT" "$STATE/boot.plist"
        render_rules "$2" > "$STATE/new-anchor"
        pfctl -nf "$STATE/new-anchor"
        install -d -m 755 /usr/local/libexec
        if [ "$0" != "$HELPER" ]; then install -o root -g wheel -m 755 "$0" "$HELPER"; fi
        render_plist local.macos-agent.rollback watch > "$STATE/watch.plist"
        render_plist local.macos-agent.firewall boot > "$STATE/new-boot.plist"
        plutil -lint "$STATE/watch.plist" "$STATE/new-boot.plist"
        install -o root -g wheel -m 644 "$STATE/watch.plist" "$WATCH"
        touch "$STATE/pending"
        launchctl bootout system/local.macos-agent.rollback 2>/dev/null || true
        # Start the watchdog BEFORE touching the active firewall.
        if ! launchctl bootstrap system "$WATCH"; then
            rm -f "$STATE/pending" "$WATCH"
            die 'Could not start rollback timer; no firewall rules changed.'
        fi
        trap 'if [ "$?" -ne 0 ]; then rollback || true; fi' EXIT
        install -o root -g wheel -m 644 "$STATE/new-anchor" "$ANCHOR"
        awk '
            $0 == "anchor \"macos-agent\"" {next}
            $0 == "load anchor \"macos-agent\" from \"/etc/pf.anchors/macos-agent\"" {next}
            $0 == "anchor \"com.apple/*\"" {
                print "anchor \"macos-agent\""
                print "load anchor \"macos-agent\" from \"/etc/pf.anchors/macos-agent\""
            }
            {print}
        ' /etc/pf.conf > "$STATE/new-pf.conf"
        grep -Fxq 'anchor "macos-agent"' "$STATE/new-pf.conf" || die 'Could not insert the PF anchor.'
        pfctl -nf "$STATE/new-pf.conf"
        install -o root -g wheel -m 644 "$STATE/new-pf.conf" /etc/pf.conf
        install -o root -g wheel -m 644 "$STATE/new-boot.plist" "$BOOT"
        launchctl bootout system/local.macos-agent.firewall 2>/dev/null || true
        # Apply synchronously so errors reach the caller, then register boot loading.
        "$HELPER" boot
        launchctl bootstrap system "$BOOT"
        cat <<'EOF'
Firewall applied. It will roll back in 180 seconds unless confirmed.

Open a NEW SSH connection to this Mac's Tailscale address from another device.
In that new session, run this from your macos-agent checkout:
  bash setup.sh confirm-network

Before confirming, check internet access and DNS on the Mac. If access fails,
wait for rollback or run locally:
  bash setup.sh rollback-network

Existing connections may retain their PF states. Test using new connections.
EOF
        ;;
    *) die 'Unknown network action' ;;
esac
