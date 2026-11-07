#!/usr/bin/env bash
# sweenlab | cleanup launcher 1.1.0
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
  'https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/aec2e6446c6eef4d9245eea5e837fb1821ee9966/scripts/sweenlab-cleanup/sweenlab-cleanup.py' \
  -o "$sweenlab_tmp/cleanup.py"
printf '%s  %s\n' '50a5b8e878d4f57b0e9dbb10c14e224dd4cb9d7d803534216ce84b022c5e00b9' "$sweenlab_tmp/cleanup.py" | sha256sum -c -
python3 "$sweenlab_tmp/cleanup.py" "$@"
