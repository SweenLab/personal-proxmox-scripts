#!/usr/bin/env bash
# sweenlab | cleanup launcher 2.0.0
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
  'https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/b6cd8cd5f84e1ac4dc05c1e931f95fd6dd1bda9e/scripts/sweenlab-cleanup/sweenlab-cleanup.py' \
  -o "$sweenlab_tmp/cleanup.py"
printf '%s  %s\n' '04841ea270ff7bf7a1c52d9100408b720891cd8c14ade686673dd52d3d7ef0f0' "$sweenlab_tmp/cleanup.py" | sha256sum -c -
python3 "$sweenlab_tmp/cleanup.py" "$@"
