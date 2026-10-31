# SWEENLAB SCRIPTS

<p align="center">
  <img src="assets/branding/sweenlab-scripts-banner.png" alt="SWEENLAB SCRIPTS — orange and green circuit crest" width="800">
</p>

Hi, I'm Sween. 👋

I'm building and learning through my personal homelab, **Sween Lab**.

This repository contains scripts I've created to make managing **Proxmox VE** and Linux systems a little easier. I learn best by doing, experimenting, and occasionally breaking things before figuring out how to fix them. If you're the kind of person who learns through hands-on experience instead of memorizing commands, I hope these tools are useful to you too.

Every script is something I built because I wanted it for my own lab first. If it helps someone else learn or saves them some time, that's even better.

Have fun!

<p align="center">
  <a href="https://buymeacoffee.com/sweenlab">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" width="220">
  </a>
</p>

---

# Hawser Agent Setup Wizard

Connect Docker LXCs to Dockhand with a guided native-service installer—no Compose file needed. Paste a Dockhand-generated token, or press **F2** to generate one in the wizard. Includes orange/green menus, Back/Abort, automatic verbose installation, checksum verification, backups and a final checklist.

Run **inside each Docker LXC as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/8d70357b43e1d91eb5a86798f9bc9ed784e424f4/scripts/hawser-agent-setup.sh)"
```

Version **0.1.2**. Uses Standard HTTP/token authentication on port 2376 for a trusted LAN/Tailscale path. Installs and enables Hawser at boot; existing Compose stacks require separate import. [Setup guide](docs/hawser-agent-setup.md) · [Script](scripts/hawser-agent-setup.sh). Local checks pass; live LXC installation remains unverified.

---

# Debian LXC Creation Wizard

Create a Debian 12 or 13 LXC through a fully guided, step-by-step wizard. Every configuration stage is shown; no packages are preselected.

| Script | Purpose | Documentation |
|---------|---------|---------------|
| [Debian LXC Creation Wizard](scripts/proxmox-debian-lxc-create.sh) | Choose container ID, hostname, tags, networking, resources, packages, features and optional device passthrough. | [View Guide](docs/proxmox-debian-lxc-create.md) |

The installer is embedded in this single script and runs inside the new container.

## Branding and container notes

Download the [banner](assets/branding/sweenlab-scripts-banner.png) or [crest](assets/branding/sweenlab-crest.png), and see the [automatic/copyable Proxmox notes template](docs/container-notes.md).

## Features

- New containers automatically receive generic SWEENLAB SCRIPTS Summary notes: compact banner and links centered in a 280-pixel-high layout. The wizard saves them again after guest setup and verifies the saved description through Proxmox before reporting completion.

- Consistent orange/green screens, persistent centered grey input boxes, complete Tab/arrow navigation, and an aligned Create/Abort review. Password confirmation always starts blank.
- Explicit unprivileged or privileged container selection.
- Name-only Proxmox bridge/storage choices and IPv4/IPv6 configuration; other network settings use background defaults. Runtime Docker/firewall bridges are hidden.
- Selectable git, curl, wget, Tailscale, Docker Engine/Compose, nano, jq, unzip, ping, OpenSSH and sudo.
- Orange/green terminal accents, horizontal Yes/No controls, FUSE and GPU defaulting to No, and automatic device UID/GID settings.
- Mandatory root password, host-derived timezone and locale, 10 GiB initial root disk, memory conversion chart, required swap allowance in MiB (0 disables swap; no default), and already-downloaded Debian templates.
- Optional automatic Tailscale sign-in with SSH/DNS/route settings and a browser login link.
- Explicit single-choice bridge, IPv4/IPv6 mode, storage and template selectors; required selections block Next until chosen, then focus moves straight to Next.
- Correct Proxmox directory creation permissions, private logs, read-only extraction diagnostics.
- Simplified networking with background defaults and arrow-key navigation between fields, lists and buttons.
- Required package choice with Select all/clear all and exclusive None, optional Python 3/pip/venv, editable host-derived locale, full Debian upgrade after locale setup, and quiet or verbose emoji/color installation progress.
- Official package repositories, signed packages, rerunnable tool installation and logs.
- No additional installer shell scripts are downloaded or executed.

## Quick Start

Use the copy button on the command block below, then paste it into your **Proxmox node shell as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/d9b315243acb699bdfe3c58b623be6f0a9d0bdb2/scripts/proxmox-debian-lxc-create.sh)"
```

This command is pinned to version 0.1.21 so it does not depend on a cached main-branch download. This downloads and runs the SweenLab wizard. Back preserves your entries; the final Create action begins provisioning. The guest installer is embedded; no companion file or additional shell script download is required.

For a first test, choose a new disposable container ID. Follow the [step-by-step guide](docs/proxmox-debian-lxc-create.md) for prerequisites, passthrough permissions, retries and testing. You can inspect the script on GitHub before running it.

## Testing Status

Version 0.1.21 is an initial test build. Bash syntax and simulated workflow checks pass; live Proxmox, Docker, Tailscale and GPU validation is still required. Start with a disposable container.

## Documentation

- [Debian LXC Creation Wizard guide](docs/proxmox-debian-lxc-create.md)

## Releases

Every tweak and update is recorded in the [changelog](CHANGELOG.md) and on the [Releases page](https://github.com/SweenLab/sweenlab-scripts/releases). Historical releases can contain tools no longer present on the main branch.

## Contributing

Suggestions and bug reports are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

These scripts are provided as-is without warranty. Review the code and configuration before running it, and make backups of important systems. Use at your own risk.

## License

This project is licensed under the [MIT License](LICENSE).
