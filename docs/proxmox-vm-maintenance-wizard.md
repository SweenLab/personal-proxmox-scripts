# Proxmox VM Maintenance Wizard

Safely run guided maintenance on **Debian-family virtual machines** from a Proxmox VE host using QEMU Guest Agent.

The wizard is designed for normal Linux VMs that use `apt`, such as Debian, Ubuntu, Kali Linux, Linux Mint, Pop!_OS, Raspberry Pi OS, and other systems whose `/etc/os-release` says they are Debian-like.

It supports one-time maintenance runs, saved scheduled plans, persistent logs, and optional notifications.

---

# Features

The VM Maintenance Wizard can:

- run one-time VM maintenance
- save a completed one-time run as a scheduled plan
- view saved scheduled plans
- edit saved scheduled plans
- run a saved plan immediately
- enable or disable saved schedules
- delete saved schedules
- send optional completion reports through notification providers
- keep detailed logs under `/var/log/sweenlab/vm-maintenance`

Scheduled plans are managed with native **systemd services and timers**.

No cron jobs are required.

---

# Supported Guests

Supported guest operating systems include:

- Debian
- Ubuntu
- Kali Linux
- Linux Mint
- Pop!_OS
- Raspberry Pi OS
- other Debian-family distributions with `ID_LIKE=debian`

The VM must have QEMU Guest Agent installed and running.

---

# Appliance VM Notice

The wizard intentionally does **not** maintain appliance-style operating systems.

If detected, these VMs are removed from the maintenance list and the wizard shows a notice:

- Home Assistant OS
- OPNsense

Maintain those systems through their own supported update methods.

Use:

- Home Assistant web UI and official Home Assistant update guidance
- OPNsense web UI and official OPNsense update guidance

This avoids breaking appliances that manage their own packages, services, boot process, or firmware-like updates.

---

# Safety

The wizard is conservative by design.

It does **not**:

- update Home Assistant OS
- update OPNsense
- reboot VMs
- remove Docker volumes
- force-stop VMs
- start stopped VMs without asking
- modify VMs that are not detected as Debian-family guests
- run guest commands without QEMU Guest Agent

Before maintenance runs, the wizard shows the selected VMs, selected tasks, and notification setting.

---

# Run the Wizard

Run as **root** on the Proxmox host.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/main/scripts/proxmox-vm-maintenance-wizard.sh)
```

If `whiptail` or `jq` is missing, the wizard offers to install what it needs.

---

# Main Menu

The main menu contains:

| Option | Description |
|----------|-------------|
| Run | Start a one-time maintenance run |
| View | View saved scheduled plans |
| Edit | Edit a saved scheduled plan |
| Run-plan | Run a saved plan immediately |
| Toggle | Enable or disable a saved schedule |
| Delete | Delete a saved schedule |
| Notifications | Add, remove, test, or view notification providers |
| Exit | Close the wizard |

There is no separate "Create Schedule" option on the main menu.

To create a schedule, run maintenance once and then choose **Schedule this same maintenance plan** after the run finishes.

---

# One-Time Maintenance Flow

A normal run works like this:

```text
Start Wizard
        |
        v
Run one-time maintenance
        |
        v
Select VMs
        |
        v
Choose stopped-VM behavior
        |
        v
Select maintenance tasks
        |
        v
Choose notification behavior
        |
        v
Confirm and run
        |
        v
Review summary
        |
        v
Optionally save this run as a schedule
```

---

# Maintenance Tasks

Available tasks include:

| Task | Description |
|----------|-------------|
| Refresh package lists | Runs `apt-get update` |
| Report available upgrades | Reports available package upgrades without installing them |
| Install package upgrades | Runs `apt-get -y upgrade` |
| Remove unused packages | Runs `apt-get -y autoremove` |
| Clean APT cache | Runs `apt-get clean` |
| Clean old journal entries | Removes journal entries older than the configured retention |
| Clean temporary files | Runs system temporary-file cleanup policies |
| Trim guest filesystems | Runs filesystem trim inside the guest |
| Clean unused Docker data | Runs `docker system prune -f` when Docker is installed |

Docker volumes are never removed.

If Docker is not installed in a VM, Docker cleanup is skipped for that VM.

---

# Stopped VMs

If a selected VM is stopped, the wizard asks what to do.

Options:

| Option | Description |
|----------|-------------|
| Skip | Do not maintain the stopped VM |
| Temporary | Start it, maintain it, then request shutdown |
| Leave running | Start it, maintain it, and leave it running |

The wizard does not wait forever for shutdowns. If a temporary VM does not fully shut down in time, the run continues and the log records the issue.

---

# Scheduling

After a one-time run completes, the wizard shows a **Maintenance Complete** menu.

From there, choose:

```text
Schedule this same maintenance plan
```

The wizard saves the same:

- selected VMs
- selected maintenance tasks
- stopped-VM policies
- notification choices
- report format

Then it asks for:

- schedule name
- schedule frequency
- time
- timezone

Schedules are stored under:

```text
/etc/sweenlab/vm-maintenance/plans/
```

Systemd units are created under:

```text
/etc/systemd/system/
```

---

# Notifications

Notifications are optional.

Every plan can use:

- No Notifications
- Configured notification providers

Supported native providers:

- Discord
- Slack
- Telegram
- ntfy
- Gotify
- Pushover
- SMTP email
- Generic webhook

Advanced provider:

- Apprise

Apprise is only offered for installation when the Apprise provider is selected.

Provider credentials are stored in root-only files:

```text
/etc/sweenlab/vm-maintenance/providers/
```

The wizard supports:

- multiple providers
- per-provider severity levels
- provider test notifications
- summary reports
- detailed reports

---

# Logs

Each run creates a timestamped log directory:

```text
/var/log/sweenlab/vm-maintenance/
```

Each task receives its own log file.

At the end of a run, the summary displays the log path.

Example:

```text
Logs: /var/log/sweenlab/vm-maintenance/20260725-211424-one-time
```

---

# Requirements

- Proxmox VE host
- Root privileges on the Proxmox host
- QEMU Guest Agent installed and running inside target VMs
- Debian-family guest operating systems
- Internet access inside guests for package updates
- `whiptail`
- `jq`

The wizard can offer to install missing host-side dependencies.

---

# QEMU Guest Agent

Guest commands are executed through QEMU Guest Agent.

Inside Debian or Ubuntu-family VMs, install it with:

```bash
sudo apt update
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

Then confirm from the Proxmox host:

```bash
qm agent VMID ping
```

Replace `VMID` with the VM number.

---

# Notes

- This wizard is for VMs, not LXC containers.
- Use the Host & LXC Maintenance Wizard for Proxmox host and LXC maintenance.
- Use appliance web interfaces for Home Assistant OS and OPNsense.
- Review maintenance choices before running them on important systems.
- Make backups before using automated maintenance on production-like VMs.

