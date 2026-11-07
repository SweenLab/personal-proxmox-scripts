#!/usr/bin/env bash
# sweenlab | cleanup launcher 2.1.1
# Default: inventory. Pass --apply for reviewed interactive cleanup.
set -euo pipefail
umask 077
if [[ $(id -u) != 0 ]]; then
  echo 'Run in the Proxmox root shell.' >&2
  exit 1
fi
sweenlab_tmp=$(mktemp -d)
trap 'rm -f -- "$sweenlab_tmp/cleanup.py"; rmdir -- "$sweenlab_tmp"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL \
  'https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/55bd78e1cabfde5a1482f441c8df718060be55e1/scripts/sweenlab-cleanup/sweenlab-cleanup.py' \
  -o "$sweenlab_tmp/cleanup.py"
printf '%s  %s\n' 'a67f2097463bc0506f557ae63c890fd70d47b028ec04164fea2694544915b6f5' "$sweenlab_tmp/cleanup.py" | sha256sum -c -
python3 "$sweenlab_tmp/cleanup.py" "$@"
