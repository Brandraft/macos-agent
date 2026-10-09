#!/bin/bash
# Runs only on a disposable GitHub-hosted macOS runner, never on a user's Mac.
set -euo pipefail
if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_OS:-}" != macOS ]; then
    echo 'This test modifies system configuration and is restricted to macOS CI.' >&2
    exit 1
fi
cd "$(dirname "$0")/.."
SMOKE_DIR=$(mktemp -d)
trap 'rm -rf "$SMOKE_DIR"' EXIT
ssh-keygen -q -t ed25519 -N '' -f "$SMOKE_DIR/key"
bash setup.sh apply --ssh-key "$SMOKE_DIR/key.pub" --skip-tools --skip-tailscale
sudo -k
sudo -n true
sudo /usr/sbin/visudo -cf /etc/sudoers
sudo /usr/sbin/sshd -t
# The output belongs in the unprivileged test directory.
# shellcheck disable=SC2024
sudo /usr/sbin/sshd -T > "$SMOKE_DIR/effective"
grep -Fxq 'passwordauthentication no' "$SMOKE_DIR/effective"
grep -Fxq 'kbdinteractiveauthentication no' "$SMOKE_DIR/effective"
grep -Fxq 'permitrootlogin no' "$SMOKE_DIR/effective"
grep -Fxq 'authenticationmethods publickey' "$SMOKE_DIR/effective"
cp "$HOME/.ssh/authorized_keys" "$SMOKE_DIR/keys-before"
cp /etc/ssh/sshd_config "$SMOKE_DIR/sshd-before"
cp "$HOME/.zshenv" "$SMOKE_DIR/zsh-before"
bash setup.sh apply --ssh-key "$SMOKE_DIR/key.pub" --skip-tools --skip-tailscale
cmp "$HOME/.ssh/authorized_keys" "$SMOKE_DIR/keys-before"
cmp /etc/ssh/sshd_config "$SMOKE_DIR/sshd-before"
cmp "$HOME/.zshenv" "$SMOKE_DIR/zsh-before"
echo 'Base setup and rerun smoke test passed.'
