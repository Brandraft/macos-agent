# macos-agent

Set up a dedicated Mac for coding agents under one account with full passwordless sudo. Supports macOS 14 or newer on Apple silicon and Intel. Run the initial setup in the Mac's local Terminal.

This is for a machine you can rebuild. Every process under the account can become root. Keep personal data and your main password vault off it. Command approval checks do not contain malicious dependencies.

## Download and run

Download the repository without needing Git or Command Line Tools:

```bash
curl --fail --location --proto '=https' \
  https://github.com/brandraft/macos-agent/archive/refs/heads/main.tar.gz \
  -o macos-agent.tar.gz
tar -xzf macos-agent.tar.gz
cd macos-agent-main
bash setup.sh plan
```

Copy the **public** SSH key from the computer you will use to access this Mac into a file on the Mac. Keep the private key on the connecting computer. The script accepts one plain OpenSSH public key and preserves existing authorized keys.

Read `setup.sh` and `lib/network.sh`, then run:

```bash
bash setup.sh apply --ssh-key ~/Downloads/agent-access.pub
```

The current account must already be able to use sudo, as the first macOS administrator account normally can. Enter any initial sudo password only into your own local Terminal. Do not run the whole script with sudo.

You can rerun this command after a failed download or interrupted install. `--skip-tools` and `--skip-tailscale` skip those installations. Existing mise and Tailscale installations are preserved. Other changes are applied again, with backups.

## What apply changes

- Grants the current account passwordless sudo in `/etc/sudoers.d/90-macos-agent`. It creates no accounts.
- Adds the public key and configures SSH to accept public keys only, for the current account. Root login, SSH agent forwarding, and X11 forwarding are disabled. TCP forwarding remains available for remote development.
- Installs mise under `~/.local/bin` and installs Node 24, pnpm 10, GitHub CLI, jq, and ripgrep. Tool installation runs as the account user.
- Installs the Standalone Tailscale package if `/Applications/Tailscale.app` is absent. The bootstrap downloads have pinned versions and SHA-256 hashes. macOS also checks the Tailscale installer signature and Gatekeeper assessment. This does not pin the later mise-managed tool downloads.
- Prepends tool paths to zsh and bash startup files so noninteractive SSH commands can find the tools.
- Disables idle system sleep on AC power and sets display sleep to ten minutes. Battery settings stay unchanged. Keep the lid open.
- Enables automatic software update checks, downloads, security data, and critical updates. It does not initiate an OS upgrade or reboot.
- Installs generic agent instructions in `/etc/macos-agent/AGENTS.md` and links them into the home, Codex, and Claude instruction locations when those locations are empty.

Backups go to `~/.local/state/macos-agent/backups/`. The script preserves existing instruction files. It does not install agent applications, Homebrew, Xcode, a container VM, or an always-running worker. Install the tools required by your workload afterward.

## Finish on the Mac

1. Open Tailscale, approve the system extension, and sign in. Use the Tailscale admin console to assign a server tag and restrict connections initiated by that tag. The script does not change your tailnet policy. If you have the App Store variant installed, follow Tailscale's migration instructions instead of installing another variant over it.
2. In System Settings > General > Sharing, turn on Remote Login for your account. Leave full disk access for remote users off unless needed. macOS may require this UI step even when sudo is available.
3. Turn on FileVault in Privacy & Security if needed. Store its recovery key outside the Mac. The script never reads it. Verify how you will unlock the Mac after a restart before leaving it unattended.
4. Apply network isolation below.
5. Install and authenticate your agent applications. Use scoped credentials and check access after logout and reboot.

Until the network step, Remote Login may be reachable on the local network. It still requires an authorized SSH key.

## Network isolation

Do this in the local Terminal after Tailscale is connected. Supply your router's IPv4 address, or the IPv4 DNS resolver your Mac uses. Use your actual address in place of `DNS_IPV4`:

```bash
bash setup.sh network --dns-server DNS_IPV4
```

The command creates a PF anchor and a boot LaunchDaemon. It preserves the existing Apple anchor declarations. A separate LaunchDaemon restores the previous configuration after 180 seconds unless you confirm it.

From another device, open a **new** SSH connection to the Mac's Tailscale address. First check that DNS and internet access work on the Mac. Then, inside that new SSH session:

```bash
cd ~/macos-agent-main
bash setup.sh confirm-network
```

Adjust the checkout path if you extracted it elsewhere. An old SSH connection is not a valid connectivity test because existing PF states can survive rule changes. If the new connection fails, wait for rollback or run locally:

```bash
bash setup.sh rollback-network
```

Rules allow tailnet traffic and block other unsolicited inbound traffic, with exceptions for loopback, DHCP, IPv6 neighbor discovery, and UDP 41641. Outbound internet is allowed. RFC1918 IPv4, IPv4 link-local, private IPv6, and IPv6 link-local destinations are blocked except the chosen IPv4 DNS server on port 53, DHCP, neighbor discovery, tailnet IPv6, and UDP from port 41641.

These exceptions matter. A process can use the UDP port exception. PF does not identify the Tailscale process. Tailscale may also use other UDP ports and fall back to relays. The rules do not block publicly addressed hosts on your LAN, and the chosen DNS exception does not follow you to another network. IPv6-only DNS on a private router requires adapting the rules. This configuration targets a stationary host with IPv4 DNS.

Tailnet grants must separately block connections from this Mac to your personal devices. A router or VLAN must enforce LAN isolation if you need it to survive root compromise. This script's PF rules cannot provide that guarantee to an account with passwordless sudo.

## Recovery and inspection

```bash
bash setup.sh status
sudo pfctl -a macos-agent -sr
sudo /usr/sbin/sshd -T
```

For a pending firewall change, use `rollback-network`. To remove a confirmed firewall setup locally, unload its boot job, remove the two `macos-agent` anchor lines from `/etc/pf.conf`, validate with `sudo pfctl -nf /etc/pf.conf`, then reload it. Preserve Apple's declarations. Keep a local Terminal available during this work.

The network snapshot is in `/var/db/macos-agent-network/`, owned by root. Network rollback restores the previous PF files and boot job. It leaves PF enabled because another macOS service may depend on it. It does not restore closed or changed connections.

For base setup, use the timestamped backups to restore individual files. Record the original power settings from `power-settings.txt` before changing them back with `pmset`. There is no blanket uninstall command because later edits may belong to you or another tool.

## Validation

```bash
bash tests/check.sh
shellcheck setup.sh lib/network.sh tests/*.sh
```

Local validation covers shell syntax, ShellCheck, invalid input rejection, and simulated firewall failure and rollback paths. The macOS CI job has also passed PF and plist parsing, base setup with package installation skipped, SSH configuration checks, and a second setup run without duplicate changes. Live packet filtering and target Mac recovery have not been tested.

`.github/workflows/check.yml` runs on every push and pull request. It runs shell checks on Linux, parses the generated PF rules and launchd plist on macOS, and runs base setup twice on a disposable macOS runner with tool downloads skipped. The smoke test modifies that runner's sudoers, SSH, power, update, and shell settings. It refuses to run outside macOS GitHub Actions.

CI does not test an actual Tailscale connection, PF packet filtering, FileVault recovery, sleep behavior, or package installation. Those require checks on the target Mac. Do not treat a successful CI run as proof of network isolation.

## References

- [Apple Remote Login](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac)
- [Apple launchd guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [Tailscale macOS variants](https://tailscale.com/docs/concepts/macos-variants)
- [Tailscale package checksums](https://pkgs.tailscale.com/stable/)
- [mise installation](https://mise.jdx.dev/installing-mise.html)
- [mise shims](https://mise.jdx.dev/dev-tools/shims.html)
