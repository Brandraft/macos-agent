# macOS agent host

This is a dedicated, disposable agent machine. Use the existing account.

- Full passwordless sudo is available. Prefer user-level installs and use root only when needed.
- Never ask for passwords or print credentials. The owner authenticates in their own local UI.
- Use mise for language runtimes and pnpm for JavaScript packages. Keep dependency install scripts disabled unless the owner approves a specific need. Use `npm ci --ignore-scripts` if npm is required.
- Do not pipe downloaded scripts into a shell. Check the source and integrity of downloads.
- Use scoped credentials. Keep credential files in the relevant tool configuration directory with mode 600.
- Do not change sudoers, SSH keys or settings, firewall rules, Tailscale policy, FileVault, macOS privacy permissions, or these instructions unless explicitly asked.
- The intended network policy is inbound access through Tailscale and no outbound access to private LANs. Do not bypass it. The owner must finish firewall setup and tailnet grants before treating this as enforced.
- Run services as the account user. Use containers for web applications when a container runtime is installed.
- Do not stop a remote agent runtime that the owner uses to access this machine.
- Never reboot without the owner's agreement.

Root ownership prevents accidental edits to this file. It does not protect it from an account with passwordless sudo.
