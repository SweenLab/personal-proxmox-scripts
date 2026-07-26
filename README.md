# SweenLab Personal Proxmox Scripts

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

# Scripts

| Script | Purpose | Documentation |
|---------|---------|---------------|
| **Proxmox Task Scheduler** | Create and manage scheduled maintenance tasks using interactive menus. | [View Guide](docs/proxmox-task-scheduler.md) |
| **Proxmox Health Check** | Perform a comprehensive read-only health assessment of a Proxmox host, including storage, SMART health, package updates, networking, DNS, system services, and an overall health summary. | [View Guide](docs/proxmox-health-check.md) |
| **Proxmox Host & LXC Maintenance Wizard** | Safely perform guided maintenance on the Proxmox host or Debian/Ubuntu LXC containers with maintenance profiles, progress tracking, automatic logging, and detailed summaries. | [View Guide](docs/proxmox-lxc-maintenance-wizard.md) |
| **Proxmox VM Maintenance Wizard** | Run and schedule guided maintenance for Debian-family VMs through QEMU Guest Agent with logs, stopped-VM policies, and optional notifications. | [View Guide](docs/proxmox-vm-maintenance-wizard.md) |

---

# Features

- Interactive terminal menus
- Beginner-friendly guided workflows
- Safe defaults
- Readable output
- Automatic logging
- Responsive terminal interface
- Supports Debian and Ubuntu LXC containers
- Designed specifically for Proxmox VE

---

# Quick Start

Clone the repository:

```bash
git clone https://github.com/SweenLab/personal-proxmox-scripts.git
```

Or run a script directly from GitHub.

Example:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/main/scripts/proxmox-health-check.sh)
```

Each script includes its own documentation and usage guide.

---

# Documentation

Detailed documentation is available in the **docs** directory.

- 📖 [Proxmox Task Scheduler](docs/proxmox-task-scheduler.md)
- 📖 [Proxmox Health Check](docs/proxmox-health-check.md)
- 📖 [Proxmox Host & LXC Maintenance Wizard](docs/proxmox-lxc-maintenance-wizard.md)
- 📖 [Proxmox VM Maintenance Wizard](docs/proxmox-vm-maintenance-wizard.md)

---

# Releases

Version history and release notes are available on the GitHub **Releases** page.

👉 https://github.com/SweenLab/personal-proxmox-scripts/releases

---

# Roadmap

## Current

- ✅ Proxmox Task Scheduler
- ✅ Proxmox Health Check
- ✅ Proxmox Host & LXC Maintenance Wizard
- ✅ Proxmox VM Maintenance Wizard

## Planned

- 🚧 LXC Setup Wizard
- 🚧 Docker Installer
- 🚧 SMART Report Exporter
- 🚧 Storage Report

---

# Contributing

Suggestions, bug reports, and feature requests are always welcome.

If you find an issue or have an idea that would improve one of these scripts, feel free to open an Issue or submit a Pull Request.

---

# Disclaimer

These scripts are provided **as-is** without warranty.

Although they are designed with safe defaults and are tested in my own homelab, you should always review any script before running it in your own environment.

Make backups of important systems before performing maintenance.

Use at your own risk.

---

# License

This project is licensed under the MIT License.
