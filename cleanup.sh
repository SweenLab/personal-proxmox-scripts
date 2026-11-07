#!/usr/bin/env bash
# sweenlab | cleanup launcher 2.1.0
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
  'https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/6d4ee015238e47cbe7335076b9bf69e3093b3599/scripts/sweenlab-cleanup/sweenlab-cleanup.py' \
  -o "$sweenlab_tmp/cleanup.py"
printf '%s  %s\n' '65422345e241d37a46a84406fadecd5f08876d4e719d39dd1cf3da4c121955a8' "$sweenlab_tmp/cleanup.py" | sha256sum -c -
python3 "$sweenlab_tmp/cleanup.py" "$@"
