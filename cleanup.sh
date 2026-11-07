#!/usr/bin/env bash
# sweenlab | cleanup launcher 1.1.1
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
  'https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/1406df6e217218cdadbce2ed904f0c5354c9b3f5/scripts/sweenlab-cleanup/sweenlab-cleanup.py' \
  -o "$sweenlab_tmp/cleanup.py"
printf '%s  %s\n' 'ca1402bdc2a94fed72e94563bc138066fa5a7aa58e191837dba481e72aaecdae' "$sweenlab_tmp/cleanup.py" | sha256sum -c -
python3 "$sweenlab_tmp/cleanup.py" "$@"
