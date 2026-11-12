#!/usr/bin/env bash
# SweenLab Debian LXC Creation Wizard — MIT
# https://github.com/SweenLab/sweenlab-scripts
set -Eeuo pipefail
SCRIPT_VERSION=0.3.4
COMPLETED=()
CTID='' CREATED=0 LOG='' TMP='' UI_DIR='' UI_ACTION='' UI_VALUE=''
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() {
    local rc=$?
    [[ -z "$TMP" ]] || rm -f -- "$TMP"
    [[ -z "$UI_DIR" ]] || rm -rf -- "$UI_DIR"
    if (( rc != 0 )); then
        printf '\nStopped with status %s. Log: %s\n' "$rc" "${LOG:-not started}" >&2
        [[ -z "$CTID" ]] || printf 'Inspect CT %s and any partial storage before retrying. Nothing is automatically destroyed.\n' "$CTID" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Keep private logs/UI files at 077, but do not pass that mask to Proxmox.
# File::Path::make_path in Proxmox respects the inherited process umask.
proxmox_pct() (
    umask 022
    pct "$@"
)
number() { [[ "$1" =~ ^[1-9][0-9]{0,8}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 )); }
contains_line() { local wanted=$1 line; while IFS= read -r line; do [[ "$line" != "$wanted" ]] || return 0; done <<< "$2"; return 1; }
ui() {
    local kind=$1 title=$2 prompt=$3 seed=$4; shift 4
    printf '%s' "$seed" > "$UI_DIR/seed"
    python3 "$UI_DIR/ui.py" "$kind" "SweenLab $SCRIPT_VERSION | $title" "$prompt" "$UI_DIR/seed" "$UI_DIR/result" "$@" </dev/tty >/dev/tty
    IFS= read -r UI_ACTION < "$UI_DIR/result"
    UI_VALUE=$(sed '1d' "$UI_DIR/result")
    # Passwords are never passed as command arguments or retained on disk.
    : > "$UI_DIR/seed"; : > "$UI_DIR/result"
}
host_timezone() {
    local zone=''
    zone=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    if [[ -z "$zone" ]]; then
        zone=$(readlink -f /etc/localtime 2>/dev/null || true)
        zone=${zone#/usr/share/zoneinfo/}
    fi
    if [[ "$zone" =~ ^[a-zA-Z0-9_+/-]+$ && "$zone" != *..* && -f "/usr/share/zoneinfo/$zone" ]]; then
        printf '%s\n' "$zone"
    else
        printf 'UTC\n'
    fi
}
# Read configured host locale, not SSH client LANG/LC_* variables.
host_locale() {
    python3 - <<'HOST_LOCALE'
import pathlib, re
for name in ('/etc/locale.conf', '/etc/default/locale'):
    try:
        text = pathlib.Path(name).read_text()
    except OSError:
        continue
    match = re.search(r'^\s*LANG\s*=\s*[\"\']?([^\"\'\s#]+)', text, re.M)
    if match:
        value = match.group(1)
        if value.lower() in ('c.utf8', 'c.utf-8'):
            print('C.UTF-8'); break
        if re.fullmatch(r'[a-zA-Z]{2,3}_[a-zA-Z]{2}\.(?i:utf-?8)', value):
            print(value.split('.')[0] + '.UTF-8'); break
else:
    print('C.UTF-8')
HOST_LOCALE
}
list_storage() {
    local data
    data=$(pvesm status --content "$1") || die 'Could not read storage inventory.'
    awk 'NR>1 && $3=="active" {print $1}' <<< "$data"
}
list_downloaded_templates() {
    local data
    data=$(pveam list "$1") || die 'Could not read downloaded templates.'
    python3 -c '
import re, sys
store, arch = sys.argv[1:]
for line in sys.stdin:
    fields = line.split()
    if not fields:
        continue
    volume = fields[0]
    if re.fullmatch(re.escape(store) + r":vztmpl/debian-(12|13)-standard_[A-Za-z0-9.+~_-]+_" + re.escape(arch) + r"\.tar\.(zst|xz|gz)", volume):
        print(volume)
' "$1" "$2" <<< "$data"
}
validate_ip() {
    if [[ $1 == 4 && ! $2 =~ ^[^/]+/([0-9]|[12][0-9]|3[0-2])$ ]]; then return 1; fi
    python3 -c 'import ipaddress,sys; (ipaddress.IPv4Interface if sys.argv[1]=="4" else ipaddress.IPv6Interface)(sys.argv[2])' "$1" "$2" 2>/dev/null; }
validate_address() { python3 -c 'import ipaddress,sys; (ipaddress.IPv4Address if sys.argv[1]=="4" else ipaddress.IPv6Address)(sys.argv[2])' "$1" "$2" 2>/dev/null; }
validate_rate() { python3 -c 'import decimal,sys; n=decimal.Decimal(sys.argv[1]); sys.exit(0 if n.is_finite() and n>=0 and n<=8192 else 1)' "$1" 2>/dev/null; }
yes_word() { if [[ "$1" == 1 ]]; then printf Yes; else printf No; fi; }
# These probes are read-only and do not broaden host directory permissions.
check_extraction_access() {
    (( unpriv )) || return 0
    local parent
    for parent in /var /var/lib /var/lib/lxc; do
        if ! lxc-usernsexec -m u:0:100000:65536 -m g:0:100000:65536 -- test -x "$parent"; then
            printf 'Mapped container root (host UID 100000) cannot traverse %s.\n' "$parent" >&2
            command -v namei >/dev/null && namei -l "$parent" || true
            die 'Fix the host path/ACL problem before creation. No permissions were changed.'
        fi
    done
}
creation_diagnostics() {
    printf '\nProxmox failed before guest setup. Read-only path diagnostics follow.\n'
    command -v namei >/dev/null && namei -l "/var/lib/lxc/$CTID/rootfs" || true
    command -v findmnt >/dev/null && findmnt -T /var/lib/lxc -o TARGET,SOURCE,FSTYPE,OPTIONS || true
    printf 'Inspect the selected storage (%s), parent traversal permissions and ACLs.\n' "$root_store"
    printf 'Do not chmod recursively or switch to privileged mode as an automatic workaround.\n'
}
container_notes() {
    cat <<NOTES
<!-- Created by Sweenlab wizard $SCRIPT_VERSION -->
<table width="100%" height="280">
<thead><tr><td align="center" valign="middle">
<img src="https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/431677614bb80d7795f9e37ac7791b4a56f7900b/assets/branding/sweenlab-scripts-notes.png" alt="SWEENLAB SCRIPTS" width="280" height="112">
<br><br>
<a href="https://github.com/SweenLab/sweenlab-scripts">GitHub</a> · <a href="https://github.com/SweenLab/sweenlab-scripts/blob/main/docs/proxmox-debian-lxc-create.md">Guide</a> · <a href="https://github.com/SweenLab/sweenlab-scripts/releases">Releases</a>
</td></tr></thead>
</table>
NOTES
}
save_container_notes() {
    local notes
    notes=$(container_notes)
    proxmox_pct set "$CTID" --description "$notes" || return $?
    # Proxmox stores notes as config comments and restores a trailing newline.
    # Compare content through the API without treating that newline as data loss.
    pvesh get "/nodes/$(hostname -s)/lxc/$CTID/config" --output-format json |
        python3 -c 'import json, sys
actual = json.load(sys.stdin).get("description", "")
if actual.rstrip("\n") != sys.argv[1].rstrip("\n"):
    sys.exit("Proxmox did not retain the expected Summary notes; inspect the CT description.")
' "$notes"
}
make_plan() {
    cat <<PLAN
CONTAINER
  ID / name       $CTID / $hostname
  Tags            ${tags:-none}
  Type            $([[ "$unpriv" == 1 ]] && printf Unprivileged || printf Privileged)

RESOURCES
  CPU / memory    $cores cores / $memory MiB
  Swap            $swap MiB (0 disables swap)
  Root disk       $root_store · $disk GiB
  Timezone        $tz
  Template        ${template##*/}
  Template store  $template_store

NETWORK
  Bridge          $bridge
  IPv4            $ip ${gateway:+(gateway $gateway)}
  IPv6            $ip6 ${gateway6:+(gateway $gateway6)}
  VLAN / MTU      ${vlan:-untagged} / $mtu
  MAC / rate      ${mac:-automatic} / ${rate:-unlimited}
  DNS / search    ${dns:-inherit host} / ${search:-inherit host}

SOFTWARE & FEATURES
  Packages        ${packages_display:-none}
  Nesting/keyctl  $(yes_word "$nesting") / $(yes_word "$keyctl")
  FUSE / TUN      $(yes_word "$fuse") / $(yes_word "$tun")
  GPU devices     ${gpu_display:-none}
  Host boot       $(yes_word "$onboot")
  Tailscale login $([[ "$tailscale" == 1 && "$ts_up" == 1 ]] && printf Yes || printf No)
  Tailscale flags ${ts_flags_display:-not selected}

AUTOMATIC SETTINGS
  Root password required (hidden); locale $locale_name
  Verbose output  $(yes_word "$verbose")
  Full package upgrade enabled; firewall interface flag enabled
  CPU limit 0; CPU weight 100
  Summary notes: SWEENLAB SCRIPTS banner and links; saved and verified
  PVE default startup order/delays; deletion protection off
  Passed devices use guest UID/GID 0 and mode 0660

Create starts this new CT and installs the selected software.
Tailscale login may require browser authentication after installation.
PLAN
}
configure() {
    local bridge_limit=''
    ctid=$(pvesh get /cluster/nextid)
    hostname='' tags='' bridge='' ipmode='' ip='' gateway='' ip6mode='' ip6='' gateway6=''
    vlan='' mtu=${1:-} mac='' rate='' dns='' search='' cores=2 memory=1024 swap='' disk=10 root_store=''
    tz=$(host_timezone); unpriv=1 keyfile='' password='' password_confirm='' template_store='' template=''
    selected='' ts_up=1 ts_options=$'ssh\nignore-dns' nesting=1 keyctl=1 fuse=0 tun=0 gpu=0 gpu_selected='' onboot=1
    locale_name=$(host_locale) verbose=0
    docker=0 tailscale=0 packages_display='' gpu_display='' ts_flags_display=''
    local -a steps=(ctid hostname tags bridge mtu ipmode ip gateway ip6mode ip6 gateway6 cores memory swap disk root_store tz locale_name unpriv keyfile password password_confirm template_store template selected ts_up ts_options nesting keyctl fuse tun gpu gpu_selected onboot verbose review)
    local index=0 direction=1 key kind title prompt seed error='' names='' line old_password='' arch
    local -a options=()
    arch=$(dpkg --print-architecture)
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || die 'This wizard supports amd64 and arm64 hosts.'
    while (( index < ${#steps[@]} )); do
        key=${steps[$index]}
        case "$key" in
            ip|gateway) [[ "$ipmode" == static ]] || { index=$((index + direction)); continue; };;
            ip6|gateway6) [[ "$ip6mode" == static ]] || { index=$((index + direction)); continue; };;
            ts_up|ts_options|tun) (( tailscale )) || { index=$((index + direction)); continue; };;
            keyctl) (( unpriv )) || { index=$((index + direction)); continue; };;
            gpu|gpu_selected) [[ -n "$gpu_names" ]] || { index=$((index + direction)); continue; };;
        esac
        if [[ "$key" == gpu_selected ]] && (( gpu == 0 )); then index=$((index + direction)); continue; fi
        if [[ "$key" == ts_options ]] && (( ts_up == 0 )); then index=$((index + direction)); continue; fi
        options=(); kind=input; title='Container setup'; seed=${!key-}; prompt=''
        case "$key" in
            ctid) prompt='Container ID (unused across the cluster)' ;;
            hostname) prompt='Hostname (required; starts blank)' ;;
            tags) prompt=$'Tags separated by semicolons; leave blank for none.\n\nTags are case-sensitive: TEST and test are different tags.\nMatch the exact capitalization of your predefined Proxmox tags.' ;;
            bridge)
                kind=select; title='Network bridge'; prompt='Choose the bridge for this container.'
                names=$(configured_linux_bridges)
                while IFS= read -r line; do [[ -z "$line" ]] || options+=("$line" ''); done <<< "$names"
                if ((${#options[@]} == 0)); then kind=notice; prompt='No active configured Proxmox Linux bridge is available. Apply its network configuration, then restart the wizard.'; fi;;
            mtu)
                title='Container MTU'; prompt='Use the suggested MTU of 1450 bytes or enter a different value (1280 to 65535).'
                bridge_limit=$(bridge_mtu "/sys/class/net/$bridge")
                [[ -z "$bridge_limit" ]] || prompt+=" Selected bridge MTU: $bridge_limit bytes.";;
            ipmode) kind=select; title='IPv4'; prompt='How should IPv4 be configured?'; options=(dhcp 'DHCP' static 'Static address' manual 'No automatic IPv4');;
            ip) title='IPv4 address'; prompt='IPv4 address/prefix, for example 10.10.10.204/24';;
            gateway) title='IPv4 gateway'; prompt='IPv4 gateway; leave blank for none';;
            ip6mode) kind=select; title='IPv6'; prompt='How should IPv6 be configured?'; options=(manual 'No automatic IPv6' auto 'SLAAC' dhcp 'DHCPv6' static 'Static address');;
            ip6) title='IPv6 address'; prompt='IPv6 address/prefix';;
            gateway6) title='IPv6 gateway'; prompt='IPv6 gateway; leave blank for none';;
            cores) title='CPU cores'; prompt='Number of CPU cores';;
            memory) title='Memory'; prompt=$'Memory in MiB — enter the value below\n\n 1 GiB =  1024   5 GiB =  5120   9 GiB =  9216  13 GiB = 13312\n 2 GiB =  2048   6 GiB =  6144  10 GiB = 10240  14 GiB = 14336\n 3 GiB =  3072   7 GiB =  7168  11 GiB = 11264  15 GiB = 15360\n 4 GiB =  4096   8 GiB =  8192  12 GiB = 12288  16 GiB = 16384';;
            swap) title='Swap'; prompt=$'Swap allowance in MiB (required; no default)\n\nEnter 0 to disable swap.\n512 MiB = 0.5 GiB; 1024 MiB = 1 GiB; 2048 MiB = 2 GiB';;
            disk) title='Root disk'; prompt='Root disk size in GiB';;
            root_store|template_store)
                kind=select
                if [[ "$key" == root_store ]]; then title='Container storage'; prompt='Where should the container disk be stored?'; names=$(list_storage rootdir)
                else title='Template storage'; prompt='Where are your downloaded Debian templates stored?'; names=$(list_storage vztmpl); fi
                while IFS= read -r line; do [[ -z "$line" ]] || options+=("$line" ''); done <<< "$names"
                if ((${#options[@]} == 0)); then kind=notice; prompt='No active storage of the required content type is available. Configure storage in Proxmox before continuing.'; fi;;
            locale_name) title='Locale'; prompt='Detected from host locale configuration; edit if needed. C.UTF-8 is the fallback. Examples: en_US.UTF-8, en_GB.UTF-8.';;
            verbose) kind=yesno; title='Installation output'; prompt='Show verbose installation output? No shows concise progress; the full output is saved in the private log.';;
            tz) title='Timezone'; prompt='Prefilled from the Proxmox host. Edit if needed.';;
            unpriv) kind=yesno; title='Container type'; prompt='Create an unprivileged container?';;
            keyfile) title='SSH key'; prompt='Optional host path to an SSH public key file; leave blank to skip';;
            password) seed=''; kind=password; title='Root password'; prompt='Enter the required root console password (hidden).';;
            password_confirm) seed=''; kind=password; title='Confirm password'; prompt='Re-enter the root password (hidden).';;
            template)
                kind=select; title='Downloaded Debian template'; prompt='Choose a template already downloaded on this storage.'
                names=$(list_downloaded_templates "$template_store" "$arch")
                while IFS= read -r line; do [[ -z "$line" ]] || options+=("$line" "${line##*/}"); done <<< "$names"
                if ((${#options[@]} == 0)); then kind=notice; prompt='No downloaded Debian 12/13 template for this host architecture was found here. Back selects another storage; Abort lets you download a template in Proxmox first.'; fi;;
            selected)
                kind=check; title='Packages'; prompt='Choose packages or explicitly select None. Space toggles a choice. Deselect None before choosing individual packages. Compose includes Engine.'
                options=(__all__ 'Select all / clear all' __none__ 'None (no optional packages)' python3 'Python 3 + pip + venv' git 'Version control' curl 'Downloads' wget 'Downloads' tailscale 'VPN and optional guided sign-in'
                    docker 'Docker Engine + Buildx' compose 'Docker Compose + Engine' nano 'Text editor' jq 'JSON tools'
                    unzip 'ZIP extraction' iputils-ping 'Ping' openssh-server 'SSH server' sudo 'sudo; no users are created');;
            ts_up) kind=yesno; title='Tailscale sign-in'; prompt='Run tailscale up automatically after installation? The login link will appear for browser authentication.';;
            ts_options) kind=check; title='Tailscale options'; prompt='Choose options for tailscale up. SSH access still follows your tailnet policy.'; options=(ssh 'Enable Tailscale SSH' ignore-dns 'Keep existing DNS; ignore Tailscale DNS' accept-routes 'Accept advertised subnet routes');;
            nesting) kind=yesno; title='Nesting'; prompt='Enable nesting? Required for Docker; exposes additional host procfs/sysfs information.';;
            keyctl) kind=yesno; title='Keyctl'; prompt='Enable keyctl? Required for Docker in an unprivileged container.';;
            fuse) kind=yesno; title='FUSE'; prompt='Enable FUSE? It can interact with container freezing and backups.';;
            tun) kind=yesno; title='TUN passthrough'; prompt='Pass through /dev/net/tun? Required for Tailscale. Guest UID/GID are configured automatically.';;
            gpu) kind=yesno; title='GPU passthrough'; prompt='Pass through GPU device nodes? Host GPU drivers must already work.';;
            gpu_selected)
                kind=check; title='GPU devices'; prompt='Select the GPU devices to pass through. Guest UID/GID are 0.'
                while IFS= read -r line; do [[ -z "$line" ]] || options+=("$line" ''); done <<< "$gpu_names";;
            onboot) kind=yesno; title='Start at host boot'; prompt='Start this container when Proxmox boots? Startup order and delays use Proxmox defaults.';;
            review)
                kind=review; title='Review and create'; seed=''; prompt=$(make_plan);;
        esac
        [[ -z "$error" ]] || prompt=$'Please correct: '"$error"$'\n\n'"$prompt"
        case "$key" in
            ctid|hostname|bridge|mtu|ipmode|ip|ip6mode|ip6|cores|memory|swap|disk|root_store|tz|locale_name|password|password_confirm|template_store|template|selected|gpu_selected) title+=" (required)";;
        esac
        ui "$kind" "$title" "$prompt" "$seed" ${options[@]+"${options[@]}"}
        case "$UI_ACTION" in
            abort) printf 'Aborted. No container was created.\n'; exit 0;;
            back) direction=-1; index=$(( index > 0 ? index - 1 : 0 )); error=''; continue;;
            next) direction=1;;
            *) die 'Invalid dialog response.';;
        esac
        error=''
        if [[ "$key" == review ]]; then
            if (( docker && (!nesting || (unpriv && !keyctl)) )); then error='Docker requires nesting and keyctl in unprivileged mode. Use Back to change those settings.'; continue; fi
            if (( tailscale && !tun )); then error='Tailscale requires TUN. Use Back to enable it.'; continue; fi
            return 0
        fi
        old_password=$password
        printf -v "$key" '%s' "$UI_VALUE"
        case "$key" in
            ctid)
                if ! number "$ctid" 100 999999999; then error='Enter a valid CT ID.'
                elif ! pvesh get /cluster/nextid --vmid "$ctid" >/dev/null 2>&1; then error='That ID is already in use.'; fi
                CTID=$ctid;;
            hostname) [[ ${#hostname} -le 63 && "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || error='Hostname is required; use a single valid DNS label.';;
            tags) [[ -z "$tags" || "$tags" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*(\;[a-zA-Z0-9_][a-zA-Z0-9_.+-]*)*$ ]] || error='Use valid tags separated by semicolons.';;
            bridge|root_store|template_store|template) contains_line "${!key}" "$names" || error='Choose an item from the list.';;
            mtu)
                if ! number "$mtu" 1280 65535; then error='Enter a whole number from 1280 to 65535.'
                elif [[ -n "$bridge_limit" ]] && (( mtu > bridge_limit )); then error="MTU cannot exceed the selected bridge MTU ($bridge_limit bytes)."; fi;;
            ipmode) [[ $ipmode == dhcp || $ipmode == static || $ipmode == manual ]] || error='Select an IPv4 mode.'; if [[ $ipmode == static && ( $ip == dhcp || $ip == manual ) ]]; then ip=''; fi;;
            ip6mode) [[ $ip6mode == manual || $ip6mode == auto || $ip6mode == dhcp || $ip6mode == static ]] || error='Select an IPv6 mode.'; if [[ $ip6mode == static && ( $ip6 == dhcp || $ip6 == manual || $ip6 == auto ) ]]; then ip6=''; fi;;
            locale_name) [[ $locale_name == C.UTF-8 || $locale_name =~ ^[a-zA-Z]{2,3}_[a-zA-Z]{2}\.UTF-8$ ]] || error='Enter a UTF-8 locale such as en_US.UTF-8.';;
            ip) validate_ip 4 "$ip" || error='CIDR is required, for example 10.10.10.204/24 (prefix 0-32).';;
            gateway) [[ -z "$gateway" ]] || validate_address 4 "$gateway" || error='Invalid IPv4 gateway.';;
            ip6) validate_ip 6 "$ip6" || error='Enter IPv6 with a prefix length.';;
            gateway6) [[ -z "$gateway6" ]] || validate_address 6 "$gateway6" || error='Invalid IPv6 gateway.';;
            cores) number "$cores" 1 "$(nproc)" || error='Enter a valid core count for this host.';;
            memory) number "$memory" 256 1048576 || error='Memory must be at least 256 MiB.';;
            swap) [[ $swap == 0 ]] || number "$swap" 1 1048576 || error='Enter swap in whole MiB from 0 to 1048576; 0 disables swap.';;
            disk) number "$disk" 2 1048576 || error='Disk must be at least 2 GiB.';;
            tz) [[ "$tz" != *..* && "$tz" =~ ^[a-zA-Z0-9_+/-]+$ && -f "/usr/share/zoneinfo/$tz" ]] || error='Unknown timezone.';;
            keyfile) [[ -z "$keyfile" || ( -f "$keyfile" && -r "$keyfile" ) ]] || error='SSH key file is unreadable.';;
            password) [[ -n "$password" && "$password" != *$'\n'* && "$password" != *$'\r'* ]] || error='A root password is required.'; [[ "$password" == "$old_password" ]] || password_confirm='';;
            password_confirm) [[ -n "$password_confirm" && "$password_confirm" == "$password" ]] || error='Passwords must match.';;
            selected)
                if [[ -z $selected ]]; then error='Choose at least one package or explicitly select None.'; continue; fi
                if contains_line __none__ "$selected" && [[ $selected != __none__ ]]; then error='None cannot be combined with packages.'; continue; fi
                docker=0; tailscale=0; packages_display=${selected//$'\n'/, }
                [[ $selected != __none__ ]] || packages_display=None
                contains_line docker "$selected" && docker=1
                contains_line compose "$selected" && docker=1
                contains_line tailscale "$selected" && tailscale=1
                tun=$tailscale;;
            ts_options) ts_flags_display=${ts_options//$'\n'/, };;
            nesting) (( docker == 0 || nesting == 1 )) || error='Docker was selected and requires nesting.';;
            keyctl) (( docker == 0 || keyctl == 1 )) || error='Unprivileged Docker requires keyctl.';;
            tun) if (( tun )); then [[ -c /dev/net/tun ]] || error='The host TUN device is missing.'; elif (( tailscale )); then error='Tailscale requires TUN.'; fi;;
            gpu_selected)
                [[ -n $gpu_selected ]] || error='Select at least one GPU device, or use Back to disable GPU passthrough.'
                gpu_display=${gpu_selected//$'\n'/, }
                while IFS= read -r line; do [[ -z "$line" ]] || contains_line "$line" "$gpu_names" || error='Unknown GPU device.'; done <<< "$gpu_selected";;
        esac
        [[ -z "$error" ]] || continue
        # Clear only values made irrelevant by an earlier choice.
        [[ "$ipmode" == static ]] || { ip=$ipmode; gateway=''; }
        [[ "$ip6mode" == static ]] || { ip6=$ip6mode; gateway6=''; }
        (( unpriv )) || keyctl=0
        (( gpu )) || { gpu_selected=''; gpu_display=''; }
        index=$((index + 1))
    done
}
progress() {
    local state=$1 message=$2 orange='' green='' neutral='' reset=''
    if [[ ${PROGRESS_COLOR:-0} == 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
        orange=$'\033[38;5;208m'; green=$'\033[38;5;114m'; neutral=$'\033[38;5;252m'; reset=$'\033[0m'
    fi
    if [[ $state == OK || $state == CHECK ]]; then
        [[ $state != OK ]] || COMPLETED+=("$message")
        printf '  %s✅%s %s%s\n' "$green" "$neutral" "$message" "$reset"
    else printf '  %s%s%s\n' "$orange" "$message" "$reset"; fi
}
install_stage() {
    local label=$1 rc=0 output
    shift
    progress RUN "$label"
    if (( verbose )); then
        if [[ ${PROGRESS_COLOR:-0} == 1 && -z ${NO_COLOR:-} ]]; then printf '\033[38;5;252m'; fi
        "$@" || rc=$?
        if [[ ${PROGRESS_COLOR:-0} == 1 && -z ${NO_COLOR:-} ]]; then printf '\033[0m'; fi
    else
        output=$(mktemp "$UI_DIR/stage.XXXXXX") || return $?
        "$@" >"$output" 2>&1 || rc=$?
        cat "$output" >> "$LOG"
        if (( rc )); then tail -n 30 "$output"; fi
        rm -f -- "$output"
    fi
    (( rc == 0 )) || return "$rc"
    progress OK "$label"
}
persist_guest_mtu() {
    # Keep the MTU outside /etc/network/interfaces, which Proxmox can regenerate.
    proxmox_pct exec "$CTID" -- sh -eu -c '
        test -x /sbin/ifup
        hook=/etc/network/if-up.d/sweenlab-mtu
        temp=$(mktemp "${hook}.XXXXXX")
        trap "rm -f -- \"\$temp\"" EXIT
        cat > "$temp"
        chmod 0755 "$temp"
        mv -f "$temp" "$hook"
    ' <<EOF
#!/bin/sh
[ "\$IFACE" = eth0 ] || exit 0
exec /sbin/ip link set dev eth0 mtu $mtu
EOF
}
ensure_live_mtu() {
    local live_mtu
    live_mtu=$(proxmox_pct exec "$CTID" -- cat /sys/class/net/eth0/mtu) || return $?
    [[ "$live_mtu" != "$mtu" ]] || return 0
    printf 'CT %s eth0 came up at MTU %s; applying %s.\n' "$CTID" "$live_mtu" "$mtu"
    proxmox_pct exec "$CTID" -- ip link set dev eth0 mtu "$mtu" || return $?
    live_mtu=$(proxmox_pct exec "$CTID" -- cat /sys/class/net/eth0/mtu) || return $?
    if [[ "$live_mtu" != "$mtu" ]]; then
        printf 'CT %s eth0 MTU is %s; expected %s.\n' "$CTID" "$live_mtu" "$mtu" >&2
        return 1
    fi
}
execute_plan() {
    COMPLETED=()
    PROGRESS_COLOR=0
    [[ ! -t 1 ]] || PROGRESS_COLOR=1
    umask 077
    mkdir -p /var/log/sweenlab-debian-lxc
    LOG="/var/log/sweenlab-debian-lxc/$(date +%Y%m%d-%H%M%S)-$$.log"
    exec > >(tee -a "$LOG") 2>&1
    make_plan >> "$LOG"
    printf "\n  🟠 SweenLab · Debian LXC %s\n  🖥️  CT %s · %s\n\n" "$SCRIPT_VERSION" "$CTID" "$hostname"
    progress RUN "🔎 Check host and selected settings"
    check_extraction_access
    pvesh get /cluster/nextid --vmid "$CTID" >/dev/null
    [[ -d "/sys/class/net/$bridge/bridge" ]] || die 'The selected Linux bridge is no longer available.'
    local current_templates
    current_templates=$(list_downloaded_templates "$template_store" "$(dpkg --print-architecture)")
    contains_line "$template" "$current_templates" || die 'The selected template is no longer present.'
    progress OK "🔎 Host and template checks passed"
    local net="name=eth0,bridge=$bridge,ip=$ip,ip6=$ip6,firewall=1,mtu=$mtu"
    [[ -z "$gateway" ]] || net+=",gw=$gateway"
    [[ -z "$gateway6" ]] || net+=",gw6=$gateway6"
    [[ -z "$vlan" ]] || net+=",tag=$vlan"
    [[ -z "$mac" ]] || net+=",hwaddr=$mac"
    [[ -z "$rate" ]] || net+=",rate=$rate"
    local features="nesting=$nesting,fuse=$fuse"
    (( unpriv == 0 )) || features+=",keyctl=$keyctl"
    local -a args=("$CTID" "$template" --ostype debian --arch "$(dpkg --print-architecture)" --hostname "$hostname"
        --cores "$cores" --cpulimit 0 --cpuunits 100 --memory "$memory" --swap "$swap" --rootfs "$root_store:$disk"
        --unprivileged "$unpriv" --features "$features" --net0 "$net" --onboot "$onboot" --protection 0
        --description "$(container_notes)")
    [[ -z "$tags" ]] || args+=(--tags "$tags")
    [[ -z "$dns" ]] || args+=(--nameserver "$dns")
    [[ -z "$search" ]] || args+=(--searchdomain "$search")
    [[ -z "$keyfile" ]] || args+=(--ssh-public-keys "$keyfile")
    local device_index=0 device item pct_help
    local -a devices=() tools=()
    (( tun == 0 )) || devices+=(/dev/net/tun)
    if (( gpu )); then
        while IFS= read -r item; do [[ -z "$item" ]] || devices+=("$item"); done <<< "$gpu_selected"
    fi
    if ((${#devices[@]})); then
        pct_help=$(proxmox_pct help create 2>&1)
        [[ "$pct_help" == *'--dev[n]'* || "$pct_help" == *'--dev0'* ]] || die 'PVE device passthrough is unavailable on this host version.'
        for device in ${devices[@]+"${devices[@]}"}; do
            [[ -c "$device" ]] || die "Device is no longer available: $device"
            args+=("--dev$device_index" "path=$device,gid=0,uid=0,mode=0660")
            device_index=$((device_index + 1))
        done
    fi
    local rc=0
    install_stage "📦 Create container and extract Debian" proxmox_pct create "${args[@]}" || rc=$?
    if (( rc )); then creation_diagnostics; die "Container creation failed (status $rc). Inspect CT $CTID before retrying; no automatic cleanup was performed."; fi
    CREATED=1
    install_stage "🚀 Start container" proxmox_pct start "$CTID"
    local ready=0 attempt
    for attempt in {1..60}; do
        if proxmox_pct exec "$CTID" -- test -d /run/systemd/system >/dev/null 2>&1; then ready=1; break; fi
        sleep 2
    done
    (( ready )) || die 'Container was not ready within 120 seconds.'
    progress OK '🟢 Container is ready'
    printf 'root:%s\n' "$password" | proxmox_pct exec "$CTID" -- chpasswd
    progress OK "🔐 Required root password configured"
    unset password password_confirm
    TMP=$(mktemp)
    write_guest_installer > "$TMP"
    bash -n "$TMP"; sha256sum "$TMP" >> "$LOG"
    install_stage "🧰 Prepare embedded installer" proxmox_pct push "$CTID" "$TMP" /root/sweenlab-debian-tools.sh --perms 0700
    while IFS= read -r item; do [[ -z "$item" || $item == __none__ ]] || tools+=("$item"); done <<< "$selected"
    install_stage "🔧 Save container eth0 MTU for future starts" persist_guest_mtu
    install_stage "🔎 Verify container eth0 MTU is $mtu" ensure_live_mtu ||
        die "Could not verify MTU $mtu on CT $CTID eth0. Debian updates have not started."
    install_stage "🌐 Configure locale, fully update Debian and install tools" proxmox_pct exec "$CTID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE= bash /root/sweenlab-debian-tools.sh --timezone "$tz" --locale "$locale_name" --upgrade 1 ${tools[@]+"${tools[@]}"}
    progress OK "Locale $locale_name configured and UTF-8 verified"
    progress OK "Timezone $tz configured"
    progress OK "Debian full upgrade completed"
    for item in ${tools[@]+"${tools[@]}"}; do progress OK "Selected tool installed: $item"; done
    install_stage "📝 Save and verify Summary notes" save_container_notes
    local login_rc=0
    if (( tailscale && ts_up )); then
        local ssh=false accept_dns=true routes=false
        contains_line ssh "$ts_options" && ssh=true
        contains_line ignore-dns "$ts_options" && accept_dns=false
        contains_line accept-routes "$ts_options" && routes=true
        printf '\nStarting Tailscale sign-in. Open or copy the login link in your browser.\n'
        # Login URLs are sent only to the terminal, not the host run log.
        proxmox_pct exec "$CTID" -- tailscale up --timeout=120s "--ssh=$ssh" "--accept-dns=$accept_dns" "--accept-routes=$routes" --qr=false >/dev/tty 2>/dev/tty || login_rc=$?
        if (( login_rc )); then
            printf '[ATTENTION] Tailscale sign-in is incomplete; CT and packages are preserved. Retry:\n'
            printf 'pct exec %s -- tailscale up --ssh=%s --accept-dns=%s --accept-routes=%s --qr=false\n' "$CTID" "$ssh" "$accept_dns" "$routes"
        else
            progress OK 'Tailscale sign-in completed'
        fi
    fi
    if (( verbose )); then
        printf '\n  ── Completed · CT %s (%s) ──\n' "$CTID" "$hostname"
        for item in "${COMPLETED[@]}"; do progress CHECK "$item"; done
        (( login_rc == 0 )) || printf '  ⚠ Tailscale sign-in is incomplete.\n'
    fi
    printf '\n✅ CT %s created and selected packages installed. Log: %s\n' "$CTID" "$LOG"
    proxmox_pct exec "$CTID" -- hostname -I
    printf 'Enter the container: pct enter %s\n' "$CTID"
}
main() {
    local mtu_override=1450
    case ${1:-} in
        --help)
            printf 'Self-contained SweenLab wizard %s. Run as root on Proxmox VE.\n' "$SCRIPT_VERSION"
            printf 'Usage: bash installer.sh [--mtu BYTES] (default MTU: 1450 bytes).\n'
            return;;
        --mtu)
            (( $# == 2 )) && number "$2" 1280 65535 || die 'Use --mtu with a whole number from 1280 to 65535.'
            mtu_override=$2
            shift 2;;
    esac
    (($# == 0)) || die 'Unknown argument.'
    (( EUID == 0 )) || die 'Run on the Proxmox host as root.'
    [[ -d /etc/pve ]] || die 'A Proxmox VE host is required.'
    local cmd
    for cmd in pct pvesh pvesm pveam python3 flock sha256sum lxc-usernsexec; do command -v "$cmd" >/dev/null || die "Required command is missing: $cmd"; done
    python3 -c 'import curses' || die 'Python terminal support (curses) is required.'
    exec </dev/tty
    exec 9>/run/lock/sweenlab-debian-lxc.lock
    flock -n 9 || die 'Another SweenLab wizard is running.'
    umask 077
    UI_DIR=$(mktemp -d)
    write_ui > "$UI_DIR/ui.py"
    gpu_names=''
    local item
    for item in /dev/dri/card* /dev/dri/renderD*; do [[ ! -c "$item" ]] || gpu_names+="$item"$'\n'; done
    configure "$mtu_override"
    execute_plan
}

bridge_mtu() {
    local value
    if { IFS= read -r value < "$1/mtu"; } 2>/dev/null && number "$value" 68 65535; then
        printf '%s\n' "$value"
    fi
}

configured_linux_bridges() {
    local network_json
    network_json=$(pvesh get "/nodes/$(hostname -s)/network" --type bridge --output-format json) ||
        die 'Could not read Proxmox network configuration.'
    python3 -c '
import json, re, sys
networks = json.load(sys.stdin)
if not isinstance(networks, list):
    raise SystemExit("Invalid Proxmox network response.")
bridges = set()
for entry in networks:
    name = entry.get("iface", "")
    if entry.get("type") != "bridge" or entry.get("active") not in (1, True):
        continue
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", name):
        continue
    if re.fullmatch(r"docker[0-9]+|br-[0-9a-fA-F]+|fwbr[0-9]+i[0-9]+", name):
        continue
    bridges.add(name)
for name in sorted(bridges, key=lambda value: [int(part) if part.isdigit() else part for part in re.split(r"([0-9]+)", value)]):
    print(name)
' <<< "$network_json"
}


write_ui() {
    cat <<'SWEENLAB_UI'
import curses
import os
import re
import sys
import textwrap


def button_set(kind):
    if kind == 'yesno':
        return [('Back', 'back', ''), ('Yes', 'next', '1'), ('No', 'next', '0'), ('Abort', 'abort', '')]
    if kind == 'notice':
        return [('Back', 'back', ''), ('Abort', 'abort', '')]
    return [('Back', 'back', ''), ('Create' if kind == 'review' else 'Next', 'next', None), ('Abort', 'abort', '')]


def review_rows(prompt, width):
    rows = []
    for raw in prompt.splitlines():
        line = raw.strip()
        if not line:
            rows.append(('', '', 'space'))
        elif line.isupper():
            rows.append((line, '', 'section'))
        else:
            fields = re.split(r'\s{2,}', line, maxsplit=1)
            if len(fields) == 2:
                label, value = fields
                for idx, part in enumerate(textwrap.wrap(value, max(12, width - 21)) or ['']):
                    rows.append((label if idx == 0 else '', part, 'value'))
            else:
                rows.extend((part, '', 'note') for part in textwrap.wrap(line, width))
    return rows


def run(screen, kind, title, prompt, seed, options):
    curses.curs_set(0)
    screen.keypad(True)
    accent = success = highlight = body = field = 0
    try:
        if curses.has_colors() and not os.environ.get('NO_COLOR'):
            curses.start_color()
            curses.use_default_colors()
            curses.init_pair(1, 208 if curses.COLORS >= 256 else curses.COLOR_YELLOW, -1)
            curses.init_pair(2, 114 if curses.COLORS >= 256 else curses.COLOR_GREEN, -1)
            curses.init_pair(3, curses.COLOR_BLACK, 114 if curses.COLORS >= 256 else curses.COLOR_GREEN)
            curses.init_pair(4, 252 if curses.COLORS >= 256 else curses.COLOR_WHITE, -1)
            curses.init_pair(5, 252 if curses.COLORS >= 256 else curses.COLOR_WHITE, 236 if curses.COLORS >= 256 else curses.COLOR_BLACK)
            accent, success, highlight, body, field = (curses.color_pair(i) for i in (1, 2, 3, 4, 5))
            screen.bkgd(' ', body)
    except curses.error:
        pass
    text = '' if kind == 'password' else seed
    cursor = len(text)
    tags = [tag for tag, _ in options]
    selected = set(seed.splitlines())
    choice = seed if seed in tags else ''
    selection_error = ''
    row = tags.index(seed) if seed in tags else 0
    scroll = 0
    buttons = button_set(kind)
    button = 1 if kind != 'notice' else 0
    if kind == 'yesno' and seed == '0':
        button = 2
    focus = 'buttons' if kind in ('yesno', 'review', 'notice') else 'content'
    while True:
        screen.erase()
        h, w = screen.getmaxyx()
        if h < 24 or w < 80:
            screen.addnstr(0, 0, 'Enlarge this terminal to at least 80 columns x 24 rows. Esc aborts.', max(1, w - 1))
            screen.refresh()
            if screen.getch() == 27:
                return 'abort', ''
            continue
        width = min(w - 4, 100)
        left = (w - width) // 2
        top = 1
        height = h - 2
        box = screen.derwin(height, width, top, left)
        box.bkgd(' ', body)
        box.box()
        def write(y, x, value, attr=0):
            if 0 <= y < height - 1:
                if x == 3:
                    value = value.strip()
                    x = max(2, (width - min(len(value), width - 6)) // 2)
                box.addnstr(y, x, value, max(0, width - x - 2), attr)
        write(0, max(2, (width - len(title) - 2) // 2), ' ' + title + ' ', curses.A_BOLD | accent)
        lines = []
        for paragraph in prompt.splitlines():
            lines.extend(textwrap.wrap(paragraph, width - 6) or [''])
        if kind == 'review':
            table_width = min(width - 10, 76)
            table_x = (width - table_width) // 2
            rows = review_rows(prompt, table_width)
            limit = height - 7
            scroll = max(0, min(scroll, max(0, len(rows) - limit)))
            for idx, (label, value, role) in enumerate(rows[scroll:scroll + limit]):
                y = 2 + idx
                if role == 'section':
                    box.addnstr(y, table_x, label + ' ' + '─' * max(0, table_width - len(label) - 1), table_width, accent | curses.A_BOLD)
                elif role == 'value':
                    box.addnstr(y, table_x, label, 19, success)
                    box.addnstr(y, table_x + 21, value, table_width - 21, body)
                else:
                    box.addnstr(y, table_x, label, table_width, body)
        else:
            block_height = min(len(lines), 8) + 1 + (min(len(options), max(1, height - min(len(lines), 8) - 8)) if kind in ('menu', 'check', 'select') else 1)
            prompt_y = max(2, 2 + (height - 7 - block_height) // 2)
            required = '(required)' in title
            for idx, line in enumerate(lines[:8]):
                conversions = re.findall(r'(\d+)\s+GiB\s*=\s*(\d+)', line)
                if len(conversions) == 4:
                    # Keep labels neutral; emphasize only the values to enter.
                    cell_width, gap = 14, 3
                    grid_x = (width - (4 * cell_width + 3 * gap)) // 2
                    for column, (gib, mib) in enumerate(conversions):
                        x = grid_x + column * (cell_width + gap)
                        box.addnstr(prompt_y + idx, x, f'{gib:>2} GiB = ', 9, body)
                        box.addnstr(prompt_y + idx, x + 9, f'{mib:>5}', 5, success | curses.A_BOLD)
                        if column < 3:
                            box.addnstr(prompt_y + idx, x + cell_width, ' │ ', gap, body | curses.A_DIM)
                else:
                    style = (body | curses.A_BOLD) if line.startswith('Memory in MiB') else success | (curses.A_BOLD if required else 0)
                    write(prompt_y + idx, 3, line, style)
            content_y = prompt_y + 1 + min(len(lines), 8)
            if kind in ('input', 'password'):
                shown = '*' * len(text) if kind == 'password' else text
                field_width = min(48, width - 12)
                offset = max(0, cursor - field_width + 1)
                field_left = (width - field_width - 4) // 2
                field_x = field_left + 2
                box.addnstr(content_y, field_left, '[ ' + ' ' * field_width + ' ]', field_width + 4, field)
                box.addnstr(content_y, field_x, shown[offset:offset + field_width], field_width, field | (curses.A_BOLD if required else 0))
            elif kind in ('menu', 'check', 'select'):
                visible = max(1, height - content_y - 5)
                start = max(0, min(row - visible + 1, max(0, len(options) - visible)))
                for idx, (tag, label) in enumerate(options[start:start + visible], start):
                    checked = (set(tags) - {'__all__', '__none__'} <= selected) if tag == '__all__' else tag in selected
                    mark = ('[x] ' if checked else '[ ] ') if kind == 'check' else (('(x) ' if tag == choice else '( ) ') if kind == 'select' else '')
                    label = (label or tag) if kind in ('menu', 'select') or tag in ('__all__', '__none__') else (tag if not label else tag + '  ' + label)
                    write(content_y + idx - start, 3, mark + label,
                          ((highlight or curses.A_REVERSE) if idx == row and focus == 'content' else success) | (curses.A_BOLD if required else 0))
        labels = ['< ' + value[0] + ' >' for value in buttons]
        total = sum(map(len, labels)) + 4 * (len(labels) - 1)
        x = max(2, (width - total) // 2)
        for idx, label in enumerate(labels):
            write(height - 4, x, label, (highlight or curses.A_REVERSE) | curses.A_BOLD if idx == button and focus == 'buttons' else accent)
            x += len(label) + 4
        hint = 'Up/Down: field/buttons | Left/Right: edit/choose | Enter: confirm | Esc: abort'
        if kind == 'check':
            hint = 'Arrows: navigate | Right: buttons | Space: select | Enter: next | Esc: abort'
        if kind == 'select':
            hint = 'Up/Down: highlight | Space/Enter: select → Next | Tab: buttons | Esc: abort'
        if selection_error:
            write(height - 3, 3, selection_error, accent | curses.A_BOLD)
        if kind == 'review':
            hint = f'{scroll + 1}-{min(scroll + limit, len(rows))}/{len(rows)} | Up/Down: scroll | Left/Right: buttons | Esc: abort'
        write(height - 2, 3, hint, curses.A_DIM)
        curses.curs_set(1 if focus == 'content' and kind in ('input', 'password') else 0)
        if focus == 'content' and kind in ('input', 'password'):
            box.move(content_y, field_x + min(cursor - offset, field_width - 1))
        box.refresh()
        key = screen.get_wch()
        if key == '\x1b' or key == '\x03':
            return 'abort', ''
        if key == curses.KEY_RESIZE:
            continue
        if key in ('\t', curses.KEY_BTAB):
            if focus == 'content':
                focus = 'buttons'
                button = len(buttons) - 1 if key == curses.KEY_BTAB else 0
            else:
                step = -1 if key == curses.KEY_BTAB else 1
                target = button + step
                if target < 0 or target >= len(buttons):
                    if kind in ('input', 'password', 'menu', 'check', 'select'):
                        focus = 'content'
                    else:
                        button = target % len(buttons)
                else:
                    button = target
            continue
        if kind == 'review' and key in (curses.KEY_UP, curses.KEY_DOWN, curses.KEY_NPAGE, curses.KEY_PPAGE):
            scroll += {curses.KEY_UP: -1, curses.KEY_DOWN: 1, curses.KEY_NPAGE: 8, curses.KEY_PPAGE: -8}[key]
            continue
        if kind in ('input', 'password', 'menu', 'check', 'select'):
            if focus == 'buttons' and key == curses.KEY_UP:
                focus = 'content'
                continue
            if focus == 'content' and kind in ('input', 'password') and key in (curses.KEY_UP, curses.KEY_DOWN):
                focus, button = 'buttons', 1
                continue
            if focus == 'content' and kind in ('menu', 'check', 'select') and key == curses.KEY_RIGHT:
                focus, button = 'buttons', 1
                continue
        if kind == 'yesno' and key in (curses.KEY_UP, curses.KEY_DOWN):
            button = (button + (1 if key == curses.KEY_DOWN else -1)) % len(buttons)
            continue
        if focus == 'buttons' and key in (curses.KEY_LEFT, curses.KEY_RIGHT):
            button = (button + (1 if key == curses.KEY_RIGHT else -1)) % len(buttons)
            continue
        if focus == 'content':
            if kind in ('menu', 'check', 'select'):
                if key in (curses.KEY_UP, curses.KEY_DOWN):
                    target = row + (1 if key == curses.KEY_DOWN else -1)
                    if target < 0 or target >= len(options):
                        focus, button = 'buttons', 1
                    else:
                        row = target
                    continue
                if kind == 'select' and key in (' ', '\n', '\r', curses.KEY_ENTER):
                    choice = tags[row] if tags else ''
                    selection_error = ''
                    if choice:
                        focus, button = 'buttons', 1
                    continue
                if key == ' ' and kind == 'check' and options:
                    selection_error = ''
                    tag = options[row][0]
                    if tag == '__all__':
                        all_tags = set(tags) - {'__all__', '__none__'}
                        selected.discard('__none__')
                        if all_tags <= selected:
                            selected -= all_tags
                        else:
                            selected |= all_tags
                            focus, button = 'buttons', 1
                    elif tag == '__none__':
                        selected = set() if '__none__' in selected else {'__none__'}
                    elif '__none__' not in selected:
                        selected.symmetric_difference_update([tag])
                    continue
            elif kind in ('input', 'password'):
                if key in (curses.KEY_BACKSPACE, '\x7f', '\b'):
                    if cursor:
                        text = text[:cursor - 1] + text[cursor:]
                        cursor -= 1
                    continue
                if key == curses.KEY_DC:
                    text = text[:cursor] + text[cursor + 1:]
                    continue
                if key in (curses.KEY_LEFT, curses.KEY_RIGHT, curses.KEY_HOME, curses.KEY_END):
                    cursor = {curses.KEY_LEFT: max(0, cursor - 1), curses.KEY_RIGHT: min(len(text), cursor + 1),
                              curses.KEY_HOME: 0, curses.KEY_END: len(text)}[key]
                    continue
                if key == '\x15':
                    text, cursor = '', 0
                    continue
                if isinstance(key, str) and key.isprintable():
                    text = text[:cursor] + key + text[cursor:]
                    cursor += 1
                    continue
        if key in ('\n', '\r', curses.KEY_ENTER):
            _, action, value = buttons[button if focus == 'buttons' else 1]
            if action != 'next' or value is not None:
                return action, value or ''
            if kind in ('input', 'password'):
                return action, text
            if kind == 'select':
                if choice not in tags:
                    selection_error = 'Select one option before continuing.'
                    focus = 'content'
                    continue
                return action, choice
            if kind == 'menu':
                return action, tags[row] if tags else ''
            if kind == 'check':
                if '(required)' in title and not any(tag in selected for tag in tags if tag != '__all__'):
                    selection_error = 'Select at least one option before continuing.'
                    focus = 'content'
                    continue
                return action, '\n'.join(tag for tag in tags if tag in selected and tag != '__all__')
            return action, ''


def main():
    kind, title, prompt, seed_path, result_path, *raw = sys.argv[1:]
    options = list(zip(raw[::2], raw[1::2]))
    with open(seed_path) as handle:
        seed = handle.read()
    try:
        action, value = curses.wrapper(run, kind, title, prompt, seed, options)
    except KeyboardInterrupt:
        action, value = 'abort', ''
    fd = os.open(result_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as handle:
        handle.write(action + '\n' + value)


if __name__ == '__main__':
    main()
SWEENLAB_UI
}

# Keep guest setup in this file so the launcher never fetches another script.
write_guest_installer() {
    cat <<'SWEENLAB_GUEST_INSTALLER'
#!/usr/bin/env bash
# SweenLab Debian tools installer — MIT
# Run ONLY inside the intended Debian 12/13 LXC, never on the Proxmox host.
set -Eeuo pipefail
TEMP_DIR=''
trap '[[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"' EXIT
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
main() {
    [[ ${1:-} != --help ]] || { printf 'Inside Debian LXC: bash %s --timezone America/New_York --upgrade 0 git curl compose\n' "$0"; return; }
    (( EUID == 0 )) || fail 'Root is required.'
    [[ ! -d /etc/pve ]] || fail 'Refusing to install on a Proxmox host.'
    [[ $(systemd-detect-virt --container) == lxc ]] || fail 'Run only inside an LXC container.'
    # Debian owns this configuration file.
    . /etc/os-release
    [[ "$ID" == debian && "$VERSION_ID" =~ ^(12|13)$ ]] || fail 'Debian 12 or 13 required.'
    local tz=America/New_York locale_name=en_US.UTF-8 upgrade=0 docker=0 compose=0 tailscale=0 item
    local -a packages=(locales tzdata) tools=()
    while (($#)); do
        case "$1" in
            --timezone|--locale|--upgrade)
                (($# >= 2)) || fail "Missing value for $1"
                case "$1" in --timezone) tz=$2;; --locale) locale_name=$2;; --upgrade) upgrade=$2;; esac
                shift 2;;
            git|curl|wget|nano|jq|unzip|iputils-ping|openssh-server|sudo)
                packages+=("$1"); tools+=("$1"); shift;;
            python3) packages+=(python3 python3-pip python3-venv); tools+=(python3 python3-pip python3-venv); shift;;
            docker) docker=1; shift;;
            compose) docker=1; compose=1; shift;;
            tailscale) tailscale=1; shift;;
            *) fail "Unknown option/tool: $1";;
        esac
    done
    [[ "$upgrade" == 0 || "$upgrade" == 1 ]] || fail 'Upgrade must be 0 or 1.'
    [[ "$tz" != *..* && "$tz" =~ ^[a-zA-Z0-9_+/-]+$ && -f "/usr/share/zoneinfo/$tz" ]] || fail 'Invalid timezone.'
    if (( docker )); then
        for item in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
            if [[ $(dpkg-query -W -f='${Status}' "$item" 2>/dev/null || true) == 'install ok installed' ]]; then
                fail "Conflicting package $item is installed. Review removal manually; no automatic replacement."
            fi
        done
    fi
    if (( tailscale )); then [[ -c /dev/net/tun ]] || fail 'TUN device is missing.'; fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Retries=3 update
    if (( docker || tailscale )); then packages+=(ca-certificates curl gnupg); fi
    apt-get install -y --no-install-recommends "${packages[@]}"
    [[ $locale_name == C.UTF-8 || $locale_name =~ ^[a-zA-Z]{2,3}_[a-zA-Z]{2}\.UTF-8$ ]] || fail 'Invalid UTF-8 locale.'
    if [[ $locale_name != C.UTF-8 ]]; then
        local locale_source=${locale_name%.UTF-8}
        [[ -f /usr/share/i18n/locales/$locale_source ]] || fail 'Locale is not available in Debian.'
        if ! grep -Fxq "$locale_name UTF-8" /etc/locale.gen; then
            printf '\n%s UTF-8\n' "$locale_name" >> /etc/locale.gen
        fi
        locale-gen "$locale_name"
    fi
    # Debian 13 uses locale.conf; older templates also read default/locale.
    update-locale --reset LANG="$locale_name"
    update-locale --locale-file /etc/default/locale --reset LANG="$locale_name"
    update-locale --locale-file /etc/locale.conf --reset LANG="$locale_name"
    unset LANGUAGE LC_ALL
    for item in ${!LC_@}; do unset "$item"; done
    export LANG="$locale_name"
    [[ $(locale charmap) == UTF-8 ]] || fail 'Selected locale did not activate.'
    printf '🌐 Locale configured and verified: %s\n' "$LANG"
    if (( upgrade )); then
        apt-get -o Acquire::Retries=3 update
        apt-get -o Dpkg::Options::=--force-confold -y dist-upgrade
    fi
    ln -snf "/usr/share/zoneinfo/$tz" /etc/localtime
    printf '%s\n' "$tz" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata
    TEMP_DIR=$(mktemp -d)
    install -d -m 0755 /etc/apt/keyrings
    if (( docker )); then
        # Refuse ambiguous existing sources rather than overwrite personal config.
        if grep -Rqs 'download.docker.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
            [[ -f /etc/apt/sources.list.d/sweenlab-docker.sources ]] || fail 'Existing Docker repository requires manual review.'
        fi
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://download.docker.com/linux/debian/gpg -o "$TEMP_DIR/docker.asc"
        local fingerprint
        fingerprint=$(gpg --batch --show-keys --with-colons "$TEMP_DIR/docker.asc" | awk -F: '$1=="fpr" {print $10; exit}')
        [[ "$fingerprint" == 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ]] || fail 'Docker signing key fingerprint mismatch. Review upstream key rotation.'
        install -m 0644 "$TEMP_DIR/docker.asc" /etc/apt/keyrings/sweenlab-docker.asc
        cat > /etc/apt/sources.list.d/sweenlab-docker.sources <<REPO
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/sweenlab-docker.asc
REPO
    fi
    if (( tailscale )); then
        if grep -Rqs 'pkgs.tailscale.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
            [[ -f /etc/apt/sources.list.d/sweenlab-tailscale.sources ]] || fail 'Existing Tailscale repository requires manual review.'
        fi
        # Trust bootstrap: key fetched over verified TLS from the vendor's package domain.
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.noarmor.gpg" -o "$TEMP_DIR/tailscale.gpg"
        gpg --batch --show-keys "$TEMP_DIR/tailscale.gpg" >/dev/null
        install -m 0644 "$TEMP_DIR/tailscale.gpg" /etc/apt/keyrings/sweenlab-tailscale.gpg
        cat > /etc/apt/sources.list.d/sweenlab-tailscale.sources <<REPO
Types: deb
URIs: https://pkgs.tailscale.com/stable/debian
Suites: $VERSION_CODENAME
Components: main
Signed-By: /etc/apt/keyrings/sweenlab-tailscale.gpg
REPO
    fi
    if (( docker || tailscale )); then apt-get -o Acquire::Retries=3 update; fi
    if (( docker )); then
        local -a docker_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin)
        (( compose == 0 )) || docker_packages+=(docker-compose-plugin)
        apt-get install -y --no-install-recommends "${docker_packages[@]}"
        systemctl enable --now docker
        docker info >/dev/null
        (( compose == 0 )) || docker compose version
    fi
    if (( tailscale )); then
        apt-get install -y --no-install-recommends tailscale
        systemctl enable --now tailscaled
        systemctl is-active --quiet tailscaled
        printf 'Tailscale installed. The wizard will handle the selected sign-in options.\n'
    fi
    for item in ${tools[@]+"${tools[@]}"}; do
        [[ $(dpkg-query -W -f='${Status}' "$item") == 'install ok installed' ]] || fail "Verification failed: $item"
    done
    printf '[OK] Selected tools installed; locale %s; timezone %s.\n' "$locale_name" "$tz"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
SWEENLAB_GUEST_INSTALLER
}


if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then main "$@"; fi
