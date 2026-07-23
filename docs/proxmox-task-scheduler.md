# Proxmox Task Scheduler

An interactive menu for creating and managing scheduled tasks on a Proxmox host.

Tasks are stored as systemd services and timers. When creating a task, the scheduler automatically detects the Proxmox host's timezone and lets you accept it or choose another valid IANA timezone (for example, `America/New_York` or `Europe/London`). The selected timezone is stored with that task and used when the timer runs.

## Run the Scheduler

Run this command as `root` on the Proxmox host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/main/scripts/proxmox-task-scheduler.sh)
```

The script may offer to install `whiptail` if it is not already installed.

## Menu Options

- **Add** — Create a scheduled task
- **List** — Display existing tasks and their next run times
- **Run** — Run a task immediately
- **Logs** — View a task's recent logs
- **Remove** — Delete a task
- **Exit** — Close the scheduler

## Creating a Task

The setup wizard asks for:

1. **Description** — A short name for the task
2. **Target**
   - Enter `local` to run it on the Proxmox host
   - Enter an SSH destination such as `root@10.10.10.201` to run it remotely
3. **Command** — The command to execute
4. **Timezone** — The Proxmox host's timezone is detected automatically. Press **Enter** to accept it or enter another valid IANA timezone such as `America/Chicago`, `America/Los_Angeles`, or `Europe/London`.
5. **Schedule** — Once, daily, weekly, monthly, or custom
6. **Time** — Entered in 24-hour `HH:MM` format

Remote targets require passwordless SSH to already be configured.

## Example: Weekly Proxmox Reboot

Use the following values:

```text
Description: Proxmox weekly system reboot
Target: local
Command: systemctl reboot
Timezone: America/New_York
Schedule: Weekly
Day: Sunday
Time: 07:00
```

This reboots the Proxmox host every Sunday at **7:00 AM in the selected timezone**. If you accept the detected timezone, it will use the Proxmox host's configured timezone.

## Important Notes

- Review the confirmation screen before creating a task.
- Do not place passwords or other secrets inside commands.
- Selecting **Run** executes the chosen task immediately.
- Running a reboot task manually will immediately reboot the Proxmox host.
- Timers are persistent. If the host misses a scheduled task while powered off, systemd may run it shortly after the host starts again.
- Review all downloaded scripts before running them as `root`.
