# Komodo Periphery onboarding helper

Interactive installer for adding a **new** Linux machine to an existing [Komodo](https://komo.do/) installation using **outbound Periphery onboarding**.

The helper prompts for the Komodo Core URL and desired server name, creates an X25519/PKCS#8 onboarding private key, displays it so you can register it in Komodo's **Pre-Existing Key** field, and only then invokes Komodo's official Periphery installer. Periphery runs under systemd.

## Requirements

- Linux with systemd and root access; intended for Debian/Ubuntu hosts, LXCs, and VMs
- `bash`, `python3`, `curl`, `openssl`, and `systemctl` already installed
- An existing Komodo Core instance reachable from the target server
- A new Periphery installation (the helper **refuses to alter existing configurations**)
- Docker installed and accessible to Periphery if you want Docker management, not just system information

## Usage

Download, inspect, and run the script on the server you want to add:

```bash
git clone https://github.com/SweenLab/sweenlab-scripts.git
cd sweenlab-scripts/scripts/komodo-periphery-onboard
less install.sh
sudo bash install.sh
```

The script will:

1. Ask for your **full Core URL**, for example `https://komodo.example.com` or `ws://192.168.1.50:9120` (use the scheme and port actually exposed by Core).
2. Ask for a server name, defaulting to the local hostname.
3. Generate an onboarding key and **pause** so you can enter it at **Settings → Onboarding → New Onboarding Key → Pre-Existing Key**. Choose a suitable expiry, and generally leave `Privileged` disabled for a new server.
4. After you type `YES`, run Komodo's official setup script and enable Periphery.
5. Ask you to verify that the server appears in **Komodo → Servers** and reports a healthy connection.

Do **not** put real onboarding keys in the GitHub repository, issue reports, command histories, or public logs. The onboarding key is a private credential; it is displayed only in the local terminal and stored in the local Periphery configuration. Once successfully onboarded, Komodo's public/private key authentication takes over and the onboarding key can be removed.

## Why does this stop before installing?

The script generates the key **locally** first. It must be registered as a Pre-Existing Key in the Komodo dashboard before Periphery attempts onboarding. It avoids the confusing race where an agent starts before its onboarding key exists in Core.

## Existing Periphery installations

This script deliberately refuses to overwrite `/etc/komodo/periphery.config.toml` or an existing `periphery.service`. Use [Komodo's instructions](https://komo.do/docs/setup/connect-servers) to update an existing machine's outbound settings manually. Do not replace an established Periphery private key or onboard an already-managed server as a new identity without planning the migration.

## Troubleshooting

```bash
systemctl is-active periphery
journalctl -u periphery -n 50 --no-pager
```

Check the Core URL, firewall/routing, onboarding expiry, and exact server name. If Periphery is running but Docker isn't visible, verify Docker is installed, running, and accessible to the Periphery service account.

## Security notes

- The installer downloads and executes the current upstream Komodo installer, which currently selects the latest release by default. For reproducible installs, review and pin the upstream installer and release version before deploying broadly.
- This is a root-level service with potentially broad Docker access; run it only on trusted systems.
- A private onboarding key is briefly passed as a process argument to the upstream installer. For stricter credential-handling environments, use a reviewed, locally managed configuration instead.
- Review downloaded scripts before executing them. Use HTTPS/WSS for connections over untrusted networks.

## Upstream references

- [Connect More Servers](https://komo.do/docs/setup/connect-servers)
- [Official installer](https://github.com/moghtech/komodo/blob/main/scripts/setup-periphery.py)
- [Periphery config](https://github.com/moghtech/komodo/blob/main/config/periphery.config.toml)

## License

See the [repository license](../../LICENSE).
