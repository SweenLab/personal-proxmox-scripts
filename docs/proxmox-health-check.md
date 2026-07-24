# Proxmox Health Check

Perform a comprehensive, **read-only** health assessment of a Proxmox VE host.

The Health Check script reviews several areas of system health and presents an easy-to-read, color-coded report. It is designed to help identify potential problems before they become outages while leaving your system completely unchanged.

No packages are installed, no services are restarted, and no configuration files are modified.

---

# Features

The Health Check script automatically evaluates:

- System information
- Storage utilization
- Available package updates
- SMART drive health
- Failed systemd services
- Network connectivity
- DNS resolution

At the end of the scan, the script generates an overall health summary with prioritized findings.

---

# Safety

The Health Check script is completely read-only.

It **does not**:

- install packages
- remove packages
- upgrade packages
- reboot the host
- restart services
- modify configuration files
- change storage settings

The script only collects and reports system information.

---

# Requirements

- Proxmox VE host
- Root privileges

Optional:

- `smartmontools` (required for SMART drive health reporting)

If SMART tools are not installed, the script explains how to install them.

---

# Run the Script

Run as **root** on the Proxmox host.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/main/scripts/proxmox-health-check.sh)
```

---

# Health Checks

## System Information

The script reports:

- Hostname
- Proxmox version
- Current uptime
- Last boot time

This provides a quick overview of the system being evaluated.

---

## Storage Usage

Every mounted filesystem is evaluated individually.

Storage utilization uses the following thresholds:

| Usage | Status |
|-------:|--------|
| 0–69% | Healthy |
| 70–84% | Attention Needed |
| 85–100% | Critical |

This helps identify filesystems that may require cleanup or expansion.

---

## Package Updates

The script refreshes package information and reports:

- Available package updates
- Security-related updates (when detected)

No packages are installed.

---

## SMART Drive Health

For every SMART-capable drive, the script checks:

- Overall SMART health
- Temperature
- Reallocated sectors
- Pending sectors
- Offline uncorrectable sectors
- Most recent SMART self-test result

These checks can help identify failing drives before data loss occurs.

---

## Failed systemd Services

The script searches for services currently in a failed state.

If no failed services are found, the system is reported as healthy.

---

## Network and DNS

The script verifies:

- A default gateway exists
- The gateway is reachable
- DNS resolution is functioning correctly

These checks help identify common networking problems.

---

# Health Summary

After completing all checks, the script categorizes findings into four groups.

| Category | Meaning |
|----------|---------|
| Good to Go | Healthy items requiring no action |
| Maintenance Due | Routine maintenance is recommended |
| Address ASAP | Problems that should be investigated soon |
| Critical | Immediate attention is recommended |

The report concludes with an overall system health assessment based on the most severe findings.

---

# Example Workflow

```text
Start Script
      │
      ▼
Collect System Information
      │
      ▼
Evaluate Storage Usage
      │
      ▼
Check Package Updates
      │
      ▼
Evaluate SMART Health
      │
      ▼
Check Failed Services
      │
      ▼
Verify Network & DNS
      │
      ▼
Generate Health Summary
```

---

# Tips

- Run the Health Check regularly to identify issues before they become critical.
- Review SMART warnings promptly, especially reallocated or pending sectors.
- Address failed services even if the system appears to be operating normally.
- Keep package updates current to receive bug fixes and security patches.
- Investigate storage usage before filesystems become critically full.

---

# Troubleshooting

## SMART information is unavailable

`smartmontools` is not installed or the storage device does not support SMART reporting.

---

## No security updates are listed

Security updates are only reported when they can be identified by the package manager.

---

## Network check fails

Verify:

- network connectivity
- default gateway configuration
- DNS server configuration

---

# Disclaimer

Review downloaded scripts before running them as **root**.

Although the Health Check script is completely read-only, always maintain current backups and verify reported findings before making changes to a production system.
