# Proxmox Host & LXC Maintenance Wizard

Safely perform guided maintenance on your **Proxmox VE host** or **Debian/Ubuntu LXC containers** using an interactive terminal wizard.

Instead of remembering maintenance commands or creating checklists by hand, the wizard walks you through the entire process, displays exactly what will happen before making changes, tracks progress during execution, and summarizes the results when maintenance is complete.

---

# Features

## Guided Maintenance

The wizard uses interactive menus to guide you through the maintenance process.

No command-line arguments are required.

The wizard helps you:

- Select the Proxmox host or LXC containers
- Choose a maintenance profile
- Customize the selected maintenance tasks
- Review the execution plan
- Monitor maintenance progress
- Review a detailed summary after completion

---

## Maintenance Profiles

Several built-in maintenance profiles are included.

| Profile | Purpose |
|----------|---------|
| Weekly Maintenance | Routine package updates and cleanup |
| Monthly Maintenance | Weekly tasks plus log cleanup, temporary file cleanup, and filesystem trim |
| Docker Maintenance | Package maintenance plus Docker cleanup |
| Full Maintenance | Every supported maintenance task |
| Custom Maintenance | Start with a minimal profile and choose tasks manually |

Profiles are only a starting point.

After selecting a profile, you can enable or disable any maintenance task before the wizard begins.

---

# Supported Systems

## Proxmox Host

Supported operating systems:

- Proxmox VE
- Debian-based Proxmox installations

---

## LXC Containers

Supported operating systems:

- Debian
- Ubuntu

Unsupported operating systems are detected automatically and skipped safely.

---

# Safety

The wizard is intentionally conservative.

It **does not**:

- reboot the Proxmox host
- reboot containers
- force-stop containers
- remove Docker volumes
- modify unsupported operating systems
- start stopped containers without permission

Before any maintenance begins, the wizard displays the complete execution plan and asks for confirmation.

---

# Run the Wizard

Run as **root** on the Proxmox host.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/main/scripts/proxmox-lxc-maintenance-wizard.sh)
```

If `whiptail` is not installed, the wizard offers to install it automatically.

---

# Wizard Walkthrough

The maintenance process consists of several guided steps.

## Step 1

Choose where maintenance should run.

Options:

- Proxmox Host
- LXC Containers

---

## Step 2 (LXC Mode)

Select one or more LXC containers.

Features include:

- Interactive checkbox selection
- Select all containers
- Select all running containers
- Running containers selected by default

---

## Step 3

Choose a maintenance profile.

The selected profile automatically enables recommended maintenance tasks.

You may still customize the task list before continuing.

---

## Step 4

Review and modify the selected maintenance tasks.

Available tasks include:

- Update package lists
- Install package upgrades
- Remove unused packages
- Clean the APT cache
- Journal cleanup
- Log rotation
- Temporary file cleanup
- Filesystem trim
- Docker cleanup (when Docker is installed)

---

## Step 5

Review the maintenance plan.

The confirmation screen displays:

- selected host or containers
- selected maintenance profile
- selected maintenance tasks
- estimated runtime
- safety reminders

Nothing runs until you approve the plan.

---

## Step 6

Maintenance begins.

The wizard displays:

- current target
- current maintenance task
- overall progress
- percentage complete
- progress bar

Package management output is intentionally hidden during successful operations to keep the display clean.

---

## Step 7

When maintenance finishes, a detailed summary is displayed.

The summary includes:

- runtime
- successful tasks
- failed tasks
- skipped tasks
- per-target scorecards
- net disk-space recovered
- location of task logs

---

# Stopped Containers

If a selected container is currently stopped, the wizard asks how it should be handled.

Options include:

- Skip the container
- Start, maintain, then stop it again
- Start, maintain, and leave it running

The wizard never starts a stopped container without your approval.

---

# Docker Support

If Docker is detected inside a container, the wizard can perform:

```text
docker system prune -f
```

Docker volumes are **never removed**.

If Docker is not installed, Docker cleanup is skipped automatically.

---

# Logging

Each maintenance run creates a timestamped log directory.

```text
/var/log/proxmox-lxc-maintenance/
```

Each task receives its own log file.

If a task fails, the wizard offers to display the log immediately before continuing.

---

# Requirements

- Proxmox VE host
- Root privileges
- Debian or Ubuntu LXC containers
- Internet connection (for package updates)
- `whiptail` (installed automatically if needed)

---

# Example Workflow

```text
Start Wizard
        │
        ▼
Select Host or LXC Containers
        │
        ▼
Choose Maintenance Profile
        │
        ▼
Customize Tasks
        │
        ▼
Review Execution Plan
        │
        ▼
Run Maintenance
        │
        ▼
View Progress
        │
        ▼
Review Final Summary
```

---

# Tips

- Run package maintenance regularly.
- Review the execution plan before starting.
- Test new maintenance profiles on non-production systems first.
- Docker cleanup only removes unused images, containers, and networks.
- Review task logs if a failure occurs.

---

# Troubleshooting

## Docker cleanup is skipped

Docker was not detected inside the selected container.

---

## Filesystem trim is skipped

The selected storage does not support trimming or the required tools are unavailable.

---

## Journal cleanup is skipped

`journalctl` is not installed or is unavailable inside the selected environment.

---

## A container is skipped

The wizard skips containers that:

- use unsupported operating systems
- were intentionally skipped during stopped-container handling
- cannot be started successfully

---

# Disclaimer

Review downloaded scripts before running them as **root**.

Although the wizard uses conservative defaults and displays an execution plan before making changes, you are responsible for understanding the maintenance tasks you choose to run.

Always maintain current backups before performing maintenance on production systems.
