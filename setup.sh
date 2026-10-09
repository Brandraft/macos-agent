#!/bin/bash
# macOS ships Bash 3.2. Keep this script compatible with it.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-plan}
[ "$#" -eq 0 ] || shift
KEY_FILE=
DNS_SERVER=
SKIP_TOOLS=0
SKIP_TAILSCALE=0

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage:
  bash setup.sh plan
  bash setup.sh apply --ssh-key /path/to/key.pub [--skip-tools] [--skip-tailscale]
  bash setup.sh network --dns-server ROUTER_IPV4
  bash setup.sh confirm-network
  bash setup.sh rollback-network
  bash setup.sh status

Run apply from the Mac's local Terminal, as the account that will run agents.
It grants that account full passwordless sudo. The first sudo prompt stays local.
Network isolation is a separate step after signing into Tailscale.
EOF
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ssh-key) [ "$#" -ge 2 ] || die 'Missing SSH key path'; KEY_FILE=$2; shift 2 ;;
        --dns-server) [ "$#" -ge 2 ] || die 'Missing DNS server'; DNS_SERVER=$2; shift 2 ;;
        --skip-tools) SKIP_TOOLS=1; shift ;;
        --skip-tailscale) SKIP_TAILSCALE=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done
case "$MODE" in
    plan|--dry-run)
        cat <<'EOF'
Plan only. No files, packages, privileges, or network settings change.

apply:
  Use the current account. Create no other accounts.
  Grant full passwordless sudo after validating the sudoers file.
  Back up changed files under ~/.local/state/macos-agent/backups/.
  Append the supplied public key, preserving existing authorized keys.
  Configure SSH for public keys only and restrict it to the current account.
  Install pinned, SHA-256-checked mise and signed Tailscale packages if missing.
  Install Node 24, pnpm 10, gh, jq, and ripgrep through mise.
  Add user tool paths for zsh and bash, including noninteractive SSH.
  Keep the Mac awake on AC power; let the display sleep after 10 minutes.
  Enable automatic update checks and security data updates.
  Install shared agent instructions without overwriting existing instructions.
  Report the remaining Tailscale, Remote Login, and FileVault GUI steps.

network, after Tailscale sign-in:
  Block unsolicited inbound traffic except tailnet traffic, DHCP, IPv6 neighbor
  discovery, and UDP 41641 for Tailscale transport.
  Block outbound RFC1918, link-local, and private IPv6 destinations, with
  exceptions for your chosen IPv4 DNS server, DHCP, and tailnet IPv6.
  Preserve Apple's pf configuration and add a separate anchor.
  Arm a 180-second rollback. Confirm from a fresh SSH session to keep the rules.

The script does not configure tailnet grants, enable FileVault, install agent
applications, install Homebrew, create a VM, or reboot the Mac.
EOF
        exit 0 ;;
    --help|-h|help) usage; exit 0 ;;
    apply|network|confirm-network|rollback-network|status) ;;
    *) usage; die "Unknown command: $MODE" ;;
esac

[ "$(uname -s)" = Darwin ] || die 'This command requires macOS. Use plan on other systems.'
[ "$(id -u)" -ne 0 ] || die 'Run this as your normal account, without sudo.'
ACCOUNT=$(id -un)
[[ "$ACCOUNT" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || die 'Unsupported account name'
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 14 ] || die 'macOS 14 or newer is required.'
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale

if [ "$MODE" = status ]; then
    printf 'Account: %s\n' "$ACCOUNT"
    if sudo -n true 2>/dev/null; then echo 'Passwordless sudo: available'; else echo 'Passwordless sudo: unavailable'; fi
    /usr/bin/fdesetup status
    /usr/bin/pmset -g custom
    if [ -x "$TS" ]; then "$TS" status; else echo 'Tailscale: not installed'; fi
    if [ -e /var/db/macos-agent-network/pending ]; then echo 'Firewall: pending confirmation'; fi
    if sudo -n true 2>/dev/null; then
        sudo /sbin/pfctl -s info
        sudo /sbin/pfctl -a macos-agent -sr
        sudo /usr/sbin/sshd -T | /usr/bin/grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers) '
    fi
    exit 0
fi

if [ "$MODE" = confirm-network ] || [ "$MODE" = rollback-network ]; then
    [ -x /usr/local/libexec/macos-agent-network ] || die 'Network helper is not installed'
    if [ "$MODE" = confirm-network ]; then
        [ -n "${SSH_CONNECTION:-}" ] || die 'Confirm from a fresh SSH session over Tailscale.'
        printf '%s\n' "${SSH_CONNECTION%% *}" | grep -Eq '^(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|fd7a:115c:a1e0:)' || die 'This does not appear to be a Tailscale SSH connection.'
        sudo /usr/local/libexec/macos-agent-network confirm
    else
        sudo /usr/local/libexec/macos-agent-network rollback
    fi
    exit 0
fi

# Initial setup and firewall activation happen at the physical Mac so SSH
# configuration mistakes cannot take away the only way to recover.
[ -z "${SSH_CONNECTION:-}" ] || die 'Run this step in the Mac local Terminal, not over SSH.'
if [ "$MODE" = network ]; then
    [ -n "$DNS_SERVER" ] || die 'Supply --dns-server with the router or resolver IPv4 address.'
    [ -x "$TS" ] || die 'Install Tailscale first.'
    "$TS" ip -4 | grep -Eq '^100\.' || die 'Sign into Tailscale first.'
    sudo /bin/bash "$ROOT_DIR/lib/network.sh" install "$DNS_SERVER"
    exit 0
fi

[ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] || die 'Supply --ssh-key with a public key file.'
# Accept exactly one plain public key, not a private key or authorized_keys options.
[ "$(awk 'NF {n++} END {print n+0}' "$KEY_FILE")" -eq 1 ] || die 'Supply exactly one public key.'
grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( .*)?$' "$KEY_FILE" || die 'Expected a plain OpenSSH public key.'
ssh-keygen -l -f "$KEY_FILE" >/dev/null || die 'Invalid SSH public key.'
SHELL_PATH=$(dscl . -read "/Users/$ACCOUNT" UserShell | awk '{print $2}')
case "$SHELL_PATH" in /bin/zsh|/bin/bash) ;; *) die 'Use the macOS zsh or bash login shell before setup.' ;; esac
[ -z "${ZDOTDIR:-}" ] || die 'Custom ZDOTDIR is not supported; configure shell paths manually.'

umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/macos-agent.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
BACKUP="$HOME/.local/state/macos-agent/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BACKUP"
backup() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        local name
        name=$(printf '%s' "$1" | sed 's|/|_|g')
        sudo cp -pP "$1" "$BACKUP/$name"
    fi
}
download() { /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 3 "$1" -o "$2"; }
check_sha() { printf '%s  %s\n' "$1" "$2" | /usr/bin/shasum -a 256 -c -; }

printf 'Setting up account %s. Backups: %s\n' "$ACCOUNT" "$BACKUP"
# Authenticate before running downloaded programs. Never collect the password.
sudo -v
sudo /usr/sbin/visudo -cf /etc/sudoers >/dev/null
grep -Eq '^[#@]includedir[[:space:]]+/private/etc/sudoers.d|^[#@]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers 2>/dev/null || sudo grep -Eq '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers.d' /etc/sudoers || die 'sudoers does not include /etc/sudoers.d.'
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$ACCOUNT" > "$WORK/sudoers"
sudo /usr/sbin/visudo -cf "$WORK/sudoers" >/dev/null
backup /etc/sudoers.d/90-macos-agent
sudo install -d -m 755 /etc/sudoers.d
sudo install -o root -g wheel -m 440 "$WORK/sudoers" /etc/sudoers.d/90-macos-agent
if ! sudo /usr/sbin/visudo -cf /etc/sudoers >/dev/null; then
    if [ -f "$BACKUP/_etc_sudoers.d_90-macos-agent" ]; then
        sudo cp -p "$BACKUP/_etc_sudoers.d_90-macos-agent" /etc/sudoers.d/90-macos-agent
    else
        sudo rm /etc/sudoers.d/90-macos-agent
    fi
    die 'sudoers validation failed; restored previous grant.'
fi
sudo -k
sudo -n true || die 'Passwordless sudo did not take effect.'

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
backup "$HOME/.ssh/authorized_keys"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
KEY=$(awk 'NF' "$KEY_FILE")
if ! awk -v blob="$(awk 'NF {print $2}' "$KEY_FILE")" '
    /^[[:space:]]*#/ {next}
    {for (i=1; i<NF; i++) if ($i ~ /^(ssh-|ecdsa-)/ && $(i+1) == blob) found=1}
    END {exit !found}
' "$HOME/.ssh/authorized_keys"; then
    printf '\nno-agent-forwarding,no-X11-forwarding %s\n' "$KEY" >> "$HOME/.ssh/authorized_keys"
fi

# Prepending an Include puts our values before Apple's defaults. sshd uses
# the first value it sees for most settings. Keep all previous configuration.
SSH_DROP=/etc/ssh/sshd_config.d/000-macos-agent.conf
backup /etc/ssh/sshd_config
backup "$SSH_DROP"
cat > "$WORK/sshd-agent.conf" <<EOF
# Managed by macos-agent. Existing sessions stay open.
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $ACCOUNT
AllowAgentForwarding no
X11Forwarding no
EOF
sudo install -d -m 755 /etc/ssh/sshd_config.d
sudo install -o root -g wheel -m 644 "$WORK/sshd-agent.conf" "$SSH_DROP"
{ printf 'Include %s\n' "$SSH_DROP"; sudo cat /etc/ssh/sshd_config; } | awk '!seen[$0]++ || $0 != "Include /etc/ssh/sshd_config.d/000-macos-agent.conf"' > "$WORK/sshd_config"
sudo install -o root -g wheel -m 644 "$WORK/sshd_config" /etc/ssh/sshd_config
sudo ssh-keygen -A
if ! sudo /usr/sbin/sshd -t; then
    sudo cp -p "$BACKUP/_etc_ssh_sshd_config" /etc/ssh/sshd_config
    if [ -f "$BACKUP/_etc_ssh_sshd_config.d_000-macos-agent.conf" ]; then
        sudo cp -p "$BACKUP/_etc_ssh_sshd_config.d_000-macos-agent.conf" "$SSH_DROP"
    else
        sudo rm "$SSH_DROP"
    fi
    die 'sshd validation failed; restored previous SSH configuration.'
fi

if [ "$SKIP_TOOLS" -eq 0 ]; then
    mkdir -p "$HOME/.local/bin"
    if [ ! -x "$HOME/.local/bin/mise" ]; then
        case "$(uname -m)" in
            arm64) ARCH=arm64; SHA=bbcea7b0f844d026424a4c8335357a15a2f5c9e9132c9408de990d9be6f26101 ;;
            x86_64) ARCH=x64; SHA=70e1407e2fdc7a19f94db35745a8e5885b0e4bbdbfb34bfb7e3619d6230a8f70 ;;
            *) die 'Unsupported CPU architecture' ;;
        esac
        download "https://github.com/jdx/mise/releases/download/v2026.10.6/mise-v2026.10.6-macos-$ARCH" "$WORK/mise"
        check_sha "$SHA" "$WORK/mise"
        install -m 755 "$WORK/mise" "$HOME/.local/bin/mise"
    fi
    export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
    backup "$HOME/.config/mise/config.toml"
    # Run outside any project to avoid executing project-specific mise hooks.
    (cd "$WORK"; "$HOME/.local/bin/mise" use --global node@24 pnpm@10 gh@latest jq@latest ripgrep@latest)
fi

cat > "$WORK/shell-path" <<'EOF'
# macos-agent tool paths
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
EOF
for rc in .zshenv .zprofile .bashrc .bash_profile; do
    if ! grep -Fq '# macos-agent tool paths' "$HOME/$rc" 2>/dev/null; then
        backup "$HOME/$rc"
        # Prepend so a noninteractive .bashrc return cannot hide the PATH setup.
        {
            cat "$WORK/shell-path"
            if [ -f "$HOME/$rc" ]; then
                cat "$HOME/$rc"
            elif [ "$rc" = .bash_profile ]; then
                # Creating .bash_profile must not hide an older login profile.
                if [ -f "$HOME/.bash_login" ]; then
                    # shellcheck disable=SC2016
                    printf '[ ! -f "$HOME/.bash_login" ] || . "$HOME/.bash_login"\n'
                elif [ -f "$HOME/.profile" ]; then
                    # shellcheck disable=SC2016
                    printf '[ ! -f "$HOME/.profile" ] || . "$HOME/.profile"\n'
                fi
            fi
        } > "$WORK/rc"
        cat "$WORK/rc" > "$HOME/$rc"
    fi
done

if [ "$SKIP_TAILSCALE" -eq 0 ] && [ ! -d /Applications/Tailscale.app ]; then
    download https://pkgs.tailscale.com/stable/Tailscale-1.104.1-macos.pkg "$WORK/tailscale.pkg"
    check_sha 67ec55f18ee2afac0a8fb57f7811977f4ad6df1debd4a187fa0db3dbb5d401d5 "$WORK/tailscale.pkg"
    /usr/sbin/pkgutil --check-signature "$WORK/tailscale.pkg"
    /usr/sbin/spctl --assess --type install "$WORK/tailscale.pkg"
    sudo /usr/sbin/installer -pkg "$WORK/tailscale.pkg" -target /
fi

/usr/bin/pmset -g custom > "$BACKUP/power-settings.txt"
sudo /usr/bin/pmset -c sleep 0 displaysleep 10
backup /Library/Preferences/com.apple.SoftwareUpdate.plist
sudo /usr/sbin/softwareupdate --schedule on
for setting in AutomaticCheckEnabled AutomaticDownload CriticalUpdateInstall ConfigDataInstall; do
    sudo /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate "$setting" -bool true
done

sudo install -d -m 755 /etc/macos-agent
if [ ! -e /etc/macos-agent/AGENTS.md ]; then
    sudo install -o root -g wheel -m 644 "$ROOT_DIR/AGENTS.template.md" /etc/macos-agent/AGENTS.md
fi
mkdir -p "$HOME/.codex" "$HOME/.claude"
for target in "$HOME/AGENTS.md" "$HOME/.codex/AGENTS.md" "$HOME/.claude/CLAUDE.md"; do
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        ln -s /etc/macos-agent/AGENTS.md "$target"
    else
        printf 'Kept existing instructions: %s\n' "$target"
    fi
done

cat <<EOF

Base setup completed for $ACCOUNT. Backups: $BACKUP

Finish these steps on the Mac:
1. Open Tailscale, approve its system extension, and sign in.
   Apply your server tag and tailnet grants in the Tailscale admin console.
2. In System Settings > General > Sharing, enable Remote Login for $ACCOUNT.
   Leave full disk access for remote users off unless a task needs it.
3. Enable FileVault in Privacy & Security if it is off. Keep its recovery key
   outside this Mac. This script never reads or stores the key.
4. Run: bash setup.sh network --dns-server YOUR_ROUTER_IPV4
   Then connect from another device over Tailscale and confirm the firewall.
5. Install and authenticate your preferred agent applications as this account.

Keep the lid open on AC power. Reboot and logout recovery still need testing.
No firewall restrictions are active until you complete step 4.
EOF
/usr/bin/fdesetup status
