# SweenLab Debian LXC Creation Wizard

Version 0.3.4. One self-contained script, fully step by step, with Back navigation and a final Create/Abort review.

## Quick Start: copy and paste

Use the copy button in the top-right corner of this block, then paste into your **Proxmox node shell as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/bab07161db6d405c45a7e8e2a2030242961dfc18/scripts/proxmox-debian-lxc-create.sh)"
```

The command is pinned to the version 0.3.4 script to avoid stale raw GitHub main-branch downloads. No clone, companion file, or additional shell-script download is needed.

If an older wizard is still open, abort it and restart with this command. Use a new disposable CT ID for the first test. Do not reuse an ID left by a failed creation until its state has been inspected.

## Before starting

- Run on a Proxmox VE host as root, with its standard `pct`, `pvesh`, `pvesm`, `pveam`, and `lxc-usernsexec` tools.
- Python 3 with its standard `curses` terminal support is required. There is no whiptail/dialog dependency and no automatic installation of host packages.
- Use a normal terminal of at least 80 columns by 24 rows. The UI adapts when you resize it.
- Download a Debian 12 or 13 standard template using Proxmox's template interface first. This wizard lists only templates already downloaded to the selected template storage, matching the host's amd64/arm64 architecture.
- GPU host drivers and GPU device nodes must already work if you want GPU passthrough. Tailscale requires a working host `/dev/net/tun` device.

## Moving through the wizard

Every configuration screen has **Back** and **Abort**. Input, menu, and package screens show **Back / Next / Abort**. Tab cycles **field/list → Back → Next → Abort → field/list**; Shift+Tab reverses it. Yes/No screens show **Back / Yes / No / Abort** horizontally, with Yes initially highlighted except FUSE, GPU passthrough and verbose output, which start at No. The final overview shows **Back / Create / Abort**, with Create highlighted.

- Use Up/Down to select menu items; moving past either end reaches the buttons. Right also moves from a list to the buttons.
- Required single-choice screens (bridge, IPv4/IPv6 modes, storage and Debian template) use `( )` / `(x)` markers. Space or Enter selects a row and immediately highlights Next; press Enter to continue. Highlighting alone is not a selection, and Next is blocked until selected. Accepted choices remain selected when returning with Back.
- Use Space to toggle package, GPU or Tailscale checkboxes. Required package/device screens block empty selections; optional Tailscale flags may be left empty.
- In text/password fields, Up or Down moves to the buttons; Left/Right moves the cursor. From buttons, Up returns to the field/list and Left/Right chooses an action. Yes/No screens also accept Up/Down across actions. Tab and Shift+Tab remain available.
- Press Enter to accept the highlighted action. Esc aborts before creation.
- Ordinary inputs remember values when you go back. Password and confirmation fields always open blank, including retries; type each independently. Conditional screens, such as Tailscale options, follow the packages you selected.
- The overview uses one centered table with aligned labels/values, colored section dividers and a visible scroll-position count. It scrolls with Up/Down or Page Up/Page Down. Back lets you revise settings; Abort creates nothing.

After Create, provisioning begins and Back navigation ends. Failures preserve any remaining new CT/storage state for inspection; the wizard never destroys it automatically.

The UI centers prompts, fields and choices, with required prompts and choices in bold. It explicitly sets orange headings/buttons, green prompts/choices, soft green focused selections, and neutral body text rather than inheriting the Terminal profile foreground. Text and password inputs have a persistent centered grey box, including when empty or when a button has focus. Visible brackets keep the input area identifiable in monochrome. Typed text stays within the box; passwords stay masked. Creation progress uses emojis and colored stage indicators in quiet and verbose modes. Terminals without color support fall back to monochrome; `NO_COLOR=1` also disables color.

## Configuration screens

1. **Container details:** unused cluster-wide ID, blank required hostname, and optional tags separated by semicolons. Tags are case-sensitive: `TEST` and `test` are different. Match the exact capitalization of predefined Proxmox tags.
2. **Networking:** choose an active configured Proxmox Linux bridge. Choices show only names such as `vmbr0` and `vmbr1`; Docker and temporary firewall bridges are hidden. Explicitly select a bridge and each IPv4/IPv6 mode (no mode is preselected; switching to static starts with a blank address field), and addresses/gateways where relevant. Static IPv4 requires an explicit numeric CIDR prefix, for example `10.10.10.204/24`; a bare address, dotted netmask or invalid prefix cannot continue. Prefixes 0–32 are accepted when the address is valid. Untagged networking, an automatically generated MAC, no rate limit, and inherited host DNS/search settings are applied in the background. The container MTU defaults to 1450 bytes and can be edited after choosing a bridge. The wizard accepts whole numbers from 1280 to 65535, up to the bridge MTU when it can read that value. The review shows the MTU passed to Proxmox. Append `-- --mtu 1500` to prefill a different value. Debian reapplies the selected MTU whenever ifupdown brings up eth0. Before updating Debian, the installer checks the live MTU on `eth0` and corrects it if needed.
3. **Resources:** CPU cores, memory in MiB, swap allowance in MiB (required, starts blank; 0 disables swap), root disk size in GiB (initially 10), and container storage. Storage uses a single-choice selector showing `( )` and `(x)` markers alongside names. Highlight with arrows, select with Space or Enter to immediately highlight Next, then press Enter to continue. Next is blocked until a choice is explicitly selected; the first row is not automatically selected. Back preserves your accepted selection.
4. **Timezone and locale:** The guest locale is prefilled from the host configuration: `/etc/locale.conf`, then `/etc/default/locale`. Supported UTF-8 names are normalized; if no supported setting is found, `C.UTF-8` is used. SSH client locale variables are not used. You can edit the choice; it is generated where needed, written as the guest default and verified before the full upgrade. Timezone is automatically prefilled from the Proxmox host's timezone; edit if needed. If the host timezone cannot be resolved, UTC is shown.
5. **Access:** unprivileged mode is initially Yes. Choose an optional host SSH public-key file. Enter and confirm a mandatory root console password. Passwords remain hidden and are never logged or included in command arguments. Setting a console password does not enable root password login over SSH.
6. **Downloaded templates:** explicitly select template storage with the same required single-choice selector, then explicitly select one of the Debian templates already downloaded there. Next is blocked until a template is selected. There is no catalog refresh, separate Debian-release chooser, or automatic template download. If the selected storage has none, Back selects another storage; Abort lets you download a template in Proxmox first.
7. **Packages:** git, curl, wget, Tailscale, Docker Engine/Buildx, Docker Compose (includes Engine), nano, jq, unzip, ping, OpenSSH server, sudo, and Python 3 (with pip and venv). Packages are initially unselected. You must choose at least one package or explicitly select **None**. None clears and excludes individual packages until deselected. Select all / clear all toggles every package and clears None. Selecting all immediately focuses Next; individual package toggles and Clear all keep focus in the list. Use Up from Next to return to the list; Clear all alone cannot continue. None still installs the base locale/timezone support and runs the full upgrade. htop, vim-tiny, tmux, rsync, and dnsutils are no longer choices.
8. **Tailscale:** when selected, choose whether to start sign-in automatically and configure its options (details below).
9. **Features:** nesting, keyctl for unprivileged containers, FUSE, and TUN use horizontal Yes/No controls. The TUN screen appears only when Tailscale is selected and starts at Yes; without Tailscale, TUN is off and no device is passed through. Returning to Packages and removing Tailscale also clears TUN. Nesting and keyctl start at Yes; FUSE starts at No because most installs do not need it and it can complicate freezing/backups. Docker requires nesting and keyctl in unprivileged mode; Tailscale requires TUN. Invalid combinations cannot continue.
10. **GPU:** shown only when GPU nodes exist. Passthrough starts at No. Choose Yes to select individual devices; at least one device must be selected before continuing, or use Back to disable passthrough. There is no arbitrary additional-character-device question or numeric guest-group prompt.
11. **Start at host boot:** Yes is initially selected. Startup order and delays use Proxmox defaults.
12. **Installation output:** verbose output starts at No. Quiet mode shows concise stage progress and keeps full output in the private log; failures show the last 30 lines. Yes streams the full installation output and ends with a checklist of successfully completed stages and selected tools. In-progress stages have no `[..]` marker; only successful work gets a check. Incomplete Tailscale sign-in stays a warning.
13. **Overview:** a grouped summary of container, resources, networking, software/features, and automatic settings. Choose Create or Abort, or Back to revise settings.

The UI no longer presents the old numbered template-catalog or package-upgrade steps.

### Memory conversion

The memory screen shows 1–16 GiB in four equal columns of four entries. Every row has the same width, keeping all conversions aligned. Size labels are neutral grey, the MiB values to enter are bold green, and dim vertical separators distinguish the four columns. Without terminal colors, the bold values and separators still distinguish each entry. The values are:

| Memory | Enter in MiB |
|---|---:|
| 1 GiB | 1024 |
| 2 GiB | 2048 |
| 3 GiB | 3072 |
| 4 GiB | 4096 |
| 5 GiB | 5120 |
| 6 GiB | 6144 |
| 7 GiB | 7168 |
| 8 GiB | 8192 |
| 9 GiB | 9216 |
| 10 GiB | 10240 |
| 11 GiB | 11264 |
| 12 GiB | 12288 |
| 13 GiB | 13312 |
| 14 GiB | 14336 |
| 15 GiB | 15360 |
| 16 GiB | 16384 |

### Automatic settings

These are applied in the background and shown in the overview:

| Setting | Value |
|---|---|
| Interface firewall flag | Enabled (`firewall=1`); existing Proxmox firewall enablement/rules still apply |
| CPU limit / weight | `0` (unlimited) / `100` |
| Package upgrades | Always enabled: refresh APT and full upgrade after locale configuration |
| Guest locale | Detected from host configuration; fallback `C.UTF-8`; editable |
| Passed device UID/GID / permissions | `0:0`, `0660` |
| Startup order / delays | Proxmox defaults |
| Deletion protection | Off |

No firewall, CPU limit/weight, device group-ID, startup-order/delay, protection, or package-upgrade questions are shown. For GPU applications that run as a non-root user, configure guest group access separately after creation.

## Tailscale sign-in and options

When Tailscale is selected, **Run tailscale up automatically** starts as Yes. A checkbox screen offers:

| Option | Initial selection | Effect |
|---|---|---|
| Enable Tailscale SSH | Selected | `--ssh=true`; access still follows tailnet policy |
| Keep existing DNS | Selected | `--accept-dns=false` |
| Accept advertised subnet routes | Unselected | `--accept-routes=true` if selected |

After package installation, the wizard runs `tailscale up` with explicit values for these flags and a 120-second timeout. QR codes are disabled (`--qr=false`); open or copy/paste the login link. The link is shown only on the terminal, outside the host run log. **You still need to authenticate in your browser.** No auth key is requested or stored.

If authentication times out or fails, the created CT and installed packages remain. The wizard prints a retry command using your chosen flags and clearly reports sign-in as incomplete. You can also choose No to automatic sign-in and run it later yourself.

References: [Tailscale up options](https://tailscale.com/docs/reference/tailscale-cli/up), [Tailscale SSH policy](https://tailscale.com/docs/features/tailscale-ssh).

## Rootfs extraction permission errors

The reported error:

```text
tar: /var/lib/lxc/204/rootfs: Cannot open: Permission denied
```

occurs inside Proxmox's template extraction, before guest setup. The wizard through version 0.1.4 passed its private-file `umask 077` to Proxmox. Proxmox's directory creation respects that mask, producing `0700` CT directories that mapped container root (host UID 100000) cannot traverse. This matches the reported root-owned `0700` directories.

Version 0.2.0 runs Proxmox container commands in a subshell with `umask 022`, while logs and UI files retain their private mask. A regression test reproduces the old `0700` behavior with Perl's `File::Path::make_path` and verifies the corrected `0755` directories, private `0600` log files, and command status preservation. The user has since confirmed the wizard is working on Proxmox; the individual permission behavior has not been separately instrumented on that host.

Choose a fresh unused CT ID for the next test. The wizard validates the ID format and checks that no VM or CT uses it through Proxmox. Leftover directories alone do not block selection or trigger a separate pre-creation rejection; Proxmox handles creation errors. Existing failed directories and disks are left untouched for separate inspection. The read-only mapped-root traversal preflight remains in place.

If `pct create` still fails, the wizard prints path/mount diagnostics, identifies the failed CT ID, and preserves any remaining state. It does **not** chmod/chown host directories, change ACLs, disable security protections, destroy the CT, or retry as privileged.

For the reported CT/storage, these commands are read-only and can help diagnose it:

```bash
namei -l /var/lib/lxc/204/rootfs
findmnt -T /var/lib/lxc -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/4tbstorage -o TARGET,SOURCE,FSTYPE,OPTIONS
pct config 204
```

Some paths or the CT configuration may no longer exist after Proxmox's own cleanup. Do not run another creation with ID 204 until the remaining configuration/storage has been inspected. Use a fresh ID to test the corrected release; inspect old storage separately before deciding whether to remove it.

## Locale and full upgrade

The guest installer is launched under the built-in `C.UTF-8` locale to avoid an inherited not-yet-generated locale warning before setup. The installer refreshes APT and installs locale support, generates the selected locale if needed, resets stale locale overrides, and writes both `/etc/locale.conf` and `/etc/default/locale` for Debian 12/13 compatibility. It activates and verifies UTF-8 in the installer environment. It then refreshes APT again and runs `apt-get -y dist-upgrade` (with the existing keep-config policy), the script-oriented equivalent of `apt full-upgrade -y`. A failed locale check stops setup instead of reporting success. New login sessions use the saved system default; an already-open shell can retain its previous environment.

References: [Debian 13 update-locale](https://manpages.debian.org/trixie/locales/update-locale.8.en.html), [Debian APT command equivalents](https://www.debian.org/doc/manuals/debian-faq/pkgtools.html).

## Automatic Summary notes

New containers receive the [generic branded notes block](container-notes.md) through the description argument during creation. After guest package setup, a dedicated **Save and verify Summary notes** step writes the complete block again with `pct set --description` and reads the configuration back through the Proxmox API. A failed write or mismatched description stops completion with the container preserved, rather than silently claiming success. It contains only the banner and GitHub/Guide/Releases links, centered horizontally and vertically within a 280-pixel-high layout area. The creation review lists this automatic setting. Existing containers and custom notes are not updated. The wizard version is retained in a hidden HTML comment.

## Logs, safety, and retry behavior

Host logs are saved under `/var/log/sweenlab-debian-lxc/` with restrictive permissions. The final plan, installer hash, package output, and read-only diagnostics are recorded. Passwords and Tailscale login URLs are excluded.

The script uses official Proxmox creation commands and signed vendor package repositories. It does not source external shell installers, disable AppArmor, change host device ownership, install host packages, automatically reboot, prune data, or mutate an existing CT. A VM is the stronger-isolation option for nested application containers.

The embedded guest installer stays at `/root/sweenlab-debian-tools.sh` in the newly created CT. For a reviewed retry after a package failure, enter the correct CT and rerun the installer with the same selected packages and timezone. For example:

```bash
pct enter YOUR_CTID
bash /root/sweenlab-debian-tools.sh --timezone America/New_York --locale en_US.UTF-8 --upgrade 1 git curl compose tailscale
```

That retry example applies only after the CT has been created and the installer copied successfully. It cannot fix template-extraction errors. Re-running APT installs can install newer available versions; Docker data and Tailscale identity are preserved.

## Validation and release history

Local checks cover bridge filtering, cached-template filtering through the real configuration flow, required hostname/passwords, Back preserving values, abort-before-mutation, hidden defaults, Tailscale flags/auth-output isolation, namespace preflight failure, creation diagnostics, and installer-failure preservation. UI rendering/key-handling tests cover the button layouts, defaults, masking, selections, and navigation. Bash syntax and all 69 local tests passed, including simulated review and container creation at 1450, 1500 and 9000, fallback behavior, and manual override validation. This release was not tested on a live Proxmox host. Real curses pseudo-terminal smoke checks cover blank password submission at 80×24 and 93×24, plus review rendering at 93×24, with the orange/green color sequences verified. Checklist tests cover successful installation and incomplete Tailscale authentication.

These are simulated/terminal checks, not a successful live Proxmox installation. Live extraction, packages, Docker workloads, Tailscale login, GPU access, and your host's actual permissions remain to be validated.

Every user-visible update has a new version, [changelog entry](../CHANGELOG.md), and [GitHub release](https://github.com/SweenLab/sweenlab-scripts/releases).
