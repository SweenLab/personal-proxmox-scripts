# Proxmox Task Scheduler

Create and manage scheduled tasks on your Proxmox VE host using an interactive terminal interface.

The Task Scheduler stores jobs as native **systemd services and timers**, allowing scheduled commands to run reliably on the Proxmox host or remotely on LXC containers and virtual machines over SSH.

No manual timer files or cron jobs are required.

---

# Features

The Task Scheduler allows you to:

- Create scheduled tasks
- List existing scheduled tasks
- Run tasks immediately
- View task logs
- Remove scheduled tasks
- Automatically detect the Proxmox host's timezone
- Schedule commands on the Proxmox host
- Schedule commands on remote LXC containers or VMs

All tasks are managed using native systemd services and timers.

---

# Safety

The Task Scheduler creates scheduled tasks only.

It **does not**:

- install software
- configure SSH
- validate scheduled commands
- automatically update packages
- modify existing system timers outside of those it creates

Always review scheduled commands before saving them.

---

# Requirements

- Proxmox VE host
- Root privileges
- systemd
- Internet connection (only when downloading the script or installing dependencies)

Optional:

- Passwordless SSH for scheduling commands on remote LXC containers or VMs.

---

# Run the Scheduler

Run as **root** on the Proxmox host.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/main/scripts/proxmox-task-scheduler.sh)
```

If `whiptail` is not installed, the scheduler offers to install it automatically.

---

# Main Menu

The scheduler provides the following options.

| Option | Description |
|----------|-------------|
| Add | Create a scheduled task |
| List | Display existing tasks and their next run times |
| Run | Execute a task immediately |
| Logs | View recent task logs |
| Remove | Delete a scheduled task |
| Exit | Close the scheduler |

---

# Creating a Task

The setup wizard collects the following information.

## Description

A friendly name used to identify the scheduled task.

---

## Target

Choose where the command should run.

Examples:

**Local Proxmox host**

```text
local
```

**Remote LXC or VM**

```text
root@10.10.10.201
```

Remote targets require passwordless SSH.

---

## Command

Enter the command that should be executed.

Examples include package maintenance, SMART testing, Docker maintenance, or your own custom scripts.

---

## Timezone

The scheduler automatically detects the Proxmox host's configured timezone.

You may:

- Accept the detected timezone
- Enter another valid IANA timezone such as:

```text
America/New_York
Europe/London
Australia/Sydney
```

The selected timezone is stored with the task and used whenever it runs.

---

## Schedule

Choose one of the supported schedules.

- Once
- Daily
- Weekly
- Monthly
- Custom

---

## Time

Specify the execution time using 24-hour format.

Example:

```text
07:30
```

---

# Example

Create a weekly reboot task.

| Setting | Value |
|----------|-------|
| Description | Weekly Proxmox Reboot |
| Target | local |
| Command | `systemctl reboot` |
| Timezone | America/New_York |
| Schedule | Weekly |
| Day | Sunday |
| Time | 07:00 |

---

# Sample Commands

The following examples demonstrate common maintenance tasks.

Before scheduling any command, verify the listed supported targets.

When entering the **Target** field:

- Use `local` for the Proxmox host.
- Use `root@[hostname-or-ip]` for LXC containers or VMs.

Replace placeholder values such as `[drive]`, `[directory]`, or `[script-name]` with values appropriate for your environment.

---

# Package Management

## Check for package updates

**Supported Targets**

- Proxmox host
- LXC
- VM

```bash
apt update
```

---

## Install package updates

**Supported Targets**

- Proxmox host
- LXC
- VM

```bash
bash -c 'apt update && apt upgrade -y'
```

---

## Remove unused packages

**Supported Targets**

- Proxmox host
- LXC
- VM

```bash
apt autoremove -y
```

---

## Clean package cache

**Supported Targets**

- Proxmox host
- LXC
- VM

```bash
apt clean
```

---

# SMART Drive Testing

## Short SMART test

**Supported Targets**

- Proxmox host

```bash
smartctl -t short /dev/[drive]
```

Example:

```bash
smartctl -t short /dev/sda
```

---

## Long SMART test

**Supported Targets**

- Proxmox host

```bash
smartctl -t long /dev/[drive]
```

Example:

```bash
smartctl -t long /dev/sda
```

---

# Power Management

## Reboot the Proxmox host

**Supported Targets**

- Proxmox host

```bash
systemctl reboot
```

---

## Shut down the Proxmox host

**Supported Targets**

- Proxmox host

```bash
systemctl poweroff
```

---

# Docker Compose

## Restart a Compose stack

**Supported Targets**

- LXC
- VM

```bash
bash -c 'cd /opt/[directory] && docker compose restart'
```

---

## Update a Compose stack

**Supported Targets**

- LXC
- VM

```bash
bash -c 'cd /opt/[directory] && docker compose pull && docker compose up -d'
```

---

# Custom Scripts

Run your own scripts.

**Supported Targets**

- Proxmox host
- LXC
- VM

```bash
/opt/scripts/[script-name].sh
```

Example:

```bash
/opt/scripts/health-check.sh
```

---

# Logs

Scheduled tasks run through systemd.

The scheduler's **Logs** menu displays recent output.

You can also view logs manually.

```bash
journalctl -u <service-name>
```

---

# Example Workflow

```text
Start Scheduler
        │
        ▼
Create New Task
        │
        ▼
Choose Target
        │
        ▼
Enter Command
        │
        ▼
Select Schedule
        │
        ▼
Review Configuration
        │
        ▼
Save Task
        │
        ▼
systemd Timer Created
```

---

# Tips

- Test commands manually before scheduling them.
- Use descriptive task names.
- Verify remote SSH connectivity before scheduling remote tasks.
- Review task logs periodically.
- Remember that reboot and shutdown commands execute immediately when using the **Run** option.

---

# Troubleshooting

## Remote task fails

Verify:

- passwordless SSH is configured
- the destination is reachable
- the remote user has permission to execute the command

---

## Timer does not run

Confirm:

- the service and timer were created successfully
- the timer is enabled
- the system time and timezone are correct

---

## Command fails

The scheduler executes the command exactly as entered.

Verify the command manually before scheduling it.

---

# Disclaimer

Review downloaded scripts before running them as **root**.

The Task Scheduler executes the commands you provide exactly as entered. Always verify commands before scheduling them, especially those that modify the system or reboot the host.
