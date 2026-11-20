# Waydroid Network Fixer for Omarchy

A cautious network repair and diagnostics utility for Waydroid on Arch Linux and Omarchy.

> **Important:** The repair script modifies host networking rules. Review the script before running it. It creates backups and does not flush firewall rules or change the default FORWARD policy.

## Features

- Detects the Waydroid bridge and active uplink interface.
- Enables IPv4 forwarding persistently.
- Adds narrowly-scoped IPv4 NAT masquerading for the Waydroid subnet.
- Adds narrowly-scoped forwarding rules for Waydroid traffic and established replies.
- Saves current firewall, route, interface, and selected sysctl state before changes.
- Provides diagnostics and basic connectivity checks.
- Displays Waydroid service logs.

## Requirements

- Arch Linux / Omarchy (other systemd-based distributions may work)
- Waydroid with the `waydroid0` bridge
- `iproute2`, `iptables`, `systemd`
- Optional: `nftables`, `resolvectl`, `curl`

Install missing tools on Arch:

```bash
sudo pacman -S iproute2 iptables curl
```

## Usage

Clone:

```bash
git clone https://github.com/sepahna/waydroid-network-fixer-omarchy.git
cd waydroid-network-fixer-omarchy
```

Run diagnostics first:

```bash
bash waydroid-network-fixer.sh diagnose
```

Repair:

```bash
sudo bash waydroid-network-fixer.sh repair
```

Run connectivity tests:

```bash
bash waydroid-network-fixer.sh test
```

Show recent Waydroid logs:

```bash
bash waydroid-network-fixer.sh logs
```

## Safety and limitations

- The tool does **not** flush iptables/nftables rules.
- The tool does **not** set global firewall policies to ACCEPT.
- It only adds rules scoped to the detected Waydroid subnet and uplink.
- It backs up current state under `/var/backups/waydroid-network-fixer/`.
- NAT/forwarding repair addresses common host-side routing problems. It cannot fix a broken VPN profile, unreachable VPN endpoint, Xray/core failure, Android VPN-app bug, or server-side egress issue.
- Automatic rollback of firewall changes is not guaranteed. Review your firewall manager (for example, firewalld, UFW, or custom nftables rules) before using this alongside it.

## License

MIT. See [LICENSE](LICENSE).
