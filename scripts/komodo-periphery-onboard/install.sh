#!/usr/bin/env bash
# Generic Komodo Periphery outbound onboarding helper (systemd, root install).
set -Eeuo pipefail
umask 077

CONFIG=/etc/komodo/periphery.config.toml
UPSTREAM=https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Run as root (sudo bash install.sh).'
command -v systemctl >/dev/null || fail 'systemd is required.'
command -v python3 >/dev/null || fail 'python3 is required.'
command -v curl >/dev/null || fail 'curl is required.'
command -v openssl >/dev/null || fail 'openssl is required.'
[[ ! -e $CONFIG ]] || fail "Existing configuration found at $CONFIG. No changes were made. This installer is for new installations only."
[[ ! -e /etc/systemd/system/periphery.service ]] || fail 'Periphery systemd service already exists. No changes were made.'

printf '\nKomodo Periphery onboarding helper\n==================================\n'
read -r -p 'Komodo Core address (example: https://komodo.example.com or ws://192.168.1.50:9120): ' CORE
[[ -n $CORE ]] || fail 'Core address is required.'
# Reject malformed and ambiguous host input. Preserve the supplied scheme.
[[ $CORE =~ ^(https?|wss?)://[^[:space:]/]+(/[^[:space:]]*)?$ ]] || fail 'Use a full http(s) or ws(s) URL.'
[[ $CORE != *\"* && $CORE != *\\* ]] || fail 'Invalid characters in Core address.'
HOSTNAME_DEFAULT=$(hostname)
read -r -p "Server name [$HOSTNAME_DEFAULT]: " SERVER
SERVER=${SERVER:-$HOSTNAME_DEFAULT}
[[ $SERVER =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || fail 'Use letters, numbers, dots, underscores and hyphens in server name.'

# Onboarding key format is base64-encoded PKCS#8 X25519 private key DER,
# matching the key form displayed in Komodo's onboarding configuration examples.
KEY=$(openssl genpkey -algorithm X25519 -outform DER | openssl base64 -A)
[[ $KEY == MC4CAQAwBQYDK2VuBCIE* ]] || fail 'Unexpected generated onboarding key format.'

printf '\nCreate the onboarding key in Komodo BEFORE installing the service:\n'
printf '  1. Settings > Onboarding > New Onboarding Key\n'
printf '  2. Name: %s\n' "$SERVER"
printf '  3. Pre-Existing Key: %s\n' "$KEY"
printf '  4. Set an expiry long enough to finish onboarding.\n'
printf '  5. Leave Privileged and Create Builder off unless needed.\n'
printf '  6. Create the key; leave its template unselected for a new server.\n'
printf '\nThe key is a credential. Do not post it in issues, logs, or public repos.\n'
read -r -p 'Have you saved that key in Komodo? Type YES to continue: ' CONFIRM
[[ $CONFIRM == YES ]] || { printf 'Cancelled; nothing installed.\n'; exit 0; }

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf '\nDownloading official Komodo installer...\n'
curl -fsSL --retry 3 "$UPSTREAM" -o "$TMP"
# Upstream installer creates its config once and installs the systemd service.
# Supply credentials as process arguments briefly, consistent with upstream usage.
python3 "$TMP" --core-address "$CORE" --connect-as "$SERVER" --onboarding-key "$KEY"
[[ -f $CONFIG ]] || fail 'Installer did not create a Periphery config.'
chmod 600 "$CONFIG"
systemctl daemon-reload
systemctl enable --now periphery
if systemctl is-active --quiet periphery; then
  printf '\nPeriphery service active. Check Komodo > Servers for %s.\n' "$SERVER"
else
  printf '\nPeriphery did not start. Check: journalctl -u periphery -n 50 --no-pager\n' >&2
  exit 1
fi
printf 'Once onboarding succeeds, consider removing the onboarding_key setting from %s and restarting Periphery.\n' "$CONFIG"
