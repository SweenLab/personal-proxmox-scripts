# Proxmox Task Scheduler

An interactive menu for creating and managing scheduled tasks on a Proxmox host.

Tasks are stored as systemd services and timers. Standard schedules use the `America/New_York` timezone.

## Run the Scheduler

Run this command as `root` on the Proxmox host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/main/proxmox-task-scheduler.sh)
```

The script may offer to install `whiptail` if it is not already installed.

## Menu Options

- **Add** — Create a scheduled task
- **List** — Display existing tasks and their next run times
- **Run** — Run a task immediately
- **Logs** — View a task’s recent logs
- **Remove** — Delete a task
- **Exit** — Close the scheduler

## Creating a Task

The setup wizard asks for:

1. **Description** — A short name for the task
2. **Target**
   - Enter `local` to run it on the Proxmox host
   - Enter an SSH destination such as `root@10.10.10.201` to run it remotely
3. **Command** — The command to execute
4. **Schedule** — Once, daily, weekly, monthly, or custom
5. **Time** — Entered in 24-hour `HH:MM` format

Remote targets require passwordless SSH to already be configured.

## Example: Weekly Proxmox Reboot

Use the following values:

```text
Description: Proxmox weekly system reboot
Target: local
Command: systemctl reboot
Schedule: Weekly
Day: Sunday
Time: 07:00
```

This reboots the Proxmox host every Sunday at 7:00 AM Eastern Time.

## Important Notes

- Review the confirmation screen before creating a task.
- Do not place passwords or other secrets inside commands.
- Selecting **Run** executes the chosen task immediately.
- Running a reboot task manually will immediately reboot the Proxmox host.
- Timers are persistent. If the host misses a scheduled task while powered off, systemd may run it shortly after the host starts again.
- Review all downloaded scripts before running them as `root`.
