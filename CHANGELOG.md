# Changelog

Each user-visible update is recorded here and on the [GitHub Releases page](https://github.com/SweenLab/sweenlab-scripts/releases). Debian wizard tags use `debian-lxc-vX.Y.Z`; older `v1.x` releases belong to the retired maintenance wizard.

## Debian LXC Wizard 0.3.2 — 2026-11-11

- Verify the running container’s MTU on `eth0` and correct any mismatch before Debian package updates. Stop if the selected MTU cannot be verified.

## Debian LXC Wizard 0.3.1 — 2026-11-11

- Require a container MTU after bridge selection. Validate the entered value and display it before passing it to Proxmox.
- Keep `--mtu` as a way to prefill the required step.

## Debian LXC Wizard 0.3.0 — 2026-11-10

- Set the new container’s MTU from the active Linux bridge selected in the wizard. The review shows the value passed to Proxmox. If the bridge MTU is unavailable, use 1500.
- Add an optional `--mtu` launch argument for networks that require a manually selected MTU.

Bash syntax and all 69 local tests passed, including simulated review and container creation at 1450, 1500 and 9000, fallback behavior, and manual override validation. This release was not tested on a live Proxmox host.

## sweenlab Proxmox Cleanup 2.1.1 — 2026-11-06

- Fix flashing between progress windows and shell output by keeping one curses session open for setup, scanning, cleanup and final results.
- Reuse the same screen for every dialog/progress update and defer ordinary stdout/stderr messages until terminal restoration. Preserve messages and restore session state on exceptions.
- Keep cleanup worker, confirmations, exclusions and space measurements unchanged. Update launcher, README and guide.

Validation: 59 tests pass, including an actual local pseudo-terminal check proving one alternate-screen entry/exit across three inspections, deferred messages and exception cleanup. Python compilation, Bash syntax, unchanged worker check and published download verification pass. No live Proxmox/SSH run performed for this patch.

## sweenlab Proxmox Cleanup 2.1.0 — 2026-11-06

- Show confirmed deleted-file counts, logical bytes deleted and measured root-filesystem free-space changes per cleaned system and in total, with totals at the top of the final screen.
- Measure free bytes immediately before/after cleanup with statvfs and preserve signed changes, raw counters and measurement coverage in audit reports. Do not equate guest/filesystem totals with physical backend recovery.
- Preserve worker output on command errors to report confirmed partial deletion counters where available; show missing measurements as unavailable. No deletion eligibility or confirmation rules are relaxed.
- Update launcher checksum, immutable commands, README and guide.

Validation: 55 tests pass, including positive/negative totals, missing measurements, partial counts, malformed output and retained worker-error output. Python compilation, Bash syntax and published downloads verified. No live Proxmox/guest cleanup measurement run performed.

## sweenlab Proxmox Cleanup 2.0.0 — 2026-11-06

- Major workflow update: inspect all selected systems automatically, without an inventory, error or Next dialog per guest. Show one combined scan report.
- Replace per-guest cleanup selection/confirmation with one consolidated target/file checklist, recovery acknowledgement, exact `delete batch` phrase and final Delete files action defaulting to Back.
- Bind each approved file to its exact target. Audit the complete batch mapping before any deletion, then execute authorized targets sequentially with existing fresh eligibility/fingerprint checks. Record failures and continue remaining authorized targets without retrying failed commands.
- Consolidate text-mode scanning/review as well; show one final result report. Preserve exclusions, inventory default, unsupported/stopped/locked guest skipping and all worker-level protections.
- Update launcher, README and guide; preserve historical releases.

Validation: 45 tests pass, including multiple-system scan completion without per-guest prompts, failure continuation, cross-target file identity, single batch approval, empty selection and abort-before-cleanup. Python compilation, Bash syntax, unchanged worker payload and published downloads verified. No live Proxmox/guest batch cleanup testing performed.

## sweenlab Proxmox Cleanup 1.1.1 — 2026-11-06

- Fix the missing Select all / clear all row on the Targets screen. Both target and file checklists now include it.
- Preserve excluded-target restrictions and the requirement to choose at least one target. Bulk target selection never authorizes cleanup or selects deletion candidates.
- Update version, launcher checksum, README and guide while preserving historical releases.

Validation: 38 safety/UI tests pass, including the actual target options, bulk selection and the empty-target guard. Python compilation, Bash syntax and published download verification pass. No live Proxmox cleanup test performed.

## sweenlab Proxmox Cleanup 1.1.0 — 2026-11-06

- Add Select all / clear all as the first file-checklist row for each target. Space selects all eligible files, clears a complete selection, or completes a partial selection. Individual file toggles remain available.
- Keep the initial allowlist empty and preserve full-path review, recovery acknowledgement, exact typed target confirmation and final Delete files action defaulting to Back. No guest-worker deletion rules changed.
- Set the requested release version to 1.1.0; update launcher checksum, immutable README/guide commands and instructions.

Validation: all 35 cleanup safety/UI tests pass, including select-all, clear-all, partial selection, empty initial selection and rejection of the UI action marker as an allowlist. Bash syntax and Python compilation pass. Published downloads verified during release; no live Proxmox cleanup test performed.

## sweenlab Proxmox Cleanup 0.2.0 — 2026-11-06

- Add centered interactive windows using the LXC creator's actual renderer, orange/green palette, grey inputs, keyboard controls and Back/Next/Abort navigation.
- Add mode, target, exclusion, retention and scan-review screens, inspection/cleanup wait windows, scrollable inventory and exact-path reviews, per-target results and a final report screen.
- Start with inventory selected; leave all deletion candidates unchecked. Require recovery acknowledgement, exact typed target confirmation and a final Delete files action whose default focus is Back.
- Preserve CLI restrictions, text mode via `--no-ui`, noninteractive inventory and all existing guest-worker protections. Close report/lock handles on all controller exits.
- Update the checksum-verified short launcher, README and step-by-step guide with immutable commands.

Validation: 30 safety/UI tests pass, including full mocked inventory/apply/abort flows, exact renderer palette and final Back default. Python compilation, help/version, Bash syntax and local terminal open/abort checks pass. Guest deletion worker verified unchanged. No live Proxmox or guest cleanup testing performed.

## sweenlab Proxmox Cleanup 0.1.1 — 2026-11-06

- Add the short root-level `cleanup.sh` Bash launcher, with a pinned Python download, SHA-256 verification, private temporary file and automatic cleanup of its own download.
- Preserve inventory by default; `--apply` explicitly enables the existing file selection and typed confirmation flow. Forward target and exclusion options unchanged.
- Simplify README and guide commands; retain optional persistent installation instructions. Cleanup eligibility and protected resources are unchanged.

Validation: 14 cleanup safety tests, Bash syntax, Python CLI version, and launcher success/checksum-failure smoke checks pass. Published downloads verified during release. No live Proxmox or guest cleanup testing performed.

## sweenlab Proxmox Cleanup 0.1.0 — 2026-11-06

- Add a new inventory-first cleanup tool for the node, running LXCs and Debian-family VMs with guest-agent access, plus explicit in-guest mode.
- Limit cleanup to root-owned verified old .deb downloads and verified archived system journals, with exact file selection, typed target confirmation, revalidation and SHA-256 fingerprints.
- Exclude symlinks, hard links, mounted/excluded paths and locked/stopped guests; respect APT locks. No deletion paths for disks, volumes, backups, snapshots, user files or trash.
- Add private JSONL audit reports, exclusions, backup/snapshot guidance and a checksum-verified launch block pinned to script commit `7c1300cd0ade6cf011163b255fdd6ad0b6f628d7`.
- Preserve existing tools and historical releases; this is a new conservative implementation, not a restoration of the retired maintenance wizard.

Validation: all 14 cleanup safety tests pass; Python compilation and CLI help/version checks pass. Launcher Bash syntax verified. No live Proxmox, LXC, guest-agent or real cleanup run was performed.

## Debian LXC Wizard 0.2.0 — 2026-10-31

- Promote the working v0.1.25 wizard to the v0.2.0 milestone at the user's request, with no functional changes.
- Include explicit swap selection, saved/verified branded Summary notes, the aligned high-contrast 1–16 GiB memory chart, and TUN selection only with Tailscale.
- Update script and documentation version labels, testing status, and the immutable launch command; preserve all historical release tags.

Validation: the user confirmed v0.1.25 is working on Proxmox. Bash syntax, diff checks and all 67 local tests pass for v0.2.0. Optional feature combinations have not been exhaustively tested on live hosts; no additional live provisioning run was performed for this version promotion.

## Debian LXC Wizard 0.1.25 — 2026-10-31

- Show the TUN passthrough screen only when Tailscale is selected. Without Tailscale, TUN is disabled and /dev/net/tun is not passed through. Removing Tailscale on a return to Packages clears TUN as well.
- Retain the required TUN check when installing Tailscale. Update README, guides, version labels and immutable launcher.

Validation: Bash syntax, diff checks and all 67 tests pass, including TUN shown/enabled with Tailscale and hidden/absent from device arguments without Tailscale or with no packages, plus removal through Back navigation. No live Proxmox provisioning test was performed for this release.

## Debian LXC Wizard 0.1.24 — 2026-10-31

- Improve the memory chart contrast: neutral grey size labels, bold green MiB values to enter, and dim vertical column separators. Keep the four equal aligned columns and all 1–16 GiB conversions.
- Preserve bold-value and separator cues in terminals without color. Update README, guides, version labels and immutable launcher.

Validation: Bash syntax, diff checks and all 65 tests pass, including actual embedded-UI rendering at 80 × 24: color attributes, all conversions and consistent column positions. No live Proxmox display test was performed for this release.

## Debian LXC Wizard 0.1.23 — 2026-10-31

- Arrange the 1–16 GiB memory chart in four equal columns of four entries, eliminating the shorter rows that were centered separately in v0.1.22. All rows fit a standard 80-column terminal.
- Update README, guides, version labels and the immutable launcher.

Validation: Bash syntax, diff checks and all 64 existing tests pass. Verified equal row widths and complete 1–16 GiB coverage within the prompt limit. Live Proxmox display has not been tested for this release.

## Debian LXC Wizard 0.1.22 — 2026-10-31

- Expand the Memory screen conversion chart to every whole GiB from 1 through 16, including 3 GiB = 3072 MiB. Use three compact columns within the dialog's eight-line prompt limit so every entry is visible at standard terminal width.
- Update the README, guide chart, notes version label and immutable launch command.

Validation: Bash syntax, diff checks and all 64 existing tests pass. Confirmed all 16 conversions and the chart's eight-line/standard-width fit. No live Proxmox provisioning was performed for this display-only change.

## Debian LXC Wizard 0.1.21 — 2026-10-31

- Add a required Swap screen immediately after Memory. It starts blank, accepts whole MiB including 0 to disable swap, preserves entries with Back, and shows the selected allowance in the review and creation command. Remove the fixed 512 MiB setting.
- Save the branded Summary notes explicitly after guest package setup and verify the exact saved description through the Proxmox API before reporting completion. Keep the initial creation description as well. A failed save or mismatched readback stops completion and preserves the CT for inspection.
- Update the README, creation guide, notes guide and immutable launcher together.

Validation: Bash syntax, diff checks and all 64 local tests pass. Regression tests cover custom/zero/invalid swap values, Back navigation, notes dropped during creation, final notes save failures and readback mismatches. No live Proxmox provisioning or browser-rendering test was performed for this release.

## Hawser Agent Setup 0.1.2 — 2026-10-28

- Remove the verbose-output question and always stream installation output, with tokens still redacted.
- Change the review actions to Create, Abort, Back in that order; highlight Create by default. Tab/Shift+Tab and arrow keys cycle through these three actions.
- Keep Back editing and the final completion checklist; update README and guide with the new immutable launcher.

Validation: Bash syntax, diff checks and all 12 Hawser tests pass, including final action order, default Create, Abort/Back navigation and removal of the verbose prompt. Live LXC installation has not been repeated.

## Hawser Agent Setup 0.1.1 — 2026-10-28

- Highlight Yes by default on the verbose output selector. No remains available; explicit selection and Back navigation are unchanged.
- Update version labels and the immutable README/guide launcher.

Validation: Bash syntax, diff checks and all 10 Hawser tests pass. Live LXC installation has not been repeated.

## Hawser Agent Setup 0.1.0 — 2026-10-28

- Add a self-contained orange/green setup wizard for the native Hawser service inside Docker LXCs. Paste a Dockhand-generated token or generate one with F2; no Compose file is required.
- Add validated agent name/token/stack-directory inputs, horizontal explicit Yes/No for verbose output, Back/Next/Abort and an Install review.
- Download the latest official agent, verify its release checksum, configure private token authentication, enable/start systemd and verify health plus boot startup.
- Back up existing files, restore them and attempt to restore service state on installation failure; preserve unrelated config, exclude tokens from logs and reject conflicting Edge/TLS/custom-bind or Docker-agent deployments.
- Show a final checklist and Dockhand connection values. Existing application containers are not restarted; existing Compose stacks require separate import.
- Add an immutable launcher and dedicated setup guide. The Debian LXC wizard stays at 0.1.20.

Validation: Bash syntax, diff checks and all 57 local tests pass, including 10 new agent tests covering input validation, required selection/navigation, checksum mismatch, private writes, simulated install/token redaction and rollback. Official release asset names were verified. Live Linux/systemd/LXC setup remains unverified.

## Debian LXC Wizard 0.1.20 — 2026-10-28

- Automatically add generic branded Summary notes to new LXCs through pct create --description: compact banner plus GitHub, Guide and Releases links, with no app-specific text.
- Center the block horizontally and vertically in a 280-pixel-high layout using supported table attributes. It does not dynamically follow arbitrary panel heights; no Proxmox UI/CSS files are changed.
- Retain wizard version in a hidden comment and show the automatic notes setting in the creation review. Existing guests are not modified.
- Replace previous app-specific notes examples with the shared generic template; update README, guide and immutable launcher.

Validation: host Bash syntax and 47 local tests pass, including complete multiline notes passed as one creation argument, generic content, and unchanged existing guests. HTML attributes were checked against Proxmox's sanitizer allowlist. Live provisioning/rendering of this release remains unverified.

## Debian LXC Wizard 0.1.19 — 2026-10-28

- Added a dedicated 280 × 112 banner for narrow Proxmox Summary Notes panels, avoiding reliance on image width attributes.
- Replaced the notes guide with short generic and Dockhand templates: compact banner, heading, one description and one link row. Removed unnecessary detail blocks from the suggested layout.
- Updated README/guide version labels and immutable launcher. Provisioning behavior is unchanged.

Validation: banner dimensions confirmed, host Bash syntax and diff checks pass. Live Notes-panel rendering has not been confirmed; the user must replace the existing note manually. No existing guest was modified.

## Debian LXC Wizard 0.1.18 — 2026-10-28

- Renamed the repository from personal-proxmox-scripts to sweenlab-scripts.
- Added the approved SWEENLAB SCRIPTS banner and crisp 45-degree split crest under assets/branding; displayed the banner on the README.
- Added an optional copyable Proxmox notes template with a commit-pinned banner URL. Existing container notes are not changed.
- Updated repository links, README/guide version labels and immutable launch command. Wizard installation behavior is unchanged.

Validation: Bash syntax and all 46 local tests pass. Public script and branding URLs are verified during publication. Live Proxmox provisioning has not been repeated for this branding/repository change.

## Debian LXC Wizard 0.1.17 — 2026-10-28

- Static IPv4 now requires an explicit numeric CIDR prefix (0–32), such as 10.10.10.204/24. Bare addresses are rejected rather than implicitly accepted as /32.
- Missing/invalid prefixes, dotted netmasks and invalid IPv4 addresses keep the wizard on the address screen with a clear correction message.
- Updated README, guide and immutable launcher.

Validation: Bash syntax and all 46 local tests pass, including rejected bare addresses in the actual configuration flow and validator checks for valid /0, /24 and /32 plus malformed inputs. Live Proxmox provisioning has not been repeated for this input-validation change.

## Debian LXC Wizard 0.1.16 — 2026-10-28

- Selecting all packages immediately focuses Next. Individual package choices keep focus in the list so multiple selections can be made.
- Clear all keeps focus in the list; the existing required-selection stop remains. Up from Next returns to the list to adjust choices.
- Updated README, guide and immutable launcher.

Validation: Bash syntax and all 44 local tests pass, including Select all focus, individual toggles and Clear all focus behavior. Live Proxmox provisioning has not been repeated for this navigation change.

## Debian LXC Wizard 0.1.15 — 2026-10-28

- Single-choice selections immediately move focus to Next after Space or Enter selects a row. Press Enter again to continue. Applies to bridge, IPv4/IPv6 modes, storage and template selectors.
- Required-selection hard stops and Back editing remain. Multiple-choice package/device/Tailscale checklists keep list focus for additional selections.
- Updated README, guide and immutable launcher.

Validation: Bash syntax and all 43 local tests pass, including Space/Enter selecting and focusing Next, changing a selection via Up, and rejecting an unselected choice. Live Proxmox provisioning has not been repeated for this navigation change.

## Debian LXC Wizard 0.1.14 — 2026-10-28

- Extended explicit single-choice selectors to network bridge, IPv4 mode, IPv6 mode and downloaded Debian template, matching storage. Highlighting alone does not select; Space/Enter selects, then Next continues.
- IPv4/IPv6 modes start unselected. Required choices hard-stop Next until selected; accepted choices survive Back navigation.
- Required checkbox screens also stop empty selections in the UI. Package None remains an explicit valid choice; enabling GPU passthrough now requires at least one device.
- Optional Tailscale flags may remain empty. Existing Yes/No defaults and required text-field validation remain.
- Updated README, guide and immutable launcher.

Validation: Bash syntax and all 43 local tests pass, including required selection UI, network-mode rejection, GPU-device rejection and selector types throughout the configuration flow. Real curses selection/password/review smoke checks pass. Live Proxmox provisioning of this version remains unverified.

## Debian LXC Wizard 0.1.13 — 2026-10-28

- Container and template storage now use explicit single-choice selectors with visible ( ) / (x) markers. Moving the highlight does not select an option.
- Space or Enter selects the highlighted storage; Next cannot continue without a selection. Back preserves a previously accepted choice.
- Updated README, guide and immutable launcher.

Validation: all 40 local tests and Bash syntax pass. Tests cover hard-stop behavior, exclusive selection and Back navigation. Real curses storage selection passes at 93×24, alongside existing password/review smoke checks. Live provisioning has not been repeated for this UI change.

## Debian LXC Wizard 0.1.12 — 2026-10-28

- Added a persistent centered grey input box to text and password screens. Empty fields remain visible, including when focus moves to buttons.
- Visible brackets provide a monochrome fallback; long input scrolls inside the box and passwords remain masked.
- Updated README, guide and immutable launcher.

Validation: Bash syntax and all 38 local tests pass, including empty-field visibility and persistence. Real curses password submission passes at 80×24 and 93×24; review smoke check passes at 93×24. Live Proxmox provisioning has not been repeated for this visual change.

## Debian LXC Wizard 0.1.11 — 2026-10-28

- Fixed Tab/Shift+Tab order so Back, Next, Abort and field/list are all reachable. Arrow navigation remains available.
- Password and confirmation inputs always start blank, including retries and Back navigation; saved masked values are never prefilled.
- Explicit foreground colors make the orange/green theme consistent across menus and Terminal profiles. Text inputs use a compact selection-style highlight instead of a full-width inverse bar.
- Rebuilt review rendering as an aligned centered table with section dividers, neutral values and scroll-position count.
- Removed bracketed progress markers. Verbose installation ends with a checklist of completed stages/tools; incomplete Tailscale authentication is a warning, never checked off.
- Bootstrap guest Bash in C.UTF-8 before generating the selected locale to avoid inheriting a locale that does not yet exist.
- Updated README, guide and immutable launcher.

Validation: all 37 local tests pass; host and embedded installer Bash syntax pass. Real curses checks verified password submission and orange/green colors at 80×24 and 93×24, plus review rendering at 93×24. Full live Proxmox provisioning of this release has not been performed.

## Debian LXC Wizard 0.1.10 — 2026-10-28

- Root disk initially 10 GiB.
- Detect locale from host configuration, normalize supported UTF-8 values, and fall back to C.UTF-8. Timezone remains host-derived with UTC fallback; both are editable.
- Require packages or explicit exclusive None. Select all/clear all remains available; None is not passed to APT.
- Remove the Tailscale Shields Up choice and flag.
- Strengthen guest locale setup: generate when needed, reset overrides, persist Debian 12/13 defaults, activate/verify UTF-8, then refresh APT and run a full upgrade using apt-get dist-upgrade.
- Center wizard content, bold required prompts/choices, and add emoji/color installation stages while preserving quiet/verbose output and private logs.
- Update README, guide and immutable launcher.

Validation: Bash syntax for host and embedded installer plus all 31 local tests pass, including host-locale precedence/fallback, guest activation-before-upgrade ordering, required/None package behavior, centered bold content, disk default and Tailscale arguments. This release has not been tested end-to-end on a live Proxmox host; the earlier reported locale issue cannot be confirmed resolved on that host yet.

## Debian LXC Wizard 0.1.9 — 2026-10-28

- Added a case-sensitivity note to the tags screen: TEST and test are different tags. Match the exact capitalization of predefined Proxmox tags.
- Updated the guide, README version and immutable launcher. Tag handling is unchanged.

Validation: Bash syntax and diff checks pass. This wording-only update has not been live-tested on Proxmox.

## Debian LXC Wizard 0.1.8 — 2026-10-28

- Removed VLAN, MTU, MAC, rate limit, DNS and search-domain screens. Apply untagged networking, MTU 1500, automatic MAC, no rate limit and inherited DNS/search settings in the background. Bridge, IPv4/IPv6 mode and relevant address/gateway screens remain.
- Added arrow-only navigation between fields/lists and buttons. Text-field Left/Right cursor editing and review scrolling remain; Tab navigation is still supported.
- Updated README, guide and immutable launcher.

Validation: Bash syntax and all 27 local tests pass, including arrow-only navigation, cursor editing and background networking arguments. Live Proxmox testing of this version remains required.

## Debian LXC Wizard 0.1.7 — 2026-10-28

- Removed the leftover-directory restriction from container ID selection and the equivalent pre-creation rejection. ID format validation and Proxmox checks for IDs already in use remain.
- Existing directories are not automatically changed or removed; Proxmox reports creation failures normally.
- Updated README, guide and immutable launcher.

Validation: Bash syntax and 25 local tests pass. Workflow fixtures now contain an existing CT host directory and proceed through selection and simulated creation. Live Proxmox testing remains required.

## Debian LXC Wizard 0.1.6 — 2026-10-28

- Added readable orange/green terminal accents with monochrome fallback, concise installation stages, and an optional verbose-output screen. Quiet mode retains full command output in the private log and shows failure details.
- Static address entry starts blank when switching from DHCP/manual; Back retains an accepted static address.
- Added package Select all / clear all and Python 3 with pip and venv.
- FUSE and GPU passthrough now start at No; nesting, keyctl, TUN and boot defaults are preserved.
- Added an editable UTF-8 guest locale, generated and set during installation.
- Removed the Tailscale QR choice; sign-in uses an open/copy/paste link, excluded from logs.
- Updated README, guide, and immutable launcher.

Validation: all 26 local tests pass, including theme initialization, bulk selection, blank static entry, locale handoff, defaults, link-only sign-in, quiet/verbose output and failure preservation. Host and embedded guest Bash syntax pass. This release has not yet been tested end-to-end on a live Proxmox host.

## Debian LXC Wizard 0.1.5 — 2026-10-28

- Fixed the wizard's private `umask 077` leaking into Proxmox commands. Container commands now use a scoped `022` mask so newly created CT paths can be traversed by mapped container root; private wizard files keep their restrictive permissions.
- Reject CT IDs with leftover host directories or symlinks before creation, without changing or deleting existing state.
- Updated the guide with the identified extraction failure cause and a fresh-ID test procedure. Updated README and guide launchers to the immutable corrected script commit.

Validation: all 22 local tests pass, including reproduction of the original `0700` directories with Proxmox's Perl directory-creation mechanism, corrected `0755` modes, private `0600` files, preserved failure statuses, and leftover-directory/symlink rejection. Bash syntax passes. Live Proxmox creation and package installation remain to be tested.

## Debian LXC Wizard 0.1.4 — 2026-10-28

- Replaced one-way menus with an embedded terminal UI: Back on every configuration screen, remembered values, horizontal Back/Yes/No/Abort controls, Yes initially highlighted, and a grouped Back/Create/Abort overview.
- Bridge and storage options show names only. Added a MiB/GiB conversion chart to memory entry.
- Hid firewall, CPU limit/weight, swap, startup order/delays, device group ID, deletion protection and upgrade questions. Background values: firewall on, CPU limit 0/weight 100, swap 512 MiB, Proxmox startup defaults, device UID/GID 0, protection off, mandatory Debian upgrades.
- Timezone is prefilled from the Proxmox host (UTC fallback). Root password and confirmation are mandatory and hidden.
- Removed the template catalog refresh and Debian-release chooser. Select template storage and a matching Debian template already downloaded there; no automatic template downloads.
- Removed htop, vim-tiny, tmux, rsync, and dnsutils from the package choices. Removed arbitrary extra character-device passthrough.
- Added optional automatic `tailscale up`, with SSH and keep-existing-DNS selected initially, optional routes/shields settings, QR output, a bounded authentication wait, and no login URL in host logs. Browser authentication still requires the user.
- Nesting, keyctl, TUN and host-boot choices start at Yes. Other Yes/No screens also initially highlight Yes; choices are retained when going back.
- Added a read-only mapped-root traversal preflight and explicit path/mount diagnostics on creation failure. The reported host rootfs permission problem is not claimed repaired: no host permissions, ACLs or security settings are changed automatically.
- Updated the README, guide, pinned launcher, and release notes.

Validation: 20 committed bridge/workflow/UI tests plus single-file syntax/help and a real 93×24 pseudo-terminal Yes/No smoke check. No live Proxmox deployment or repair of the user's host was performed.

## Debian LXC Wizard 0.1.3 — 2026-10-28

- Fixed the network bridge menu listing Docker and temporary per-guest firewall bridges.
- Read active Linux bridges from the Proxmox node network API, preserving custom configured bridge names rather than restricting choices to `vmbr*`.
- Explicitly exclude Docker and Proxmox firewall runtime bridge names, sort choices naturally, and verify the selected bridge belongs to the eligible list.
- Stop with a clear message if network discovery fails or no eligible bridge exists; do not fall back to listing every runtime bridge.
- Updated the README, guide, and version-specific launch command.

Validation: fixtures reproduce the reported mixed bridge list, verify `vmbr0`/`vmbr1` and custom configured bridges are kept, and check API errors, malformed responses, no eligible bridge, and invalid selection. Existing simulated creation/cancellation/failure and single-file launch checks pass. Live Proxmox validation is still required; no running guest or host networking was changed.

## Debian LXC Wizard 0.1.2 — 2026-10-28

- Removed the prefilled `sweenlab-debian` hostname. The field starts blank; an empty hostname stops the wizard before creation with a clear required-field error.
- Pinned the documented launcher to a verified script commit because the raw main-branch URL served a stale cached copy.
- Added visible version 0.1.2 so users can identify the downloaded wizard.
- Made the command easy to copy from the README and the guide's Quick Start section.
- Updated the README to focus on the Debian wizard and removed the Task Scheduler, Health Check, Host & LXC Maintenance Wizard, VM Maintenance Wizard, and their four guides from main. Historical releases remain available.
- Added a release requirement for every future user-visible tweak or update.

Validation: Bash syntax; one-file `bash -c` launch help; embedded installer extraction and syntax; required-hostname rejection; simulated cancellation, static IPv4/IPv6 and tag arguments, creation settings, and failure preservation. A commit-specific download was verified to contain version 0.1.2 and the blank required hostname. Live Proxmox, Docker, Tailscale, and GPU testing is still required.

## Debian LXC Wizard 0.1.1 — 2026-10-28

- Combined host creation and guest setup into a single self-contained script.
- Removed the separate companion installer from the repository.
- Added one-line launch instructions to the README and guide.
- Kept an embedded guest installer saved inside the created CT for reviewed retries.

## Debian LXC Wizard 0.1.0 — 2026-10-28

- Added a fully step-by-step Debian 12/13 LXC creation wizard with resource, networking, tags, access, startup, and protection choices.
- Added selectable Debian utilities, Docker Engine, Docker Compose, and Tailscale using package repositories.
- Added explicit unprivileged/privileged selection, nesting, keyctl, FUSE, TUN, and GPU/character-device options.
- Added final plan confirmation, restrictive logging, and preservation of the new CT if installation fails.

Earlier development versions are recorded retrospectively from this repository's commits. Version 0.1.2 is the first dedicated Debian wizard GitHub release.
