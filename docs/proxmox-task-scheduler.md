# Proxmox Task Scheduler

An interactive menu for creating and managing scheduled tasks on a Proxmox host.

Tasks are stored as systemd services and timers. When creating a task, the scheduler automatically detects the Proxmox host's timezone and lets you accept it or choose another valid IANA timezone, such as `America/New_York` or `Europe/London`.

The selected timezone is stored with the task and used whenever its timer runs.

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

The setup wizard asks for the following information:

1. **Description** — A short name for the task
2. **Target**
   - Enter `local` to run the task on the Proxmox host
   - Enter an SSH destination such as `root@10.10.10.201` to run the task on an LXC or VM
3. **Command** — The command to execute
4. **Timezone**
   - The Proxmox host's timezone is detected automatically
   - Press **Enter** to accept the detected timezone
   - Enter another valid IANA timezone to override it
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

This reboots the Proxmox host every Sunday at **7:00 AM in the selected timezone**.

If you accept the automatically detected timezone, the task will use the Proxmox host's configured timezone.

## Sample Commands

The following examples demonstrate common commands that can be scheduled using the Proxmox Task Scheduler.

Before scheduling a command, check the listed **Supported Target(s)**.

When entering the **Target** prompt:

- Use `local` for the Proxmox host.
- Use `root@[ip-address-or-hostname]` for an LXC or VM.

Replace any information inside brackets, such as `[drive]`, `[directory]`, or `[script-name]`, with values appropriate for your environment.

---

## 📦 Package Management

---

### Check for package updates

**Supported Target(s)**

- Proxmox host
- LXC or VM

**Command to Schedule**

```bash
apt update
```

---

### Install available package updates

**Supported Target(s)**

- Proxmox host
- LXC or VM

**Command to Schedule**

```bash
bash -c 'apt update && apt upgrade -y'
```

---

### Remove unused packages

**Supported Target(s)**

- Proxmox host
- LXC or VM

**Command to Schedule**

```bash
apt autoremove -y
```

---

### Clean the package cache

**Supported Target(s)**

- Proxmox host
- LXC or VM

**Command to Schedule**

```bash
apt clean
```

---

## 💾 SMART Drive Testing

---

### Run a short SMART test

**Supported Target(s)**

- Proxmox host

**Command to Schedule**

```bash
smartctl -t short /dev/[drive]
```

**Example**

```bash
smartctl -t short /dev/sda
```

---

### Run a long SMART test

**Supported Target(s)**

- Proxmox host

**Command to Schedule**

```bash
smartctl -t long /dev/[drive]
```

**Example**

```bash
smartctl -t long /dev/sda
```

---

## ⚡ Power Management

---

### Reboot the Proxmox host

**Supported Target(s)**

- Proxmox host

**Command to Schedule**

```bash
systemctl reboot
```

---

### Shut down the Proxmox host

**Supported Target(s)**

- Proxmox host

**Command to Schedule**

```bash
systemctl poweroff
```

---

## 🐳 Docker Compose

---

### Restart a Docker Compose stack

**Supported Target(s)**

- LXC or VM

**Command to Schedule**

```bash
bash -c 'cd /opt/[directory] && docker compose restart'
```

**Example**

```bash
bash -c 'cd /opt/immich && docker compose restart'
```

---

### Update a Docker Compose stack

**Supported Target(s)**

- LXC or VM

**Command to Schedule**

```bash
bash -c 'cd /opt/[directory] && docker compose pull && docker compose up -d'
```

**Example**

```bash
bash -c 'cd /opt/immich && docker compose pull && docker compose up -d'
```

---

## 📜 Custom Scripts

---

### Run a locally created script

**Supported Target(s)**

- Proxmox host
- LXC or VM

**Command to Schedule**

```bash
/opt/scripts/[script-name].sh
```

**Example**

```bash
/opt/scripts/health-check.sh
```

## Important Notes

- Review the confirmation screen before creating a task.
- Verify that the selected target is correct before saving the task.
- Test commands manually before scheduling them.
- Do not place passwords, API keys, tokens, or other secrets inside commands.
- Selecting **Run** executes the chosen task immediately.
- Running a reboot task manually will immediately reboot the Proxmox host.
- Running a shutdown task manually will immediately power off the Proxmox host.
- SMART tests must be scheduled on the Proxmox host that has direct access to the selected drive.
- Docker Compose commands must use the correct directory containing the stack's Compose file.
- Remote tasks require passwordless SSH from the Proxmox host to the selected LXC or VM.
- Timers are persistent. If the host misses a scheduled task while powered off, systemd may run it shortly after the host starts again.
- Review all downloaded scripts before running them as `root`.
