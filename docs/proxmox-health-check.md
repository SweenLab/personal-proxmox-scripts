# Proxmox Health Check

Perform a read-only health assessment of a Proxmox host.

The script reviews several areas of system health and presents a color-coded report with an easy-to-read summary. It does **not** modify the system or install updates.

## Run the Script

Run this command as `root` on the Proxmox host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/main/scripts/proxmox-health-check.sh)
```

## What the Script Checks

### System Information

- Hostname
- Proxmox version
- Current uptime
- Last boot time

---

### Storage Usage

Storage utilization is evaluated using the following thresholds:

| Usage | Status |
|-------:|--------|
| 0–69% | Healthy |
| 70–84% | Attention Needed |
| 85–100% | Critical |

Each mounted filesystem is evaluated individually.

---

### Package Updates

The script refreshes package information and reports:

- Available package updates
- Security-related updates (when detected)

No updates are installed.

---

### SMART Drive Health

For each SMART-capable drive, the script checks:

- Overall SMART health
- Temperature
- Reallocated sectors
- Pending sectors
- Offline uncorrectable sectors
- Last SMART self-test result

If `smartmontools` is not installed, the script explains how to install it.

---

### Failed systemd Services

Reports any services currently in a failed state.

If no failed services are found, the script reports that the system is healthy.

---

### Network and DNS

The script verifies:

- A default gateway is configured
- The default gateway is reachable
- DNS resolution is functioning

These checks help identify common networking issues without requiring internet connectivity beyond DNS resolution.

---

## Health Summary

After completing all checks, the script categorizes findings into four groups:

- **Good to Go** – Healthy items requiring no action.
- **Maintenance Due** – Routine maintenance, such as available package updates.
- **Address ASAP** – Issues that should be investigated soon.
- **Critical** – Problems requiring immediate attention.

The report concludes with an overall health status based on the most severe findings.

## Notes

- The script is completely read-only.
- No packages are installed, upgraded, or removed.
- No services are restarted.
- No configuration files are modified.
- Running the script requires `root` privileges.
- Review downloaded scripts before running them as `root`.
