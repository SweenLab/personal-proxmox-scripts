# sweenlab | Proxmox cleanup

Version **0.1.1** · inventory first · explicit file allowlist · Debian-family guests

This is a new conservative cleanup tool, not a revival of the retired maintenance wizard. It finds a narrow set of verified disposable files. It does not decide that unknown data is junk.

## Short Bash launcher

Run in the Proxmox root shell. Inventory only:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/73de98c22c8ccba5bb5e84313b7946b2063c3b20/cleanup.sh)
```

Interactive cleanup with exact file selection and typed confirmation:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/73de98c22c8ccba5bb5e84313b7946b2063c3b20/cleanup.sh) --apply
```

The launcher downloads the pinned Python script, verifies SHA-256 and runs it from a private temporary directory. It removes only its own temporary download on exit. Reports remain under `/var/log/sweenlab/cleanup/`. It does not install a persistent script. All Python options can follow the command, including `--targets host,ct:200`. Both commands require Bash, curl, Python 3 and sha256sum. Default remains inventory only. The longer optional installation below is for a persistent local copy.

## 1. Prepare

Use the Proxmox node's root shell. Python 3 and standard Debian utilities are required on the node. Each guest inspected also needs Python 3, `findmnt` (util-linux), and the relevant verifier (`dpkg-deb` or `journalctl`). Nothing is installed automatically. Run once per node; discovery covers local guests only. Run during a quiet maintenance window without concurrent upgrades, migrations, mount changes or cleanup jobs.

Review your latest successful backup and restoration procedure before deleting anything. A snapshot can help roll back supported guest disks, but is not a backup, may retain deleted blocks, and does not necessarily cover bind mounts or external data. The script creates, deletes and prunes neither snapshots nor backups. No automatic rollback exists. Export needed logs before deleting them; the audit report records filenames and fingerprints, not file contents.

## 2. Paste once to install and inventory

The following block downloads the immutable script, verifies its SHA-256, installs a private copy at the lowercase path `/opt/sweenlab/sweenlab-cleanup.py`, then inventories. It refuses to overwrite an existing installation. Review the linked script first. This explicitly writes the installed script and audit reports, but performs no cleanup.

```bash
(
  set -euo pipefail
  [ "$(id -u)" -eq 0 ] || { echo "Run in the Proxmox root shell."; exit 1; }
  umask 077
  sweenlab_script=/opt/sweenlab/sweenlab-cleanup.py
  if [ -e "$sweenlab_script" ] || [ -L "$sweenlab_script" ]; then
    echo "Already installed. Run: python3 $sweenlab_script"
    exit 1
  fi
  sweenlab_tmp=$(mktemp -d)
  trap 'rm -f -- "$sweenlab_tmp/cleanup.py"; rmdir -- "$sweenlab_tmp"' EXIT
  curl --proto '=https' --tlsv1.2 -fsSL \
    https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/5e0ad4bfdcef7aa0497e7d166104f8a6164e6dab/scripts/sweenlab-cleanup/sweenlab-cleanup.py \
    -o "$sweenlab_tmp/cleanup.py"
  printf '%s  %s\n' '5d3e5e3ef6e43f8a56c9ee948afba7883abc8fd3b27d4480d539050c0b96c8dd' "$sweenlab_tmp/cleanup.py" | sha256sum -c -
  install -d -m 700 /opt/sweenlab
  install -m 700 "$sweenlab_tmp/cleanup.py" "$sweenlab_script"
  python3 "$sweenlab_script"
)
```

If already installed, use:

```bash
python3 /opt/sweenlab/sweenlab-cleanup.py
```

Default behavior inventories the host and attempts every local guest. Stopped/locked/unsupported guests are skipped with a reported error; they are never booted, mounted or modified. The process returns nonzero when any target fails, even when other targets succeed.

## 3. Read the inventory

For each accessible target, the terminal shows root filesystem usage, excluded paths and numbered cleanup candidates. Private JSONL reports under `/var/log/sweenlab/cleanup/` include timestamps, script hash, guest lists, storage backend status, guest configurations/snapshot lists, mounts, candidates, authorizations, successful deletion records, errors and completion status.

Treat reports as sensitive: guest names, storage paths and configuration details may appear. They are created with private permissions and never uploaded or automatically pruned. Keep them in an administrator-controlled directory. Inventory can consume disk I/O because it verifies and hashes eligible archives.

| Action | Exact eligibility |
| --- | --- |
| `apt` | Direct `.deb` files in `/var/cache/apt/archives`, at least 7 days old by modification time, successfully parsed by `dpkg-deb --info`. Packages remain installed. Downloads may be needed again later. |
| `journal` | Only archived `system@….journal` files matching systemd's hexadecimal archive naming pattern under `/var/log/journal/<current-machine-id>`, at least 30 days old by modification time, successfully checked by `journalctl --file=… --verify`. Active `system.journal`, user journals and other machine IDs are excluded. |

Both require regular files owned by root, one hard link, no group/world write bits, safe directory components, no symlinks, no overlapping non-root mount and no exclusion overlap. Bind mounts are detected from mountinfo, including same-device bind mounts. Separate `/var` or `/var/log` filesystems cause the related action to be skipped deliberately. This release offers no override for mounted data.

Journal age means the **archive file's modification time**, not an exact per-entry retention promise. This deletes selected whole archives; it does not rotate active logs or vacuum all journals. No estimated physical storage savings are claimed. Logical candidate bytes, `df` and backend allocation measure different things; snapshots/thin provisioning/discard can keep storage allocated.

## 4. Choose targets and exclusions

```bash
# Only the host and one LXC; inventory only.
python3 /opt/sweenlab/sweenlab-cleanup.py --targets host,ct:200

# Skip a target and protect paths in every target's own filesystem.
python3 /opt/sweenlab/sweenlab-cleanup.py \
  --exclude-target ct:239 \
  --exclude-path /var/log/journal \
  --exclude-path /var/cache/apt/archives/keep.deb

# Keep journal archives for at least 90 days.
python3 /opt/sweenlab/sweenlab-cleanup.py --journal-days 90
```

Paths are absolute, literal paths; no globs. A path exclusion overlapping any part of an action directory skips that entire directory. Exclusions apply inside each target, not to equivalent host mount paths. To protect a whole guest use `--exclude-target`. Targets are `host`, `ct:<id>` or `vm:<id>`; comma-separated selection is exact. `--reports` changes the administrator-controlled local audit directory. A local lock prevents two controllers using that report directory; use the same directory for all runs.

## 5. Explicitly clean selected files

```bash
python3 /opt/sweenlab/sweenlab-cleanup.py --apply --targets host,ct:200
```

1. Review the fresh inventory for each target.
2. Enter only the file numbers you authorize, such as `1,3,4`. Press Enter to skip the target.
3. Review the resulting exact `DELETE` list and confirm your backup/recovery review.
4. Type the exact target phrase, for example `delete ct:200`.
5. The script logs this file allowlist before running cleanup and rescans/rechecks eligibility, identity, size, modification time and SHA-256 before unlinking selected files.

There is no unattended `--yes`, wildcard allowlist, or saved plan replay. Cleanup requires a terminal. Changed files fail closed. Failure can occur after some files were removed; inspect the audit report and current state before a fresh review. A timeout/interruption may leave a guest process running: do not immediately retry. File checks reduce races but do not defend against an actively hostile root user, mount changes or concurrent root processes. Guests and their administrators must be trusted.

## 6. LXC and VM access

LXCs use `pct exec <id> -- python3 …` while running. The script does not use `pct mount` and never traverses container disks from the host. Guest Python must run as root.

VMs use `qm guest exec <id> --synchronous 1 --timeout 120 -- python3 …` and validate the guest agent's JSON exit status, completion and truncation indicators. The VM must be running, with QEMU Guest Agent enabled in Proxmox and installed/running in the guest. Guest exec must be permitted. The script does not enable or install it. Windows, BSD, Alpine and other non-Debian systems are unsupported. Missing Python or unavailable/disabled agents produce a skip/error, not an SSH fallback.

If guest-agent execution is unavailable, copy the reviewed script into a Debian guest yourself and run it there:

```bash
python3 /opt/sweenlab/sweenlab-cleanup.py --in-guest
python3 /opt/sweenlab/sweenlab-cleanup.py --in-guest --apply
```

In this mode `host` means the current guest, and its reports stay there. No Proxmox commands are used. Running a VM command via the guest agent is privileged guest execution even during inventory; it is read-only except for ordinary OS access/audit effects and the controller's report files.

## What remains protected

There are no code paths for deleting VM/LXC disks, unused/unreferenced volumes, backups, snapshots, mounts, user files or guest trash. An `unusedN` disk is not proof that a volume is disposable. Storage status and guest config/snapshot metadata are for human review, not an orphan detector. Cluster-wide reference checking, replication, backup contents and storage ownership require a separate review. Even an explicit request to delete those resources requires another tool/change and a reviewed allowlist; this script deliberately cannot perform it.

No package autoremove/purge, kernel removal, Docker/Podman prune, database cleanup, image cleanup, temp-directory sweeping, application cache cleanup, log truncation, filesystem repair, trim, zero-fill, reboot or guest configuration changes are performed. Unknown files remain untouched. If this finds little to remove, inspect application retention rules with the application owner instead of broadening deletion heuristics.

## Troubleshooting and testing

- **APT lock failure:** let the package job finish; never remove lock files. Existing dpkg/frontend/archive POSIX locks are acquired without waiting for both inventory and cleanup.
- **Mounted/excluded path:** expected protection. Do not unmount storage just to make cleanup eligible.
- **Verifier missing/corrupt archive:** the file is skipped with a reason.
- **Too many candidates or truncated VM output:** inspect in-guest or narrow scope; no blind retry with deletion.
- **Guest timeout:** confirm whether execution is still running before repeating. JSON may include a PID on a timeout; inspect with `qm guest exec-status <id> <pid>` where applicable.
- **No `finish` event:** treat the report as incomplete. Look for authorization and per-file deletion events; controller errors retain command output where available. A transport/process timeout may prevent complete deletion reporting.

Local verification: Python syntax, command help/version and mocked safety tests. No live Proxmox, LXC, guest-agent or real cleanup validation has been performed. Start with inventory and test any apply operation on a disposable Debian guest before production use.

```bash
python3 -m unittest discover -s scripts/sweenlab-cleanup/tests -v
python3 scripts/sweenlab-cleanup/sweenlab-cleanup.py --help
```

## Command references checked for this release

- [Proxmox's current generated qm CLI reference](https://github.com/proxmox/pve-docs/blob/master/generated/qm.1-synopsis.adoc): guest exec, synchronous/timeout, exec-status.
- [Proxmox's current generated pct CLI reference](https://github.com/proxmox/pve-docs/blob/master/generated/pct.1-synopsis.adoc): exec, status, config, listsnapshot.
- [Debian trixie apt-get manual](https://manpages.debian.org/trixie/apt/apt-get.8.en.html): clean removes downloaded package caches; autoremove removes packages and is intentionally excluded. This script uses a narrower verified file allowlist instead of broad `apt-get clean`.
- [Debian trixie journalctl manual](https://manpages.debian.org/trixie/systemd/journalctl.1.en.html): verify checks journal consistency; vacuum acts on archived files. This script verifies exact system archives and deletes only the reviewed files rather than calling broad vacuum.

The Proxmox documentation website returned HTTP 403 during research, so the official Proxmox source repository was used. Verify installed `qm help guest exec` and `pct help exec` if a node's version differs. Documentation research does not substitute for live compatibility testing.
