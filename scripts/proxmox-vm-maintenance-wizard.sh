#!/usr/bin/env bash

# Proxmox VM Maintenance Wizard
# https://github.com/SweenLab/personal-proxmox-scripts
#
# Maintains Debian-family virtual machines through QEMU Guest Agent.
# Supports one-time runs, persistent systemd schedules, protected notification
# providers, per-provider severities, and summary or detailed reports.

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'Error: Bash 4 or newer is required. Proxmox VE includes a compatible version.\n' >&2
  exit 1
fi

readonly APP_NAME="Proxmox VM Maintenance Wizard"
readonly APP_VERSION="1.2.2"
readonly INSTALL_PATH="/usr/local/sbin/proxmox-vm-maintenance-wizard"
readonly CONFIG_ROOT="/etc/sweenlab/vm-maintenance"
readonly PLAN_DIR="${CONFIG_ROOT}/plans"
readonly PROVIDER_DIR="${CONFIG_ROOT}/providers"
readonly LOG_ROOT="/var/log/sweenlab/vm-maintenance"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly UNIT_PREFIX="sweenlab-vm-maintenance"
readonly JOURNAL_RETENTION="14d"
readonly GUEST_TIMEOUT=1800
readonly SHUTDOWN_TIMEOUT=240

DIALOG_HEIGHT=22
DIALOG_WIDTH=78
LIST_HEIGHT=12

declare -a VM_IDS=()
declare -a MAINTAINABLE_VM_IDS=()
declare -a APPLIANCE_VM_IDS=()
declare -a SELECTED_VM_IDS=()
declare -a SELECTED_TASKS=()
declare -a SELECTED_PROVIDERS=()
declare -a PROFILE_TASKS=()
declare -a DETAIL_LINES=()

declare -A VM_NAME=()
declare -A VM_STATUS=()
declare -A VM_APPLIANCE=()
declare -A STOPPED_POLICY=()
declare -A TEMP_STARTED=()
declare -A SHUTDOWN_PENDING=()
declare -A TARGET_OK=()
declare -A TARGET_FAILED=()
declare -A TARGET_SKIPPED=()
declare -A TARGET_RECLAIMED=()
declare -A APT_READY=()

PROFILE="weekly"
PLAN_NAME=""
PLAN_SLUG=""
PLAN_REPORT="summary"
PLAN_NOTIFY="none"
PLAN_ENABLED="yes"
PLAN_CALENDAR=""
PLAN_TIMEZONE=""
PLAN_STOPPED_DEFAULT="skip"
PLAN_SOURCE=""
RUN_DIR=""
RUN_STARTED=0
TOTAL_OK=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
CURRENT_STEP=0
TOTAL_STEPS=0

if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
  exec </dev/tty 2>/dev/null || true
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

slugify() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' |
    cut -c1-48
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

truncate_text() {
  local value=$1
  local limit=$2

  if ((${#value} <= limit)); then
    printf '%s' "$value"
  else
    printf '%s\n[Report shortened; full report is stored on the Proxmox host.]' \
      "${value:0:$((limit - 70))}"
  fi
}

array_contains() {
  local needle=$1
  local item

  shift

  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done

  return 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] ||
    die "Run this script as root on the Proxmox host."
}

verify_host() {
  command_exists qm ||
    die "The qm command was not found. Run this on Proxmox VE."

  [[ -d /etc/pve ]] ||
    die "/etc/pve was not found. Run this on Proxmox VE."

  command_exists curl ||
    die "curl is required."

  command_exists systemctl ||
    die "systemd is required."

  command_exists timeout ||
    die "GNU timeout is required."
}

calculate_dialog_size() {
  local rows=24
  local cols=80

  if command_exists tput; then
    rows=$(tput lines 2>/dev/null || printf 24)
    cols=$(tput cols 2>/dev/null || printf 80)
  fi

  [[ $rows =~ ^[0-9]+$ ]] || rows=24
  [[ $cols =~ ^[0-9]+$ ]] || cols=80

  ((rows >= 18 && cols >= 58)) ||
    die "Enlarge the terminal to at least 18 rows by 58 columns."

  DIALOG_HEIGHT=$((rows - 4))
  DIALOG_WIDTH=$((cols - 4))

  ((DIALOG_HEIGHT > 30)) && DIALOG_HEIGHT=30
  ((DIALOG_WIDTH > 96)) && DIALOG_WIDTH=96

  LIST_HEIGHT=$((DIALOG_HEIGHT - 9))
  ((LIST_HEIGHT < 6)) && LIST_HEIGHT=6
}

ensure_whiptail() {
  command_exists whiptail && return

  printf 'whiptail is required for the interactive interface.\n'
  read -r -p "Install it now? [Y/n] " answer

  case "${answer:-Y}" in
    [Yy]*)
      apt-get update &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail ||
        die "whiptail could not be installed."
      ;;
    *)
      die "whiptail is required."
      ;;
  esac
}

ensure_jq() {
  command_exists jq && return

  printf 'jq is required to read QEMU Guest Agent responses.\n'
  read -r -p "Install it now? [Y/n] " answer

  case "${answer:-Y}" in
    [Yy]*)
      apt-get update &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq ||
        die "jq could not be installed."
      ;;
    *)
      die "jq is required."
      ;;
  esac
}

prepare_directories() {
  install -d -m 700 "$CONFIG_ROOT" "$PLAN_DIR" "$PROVIDER_DIR"
  install -d -m 750 "$LOG_ROOT"
}

msg() {
  whiptail \
    --title "$APP_NAME" \
    --msgbox "$1" \
    14 "$DIALOG_WIDTH"
}

input_box() {
  whiptail \
    --title "$APP_NAME" \
    --inputbox "$1" \
    12 "$DIALOG_WIDTH" "${2:-}" \
    3>&1 1>&2 2>&3
}

password_box() {
  whiptail \
    --title "$APP_NAME" \
    --passwordbox "$1" \
    12 "$DIALOG_WIDTH" \
    3>&1 1>&2 2>&3
}

yesno() {
  whiptail \
    --title "$APP_NAME" \
    --defaultno \
    --yesno "$1" \
    14 "$DIALOG_WIDTH"
}

install_self() {
  local source=${BASH_SOURCE[0]}

  [[ -r $source ]] ||
    die "The running script cannot be copied for scheduling."

  install -m 755 "$source" "$INSTALL_PATH"
}

detect_appliance_vm() {
  local vmid=$1
  local name=${VM_NAME[$vmid],,}
  local os_info=""

  VM_APPLIANCE["$vmid"]=""

  case "$name" in
    *home-assistant*|*homeassistant*|*home_assistant*|haos|haos-*)
      VM_APPLIANCE["$vmid"]="Home Assistant OS"
      return
      ;;
    *opnsense*)
      VM_APPLIANCE["$vmid"]="OPNsense"
      return
      ;;
  esac

  if [[ ${VM_STATUS[$vmid]:-} == running ]] &&
     qm agent "$vmid" ping >/dev/null 2>&1; then

    os_info=$(qm agent "$vmid" get-osinfo 2>/dev/null || true)

    case "${os_info,,}" in
      *home\ assistant*)
        VM_APPLIANCE["$vmid"]="Home Assistant OS"
        ;;
      *opnsense*)
        VM_APPLIANCE["$vmid"]="OPNsense"
        ;;
    esac
  fi
}

discover_vms() {
  VM_IDS=()
  MAINTAINABLE_VM_IDS=()
  APPLIANCE_VM_IDS=()

  local vmid
  local name
  local status

  while read -r vmid name status; do
    [[ $vmid =~ ^[0-9]+$ ]] || continue

    VM_IDS+=("$vmid")
    VM_NAME["$vmid"]=${name:-unnamed-vm}
    VM_STATUS["$vmid"]=${status:-unknown}

    detect_appliance_vm "$vmid"

    if [[ -n ${VM_APPLIANCE[$vmid]:-} ]]; then
      APPLIANCE_VM_IDS+=("$vmid")
    else
      MAINTAINABLE_VM_IDS+=("$vmid")
    fi
  done < <(
    qm list 2>/dev/null |
      awk 'NR>1 {print $1, $2, $3}' |
      sort -n
  )
}

show_appliance_notice() {
  ((${#APPLIANCE_VM_IDS[@]})) || return

  local vmid
  local detected=""

  for vmid in "${APPLIANCE_VM_IDS[@]}"; do
    detected+=$'\n'
    detected+="VM ${vmid}: ${VM_NAME[$vmid]} (${VM_APPLIANCE[$vmid]})"
  done

  whiptail \
    --title "Appliance VMs Excluded" \
    --msgbox \
    "The following appliance VMs were detected and removed:
${detected}

They must be updated through their supported interfaces.

Home Assistant OS:
Settings > System > Updates
https://www.home-assistant.io/common-tasks/os/

OPNsense:
System > Firmware > Status
https://docs.opnsense.org/manual/updates.html

This wizard will not maintain these appliance VMs." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
}

agent_available() {
  local vmid=$1

  [[ ${VM_STATUS[$vmid]:-} == running ]] || return 1
  qm agent "$vmid" ping >/dev/null 2>&1
}

guest_exec() {
  local vmid=$1
  local command=$2
  local guest_timeout=${3:-$GUEST_TIMEOUT}
  local response
  local transport_exit
  local guest_exit

  response=$(
    timeout "$guest_timeout" \
      qm guest exec "$vmid" -- bash -lc "$command" 2>&1
  )

  transport_exit=$?

  if ((transport_exit != 0)); then
    printf '%s\n' "$response" >&2
    return 125
  fi

  if ! printf '%s' "$response" |
       jq -e 'type == "object"' >/dev/null 2>&1; then

    printf 'QEMU Guest Agent returned an unreadable response:\n%s\n' \
      "$response" >&2

    return 125
  fi

  printf '%s' "$response" |
    jq -r '."out-data" // empty'

  printf '%s' "$response" |
    jq -r '."err-data" // empty' >&2

  guest_exit=$(
    printf '%s' "$response" |
      jq -r '.exitcode // 255'
  )

  [[ $guest_exit =~ ^[0-9]+$ ]] || return 125

  ((guest_exit <= 255)) || return 255
  return "$guest_exit"
}

guest_capture() {
  local vmid=$1
  local command=$2

  guest_exec "$vmid" "$command" 60 2>/dev/null
}

guest_os_supported() {
  local vmid=$1
  local os_data
  local os_id
  local os_like

  os_data=$(
    guest_capture "$vmid" \
      '. /etc/os-release 2>/dev/null || exit 1; printf "%s|%s" "${ID:-unknown}" "${ID_LIKE:-}"' ||
      true
  )

  IFS='|' read -r os_id os_like <<<"$os_data"

  os_id=${os_id,,}
  os_like=${os_like,,}

  [[ $os_id == debian || $os_id == ubuntu ]] ||
    [[ " ${os_like} " == *" debian "* ]]
}

start_vm() {
  local vmid=$1
  local waited=0

  qm start "$vmid" >/dev/null || return 1

  while ((waited < 120)); do
    VM_STATUS["$vmid"]=$(
      qm status "$vmid" 2>/dev/null |
        awk '{print $2}'
    )

    if [[ ${VM_STATUS[$vmid]} == running ]] &&
       agent_available "$vmid"; then
      return 0
    fi

    sleep 5
    waited=$((waited + 5))
  done

  return 1
}

request_vm_shutdown() {
  local vmid=$1

  printf 'Requesting shutdown for VM %s (%s); continuing...\n' \
    "$vmid" "${VM_NAME[$vmid]:-unknown}"

  qm shutdown "$vmid" --timeout 60 >/dev/null 2>&1 &

  SHUTDOWN_PENDING["$vmid"]=yes
  unset 'TEMP_STARTED[$vmid]'
}

request_remaining_shutdowns() {
  local vmid

  for vmid in "${!TEMP_STARTED[@]}"; do
    [[ ${TEMP_STARTED[$vmid]} == temporary ]] || continue
    request_vm_shutdown "$vmid"
  done
}

wait_for_pending_shutdowns() {
  local waited=0
  local vmid
  local target
  local all_stopped

  ((${#SHUTDOWN_PENDING[@]})) || return

  printf 'Verifying temporarily started VMs are shutting down...\n'

  while ((waited < SHUTDOWN_TIMEOUT)); do
    all_stopped=yes

    for vmid in "${!SHUTDOWN_PENDING[@]}"; do
      if [[ $(
        qm status "$vmid" 2>/dev/null |
          awk '{print $2}'
      ) == stopped ]]; then

        unset 'SHUTDOWN_PENDING[$vmid]'
      else
        all_stopped=no
      fi
    done

    [[ $all_stopped == yes ]] && return

    sleep 5
    waited=$((waited + 5))
  done

  for vmid in "${!SHUTDOWN_PENDING[@]}"; do
    target="vm-${vmid}"

    DETAIL_LINES+=(
      "VM ${vmid}: shutdown was requested but did not finish within ${SHUTDOWN_TIMEOUT} seconds"
    )

    TARGET_FAILED["$target"]=$(( ${TARGET_FAILED[$target]:-0} + 1 ))
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  done
}

choose_vms() {
  discover_vms

  ((${#VM_IDS[@]})) || {
    msg "No VMs were detected on this node."
    return 1
  }

  show_appliance_notice

  ((${#MAINTAINABLE_VM_IDS[@]})) || {
    msg "No eligible VMs remain.

Home Assistant OS and OPNsense must be maintained through their web interfaces."
    return 1
  }

  local -a items=()
  local vmid
  local state
  local output
  local tag

  for vmid in "${MAINTAINABLE_VM_IDS[@]}"; do
    state=OFF
    [[ ${VM_STATUS[$vmid]} == running ]] && state=ON

    items+=(
      "$vmid"
      "${VM_NAME[$vmid]} [${VM_STATUS[$vmid]}]"
      "$state"
    )
  done

  output=$(
    whiptail \
      --title "Select Virtual Machines" \
      --separate-output \
      --checklist \
      "Space: select/unselect. Running Debian-family VMs are selected by default." \
      "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" \
      "${items[@]}" \
      3>&1 1>&2 2>&3
  ) || return 1

  SELECTED_VM_IDS=()

  while IFS= read -r tag; do
    [[ $tag =~ ^[0-9]+$ ]] &&
      SELECTED_VM_IDS+=("$tag")
  done <<<"$output"

  ((${#SELECTED_VM_IDS[@]})) || {
    msg "Select at least one VM."
    return 1
  }
}

choose_stopped_policies() {
  local vmid
  local choice

  for vmid in "${SELECTED_VM_IDS[@]}"; do
    if [[ ${VM_STATUS[$vmid]} == running ]]; then
      STOPPED_POLICY["$vmid"]="running"
      continue
    fi

    choice=$(
      whiptail \
        --title "Stopped VM ${vmid}" \
        --default-item skip \
        --menu "${VM_NAME[$vmid]} is stopped. Choose a policy." \
        17 "$DIALOG_WIDTH" 3 \
        skip "Skip this VM" \
        temporary "Start, maintain, then shut down" \
        leave-running "Start, maintain, and leave running" \
        3>&1 1>&2 2>&3
    ) || choice=skip

    STOPPED_POLICY["$vmid"]=$choice
  done
}

set_profile() {
  PROFILE=$1

  case "$PROFILE" in
    check)
      PROFILE_TASKS=(apt-update apt-check)
      ;;
    weekly)
      PROFILE_TASKS=(
        apt-update
        apt-upgrade
        apt-autoremove
        apt-clean
      )
      ;;
    monthly)
      PROFILE_TASKS=(
        apt-update
        apt-upgrade
        apt-autoremove
        apt-clean
        journal-clean
        temp-clean
        fstrim
      )
      ;;
    docker)
      PROFILE_TASKS=(
        apt-update
        apt-upgrade
        apt-autoremove
        apt-clean
        docker-prune
      )
      ;;
    full)
      PROFILE_TASKS=(
        apt-update
        apt-upgrade
        apt-autoremove
        apt-clean
        journal-clean
        temp-clean
        fstrim
        docker-prune
      )
      ;;
    custom)
      PROFILE_TASKS=(apt-update)
      ;;
  esac
}

choose_profile() {
  local choice

  choice=$(
    whiptail \
      --title "Maintenance Profile" \
      --menu "Choose a starting profile. Tasks can be changed next." \
      20 "$DIALOG_WIDTH" 6 \
      check "Check only; do not install upgrades" \
      weekly "Updates and routine APT cleanup" \
      monthly "Weekly plus journal, temporary files, and trim" \
      docker "Weekly plus Docker cleanup" \
      full "All supported tasks" \
      custom "Choose tasks manually" \
      3>&1 1>&2 2>&3
  ) || return 1

  set_profile "$choice"
}

profile_state() {
  array_contains "$1" "${PROFILE_TASKS[@]}" &&
    printf ON ||
    printf OFF
}

choose_tasks() {
  local output
  local task

  output=$(
    whiptail \
      --title "Select Maintenance Tasks" \
      --separate-output \
      --checklist \
      "Review the profile. Space changes selections." \
      "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" \
      apt-update "Refresh package lists" "$(profile_state apt-update)" \
      apt-check "Report available upgrades only" "$(profile_state apt-check)" \
      apt-upgrade "Install available upgrades" "$(profile_state apt-upgrade)" \
      apt-autoremove "Remove unused packages" "$(profile_state apt-autoremove)" \
      apt-clean "Clean the APT cache" "$(profile_state apt-clean)" \
      journal-clean "Remove journal entries older than ${JOURNAL_RETENTION}" "$(profile_state journal-clean)" \
      temp-clean "Clean temporary files using system policies" "$(profile_state temp-clean)" \
      fstrim "Trim filesystems inside the guest" "$(profile_state fstrim)" \
      docker-prune "Remove unused Docker data (never volumes)" "$(profile_state docker-prune)" \
      3>&1 1>&2 2>&3
  ) || return 1

  SELECTED_TASKS=()

  while IFS= read -r task; do
    [[ -n $task ]] &&
      SELECTED_TASKS+=("$task")
  done <<<"$output"

  ((${#SELECTED_TASKS[@]})) || {
    msg "Select at least one task."
    return 1
  }
}

task_label() {
  case "$1" in
    apt-update)
      printf "Refresh package lists"
      ;;
    apt-check)
      printf "Report available upgrades"
      ;;
    apt-upgrade)
      printf "Install package upgrades"
      ;;
    apt-autoremove)
      printf "Remove unused packages"
      ;;
    apt-clean)
      printf "Clean APT cache"
      ;;
    journal-clean)
      printf "Clean old journal entries"
      ;;
    temp-clean)
      printf "Clean temporary files"
      ;;
    fstrim)
      printf "Trim guest filesystems"
      ;;
    docker-prune)
      printf "Clean unused Docker data"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

task_command() {
  case "$1" in
    apt-update)
      printf 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update'
      ;;
    apt-check)
      printf 'apt-get -s upgrade | awk '\''/^Inst /{count++} END{printf "Available upgrades: %%d\\n", count+0}'\'''
      ;;
    apt-upgrade)
      printf 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -y upgrade'
      ;;
    apt-autoremove)
      printf 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -y autoremove'
      ;;
    apt-clean)
      printf 'apt-get -o DPkg::Lock::Timeout=120 clean'
      ;;
    journal-clean)
      printf 'journalctl --vacuum-time=%q' "$JOURNAL_RETENTION"
      ;;
    temp-clean)
      printf 'systemd-tmpfiles --clean'
      ;;
    fstrim)
      printf 'fstrim -av'
      ;;
    docker-prune)
      printf 'docker system prune -f'
      ;;
    *)
      return 1
      ;;
  esac
}

task_requirement() {
  case "$1" in
    journal-clean)
      printf 'journalctl'
      ;;
    temp-clean)
      printf 'systemd-tmpfiles'
      ;;
    fstrim)
      printf 'fstrim'
      ;;
    docker-prune)
      printf 'docker'
      ;;
    *)
      return 1
      ;;
  esac
}

guest_has_command() {
  local vmid=$1
  local command_name=$2

  guest_exec \
    "$vmid" \
    "command -v ${command_name} >/dev/null 2>&1" \
    >/dev/null 2>&1
}

provider_paths() {
  find "$PROVIDER_DIR" \
    -maxdepth 1 \
    -type f \
    -name '*.conf' \
    -print 2>/dev/null |
    sort
}

provider_names() {
  local file

  while IFS= read -r file; do
    [[ -n $file ]] &&
      basename "$file" .conf
  done < <(provider_paths)
}

providers_exist() {
  compgen -G "${PROVIDER_DIR}/*.conf" >/dev/null
}

provider_config_write() {
  local slug=$1
  local name=$2
  local type=$3
  local severities=$4
  local report=$5

  shift 5

  local path="${PROVIDER_DIR}/${slug}.conf"
  local pair
  local key
  local value

  {
    printf 'PROVIDER_NAME=%q\n' "$name"
    printf 'PROVIDER_TYPE=%q\n' "$type"
    printf 'PROVIDER_SEVERITIES=%q\n' "$severities"
    printf 'PROVIDER_REPORT=%q\n' "$report"

    for pair in "$@"; do
      key=${pair%%=*}
      value=${pair#*=}
      printf '%s=%q\n' "$key" "$value"
    done
  } >"$path"

  chmod 600 "$path"
}

choose_severities() {
  local output
  local severity
  local values=()

  output=$(
    whiptail \
      --title "Notification Severities" \
      --separate-output \
      --checklist \
      "Choose which severities this provider receives." \
      17 "$DIALOG_WIDTH" 4 \
      info "Successful and informational reports" ON \
      warning "Completed with skipped tasks or warnings" ON \
      error "Maintenance task failures" ON \
      critical "Critical failures" ON \
      3>&1 1>&2 2>&3
  ) || return 1

  while IFS= read -r severity; do
    [[ -n $severity ]] &&
      values+=("$severity")
  done <<<"$output"

  ((${#values[@]})) || return 1
  printf '%s' "${values[*]}"
}

choose_report_format() {
  whiptail \
    --title "Report Format" \
    --menu "Choose the report detail." \
    15 "$DIALOG_WIDTH" 2 \
    summary "Short result and totals" \
    detailed "Per-VM task results and totals" \
    3>&1 1>&2 2>&3
}

ensure_apprise() {
  command_exists apprise && return 0

  yesno "Apprise is not installed.

Install it now with apt and pipx?" ||
    return 1

  apt-get update &&
    DEBIAN_FRONTEND=noninteractive apt-get install -y pipx &&
    PIPX_HOME=/opt/pipx \
      PIPX_BIN_DIR=/usr/local/bin \
      pipx install apprise
}

add_provider() {
  local type
  local name
  local slug
  local severities
  local report
  local value1=""
  local value2=""
  local value3=""
  local value4=""

  type=$(
    whiptail \
      --title "Add Notification Provider" \
      --menu "Choose a provider. No SweenLab backend is used." \
      24 "$DIALOG_WIDTH" 10 \
      none "No Notifications" \
      discord "Discord incoming webhook" \
      slack "Slack incoming webhook" \
      telegram "Telegram bot" \
      ntfy "ntfy server and topic" \
      gotify "Gotify server and application token" \
      pushover "Pushover application and user tokens" \
      smtp "SMTP email" \
      webhook "Generic JSON webhook" \
      apprise "Advanced Apprise URL" \
      3>&1 1>&2 2>&3
  ) || return

  [[ $type == none ]] && return

  if [[ $type == pushover ]]; then
    while [[ -z $value1 ]]; do
      value1=$(
        input_box \
          "Paste the Pushover Application API Token.

The token is visible while entering it and stored in a root-only file."
      ) || return

      [[ -n $value1 ]] ||
        msg "The Application API Token cannot be blank.

Press Enter to try again."
    done

    while [[ -z $value2 ]]; do
      value2=$(
        input_box \
          "Paste the Pushover User Key or Group Key.

The key is visible while entering it and stored in a root-only file."
      ) || return

      [[ -n $value2 ]] ||
        msg "The User Key cannot be blank.

Press Enter to try again."
    done
  fi

  name=$(
    input_box \
      "Friendly provider name:" \
      "${type}-notifications"
  ) || return

  slug=$(slugify "$name")

  [[ -n $slug ]] || {
    msg "The provider name needs a letter or number."
    return
  }

  severities=$(choose_severities) || return
  report=$(choose_report_format) || return

  case "$type" in
    discord|slack|webhook)
      value1=$(
        password_box \
          "Paste the webhook URL.

Typing and pasted text are hidden."
      ) || return

      [[ -n $value1 ]] || {
        msg "A webhook URL is required."
        return
      }

      provider_config_write \
        "$slug" "$name" "$type" "$severities" "$report" \
        "WEBHOOK_URL=$value1"
      ;;
    telegram)
      value1=$(
        password_box \
          "Telegram bot token:

Typing and pasted text are hidden."
      ) || return

      value2=$(input_box "Telegram chat ID:") || return

      [[ -n $value1 && -n $value2 ]] || {
        msg "A bot token and chat ID are required."
        return
      }

      provider_config_write \
        "$slug" "$name" "$type" "$severities" "$report" \
        "BOT_TOKEN=$value1" \
        "CHAT_ID=$value2"
      ;;
    ntfy)
      value1=$(
        input_box \
          "ntfy server URL:" \
          "https://ntfy.sh"
      ) || return

      value2=$(input_box "ntfy topic:") || return
      value3=$(input_box "Optional access token:") || return

      [[ -n $value1 && -n $value2 ]] || {
        msg "An ntfy server URL and topic are required."
        return
      }

      provider_config_write \
        "$slug" "$name" "$type" "$severities" "$report" \
        "SERVER_URL=$value1" \
        "TOPIC=$value2" \
        "ACCESS_TOKEN=$value3"
      ;;
    gotify)
      value1=$(input_box "Gotify server URL:") || return

      value2=$(
        password_box \
          "Gotify application token:

Typing and pasted text are hidden."
      ) || return

      [[ -n $value1 && -n $value2 ]] || {
        msg "A Gotify server URL and token are required."
        return
      }

      provider_config_write \
        "$slug" "$name" "$type" "$severities" "$report" \
        "SERVER_URL=$value1" \
        "APP_TOKEN=$value2"
      ;;
    pushover)
      provider_config_write \
        "$slug" "$name" "$type" "$severities" "$report" \
        "APP_TOKEN=$value1" \
        "USER_KEY=$value2"
      ;;
    smtp)
      value1=$(
        input_box \
          "SMTP URL:

Example: smtps://smtp.example.com:465"
      ) || return

      value2=$(input_box "SMTP username:") || return

      value3=$(
        password_box \
          "SMTP password:

Typing and pasted text are hidden."
      ) || return

      value4=$(
        input_box \
          "Sender and recipient separated by a comma:

from@example.com,to@example.com"
      ) || return

      [[ -n $value1 && -n $value4 && $value4 == *,* ]] || {
        msg "A valid SMTP URL, sender, and recipient are required."
        return
      }

      provider_config_write \
        "$slug" "$name" "$type" "$severities" "$report" \
        "SMTP_URL=$value1" \
        "SMTP_USER=$value2" \
        "SMTP_PASS=$value3" \
        "MAIL_FROM=${value4%%,*}" \
        "MAIL_TO=${value4#*,}"
      ;;
    apprise)
      ensure_apprise || {
        msg "Apprise was not installed."
        return
      }

      value1=$(
        password_box \
          "Apprise notification URL:

Typing and pasted text are hidden."
      ) || return

      [[ -n $value1 ]] || {
        msg "An Apprise notification URL is required."
        return
      }

      provider_config_write \
        "$slug" "$name" "$type" "$severities" "$report" \
        "APPRISE_URL=$value1"
      ;;
  esac

  if test_provider "$slug"; then
    msg "Test notification sent successfully.

The provider was saved."
  else
    msg "The provider was saved, but its test failed.

Check its credentials or network connection.

Tests automatically stop after 20 seconds."
  fi
}

load_provider() {
  local slug=$1
  local path="${PROVIDER_DIR}/${slug}.conf"

  [[ -r $path ]] || return 1

  unset PROVIDER_NAME
  unset PROVIDER_TYPE
  unset PROVIDER_SEVERITIES
  unset PROVIDER_REPORT
  unset WEBHOOK_URL
  unset BOT_TOKEN
  unset CHAT_ID
  unset SERVER_URL
  unset TOPIC
  unset ACCESS_TOKEN
  unset APP_TOKEN
  unset USER_KEY
  unset SMTP_URL
  unset SMTP_USER
  unset SMTP_PASS
  unset MAIL_FROM
  unset MAIL_TO
  unset APPRISE_URL

  # Root-owned configuration generated by this script.
  # shellcheck disable=SC1090
  source "$path"
}

send_provider() {
  local slug=$1
  local title=$2
  local body=$3
  local severity=$4
  local force=${5:-no}
  local payload
  local auth=()
  local mail
  local message
  local result

  load_provider "$slug" || return 1

  if [[ $force != yes ]]; then
    array_contains "$severity" ${PROVIDER_SEVERITIES:-} ||
      return 0
  fi

  case "$PROVIDER_TYPE" in
    discord)
      body=$(truncate_text "$body" 1750)
      message="${title}"$'\n\n'"${body}"
      payload="{\"username\":\"SweenLab\",\"content\":\"$(json_escape "$message")\"}"

      curl -fsS \
        --connect-timeout 5 \
        --max-time 20 \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$WEBHOOK_URL" \
        >/dev/null
      ;;
    slack)
      body=$(truncate_text "$body" 35000)
      message="*${title}*"$'\n'"${body}"
      payload="{\"text\":\"$(json_escape "$message")\"}"

      curl -fsS \
        --connect-timeout 5 \
        --max-time 20 \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$WEBHOOK_URL" \
        >/dev/null
      ;;
    telegram)
      body=$(truncate_text "$body" 3800)

      curl -fsS \
        --connect-timeout 5 \
        --max-time 20 \
        -X POST \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${title}"$'\n\n'"${body}" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        >/dev/null
      ;;
    ntfy)
      body=$(truncate_text "$body" 3500)

      [[ -n ${ACCESS_TOKEN:-} ]] &&
        auth=(-H "Authorization: Bearer ${ACCESS_TOKEN}")

      curl -fsS \
        --connect-timeout 5 \
        --max-time 20 \
        "${auth[@]}" \
        -H "Title: ${title}" \
        -H "Priority: $(
          [[ $severity == critical ]] &&
            printf 5 ||
            printf 3
        )" \
        -d "$body" \
        "${SERVER_URL%/}/${TOPIC}" \
        >/dev/null
      ;;
    gotify)
      body=$(truncate_text "$body" 15000)

      curl -fsS \
        --connect-timeout 5 \
        --max-time 20 \
        -X POST \
        -F "title=$title" \
        -F "message=$body" \
        -F "priority=$(
          [[ $severity == critical ]] &&
            printf 8 ||
            printf 4
        )" \
        "${SERVER_URL%/}/message?token=${APP_TOKEN}" \
        >/dev/null
      ;;
    pushover)
      body=$(truncate_text "$body" 900)

      curl -fsS \
        --connect-timeout 5 \
        --max-time 20 \
        -X POST \
        --data-urlencode "token=${APP_TOKEN}" \
        --data-urlencode "user=${USER_KEY}" \
        --data-urlencode "title=${title}" \
        --data-urlencode "message=${body}" \
        -d "priority=$(
          [[ $severity == critical ]] &&
            printf 1 ||
            printf 0
        )" \
        https://api.pushover.net/1/messages.json \
        >/dev/null
      ;;
    smtp)
      mail=$(mktemp)

      {
        printf 'From: %s\r\n' "$MAIL_FROM"
        printf 'To: %s\r\n' "$MAIL_TO"
        printf 'Subject: %s\r\n' "$title"
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf '\r\n%s\r\n' "$body"
      } >"$mail"

      curl -fsS \
        --connect-timeout 5 \
        --max-time 30 \
        --url "$SMTP_URL" \
        --ssl-reqd \
        --user "${SMTP_USER}:${SMTP_PASS}" \
        --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" \
        --upload-file "$mail" \
        >/dev/null

      result=$?
      rm -f "$mail"
      return "$result"
      ;;
    webhook)
      payload="{\"source\":\"SweenLab\",\"title\":\"$(json_escape "$title")\",\"severity\":\"$severity\",\"message\":\"$(json_escape "$body")\"}"

      curl -fsS \
        --connect-timeout 5 \
        --max-time 20 \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$WEBHOOK_URL" \
        >/dev/null
      ;;
    apprise)
      command_exists apprise || return 1

      timeout 30 \
        apprise \
          -b "$body" \
          -t "$title" \
          "$APPRISE_URL" \
          >/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

test_provider() {
  send_provider \
    "$1" \
    "SweenLab Test Notification" \
    "The Proxmox VM Maintenance Wizard can reach this provider." \
    info \
    yes
}

select_existing_provider() {
  local -a items=()
  local slug

  while IFS= read -r slug; do
    [[ -n $slug ]] &&
      items+=("$slug" "$slug")
  done < <(provider_names)

  ((${#items[@]})) || return 1

  whiptail \
    --title "Notification Providers" \
    --menu "Choose a provider." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

notification_center() {
  local action
  local slug

  while true; do
    action=$(
      whiptail \
        --title "Notification Settings" \
        --menu \
        "Providers are stored locally with root-only permissions." \
        20 "$DIALOG_WIDTH" 6 \
        add "Add a provider" \
        test "Test a provider" \
        view "View configured provider names" \
        edit "Replace a provider configuration" \
        remove "Remove a provider" \
        back "Return to the main menu" \
        3>&1 1>&2 2>&3
    ) || return

    case "$action" in
      add)
        add_provider
        ;;
      test)
        if ! providers_exist; then
          yesno "No notification providers are configured.

Add one now?" &&
            add_provider

          continue
        fi

        slug=$(select_existing_provider) || continue

        if test_provider "$slug"; then
          msg "Test sent successfully."
        else
          msg "The notification test failed.

Check the credentials and network connection.

The test automatically stops after 20 seconds."
        fi
        ;;
      view)
        if providers_exist; then
          msg "Configured providers:

$(provider_names | sed 's/^/- /')"
        else
          msg "No notification providers are configured."
        fi
        ;;
      edit)
        slug=$(select_existing_provider) || continue

        rm -f "${PROVIDER_DIR}/${slug}.conf"
        add_provider
        ;;
      remove)
        slug=$(select_existing_provider) || continue

        yesno "Remove provider '${slug}'?" &&
          rm -f "${PROVIDER_DIR}/${slug}.conf"
        ;;
      back)
        return
        ;;
    esac
  done
}

choose_plan_notifications() {
  local choice
  local output
  local slug
  local -a items=()

  choice=$(
    whiptail \
      --title "Notifications" \
      --menu \
      "Choose whether this maintenance plan sends reports." \
      16 "$DIALOG_WIDTH" 2 \
      none "No Notifications" \
      configured "Use configured providers" \
      3>&1 1>&2 2>&3
  ) || return 1

  PLAN_NOTIFY=$choice
  SELECTED_PROVIDERS=()

  [[ $choice == none ]] && return

  if ! providers_exist; then
    yesno "No notification providers are configured.

Open Notification Settings now?" &&
      notification_center

    return 1
  fi

  while IFS= read -r slug; do
    [[ -n $slug ]] &&
      items+=("$slug" "$slug" ON)
  done < <(provider_names)

  output=$(
    whiptail \
      --title "Plan Notification Providers" \
      --separate-output \
      --checklist \
      "Choose one or more providers." \
      "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" \
      "${items[@]}" \
      3>&1 1>&2 2>&3
  ) || return 1

  while IFS= read -r slug; do
    [[ -n $slug ]] &&
      SELECTED_PROVIDERS+=("$slug")
  done <<<"$output"

  ((${#SELECTED_PROVIDERS[@]})) || return 1
}

detect_timezone() {
  timedatectl show \
    --property=Timezone \
    --value 2>/dev/null ||
    cat /etc/timezone 2>/dev/null ||
    printf UTC
}

choose_calendar() {
  local frequency
  local time
  local day
  local timezone

  timezone=$(detect_timezone)

  frequency=$(
    whiptail \
      --title "Schedule Frequency" \
      --menu "Choose a schedule." \
      18 "$DIALOG_WIDTH" 4 \
      daily "Every day" \
      weekly "Once each week" \
      monthly "Once each month" \
      custom "Custom OnCalendar value" \
      3>&1 1>&2 2>&3
  ) || return 1

  PLAN_TIMEZONE=$(
    input_box \
      "Timezone (IANA name):" \
      "$timezone"
  ) || return 1

  case "$frequency" in
    daily)
      time=$(input_box "Time (24-hour HH:MM):" "03:00") ||
        return 1

      PLAN_CALENDAR="*-*-* ${time}:00 ${PLAN_TIMEZONE}"
      ;;
    weekly)
      day=$(
        whiptail \
          --title "Day" \
          --menu "Choose a weekday." \
          18 60 7 \
          Mon Monday \
          Tue Tuesday \
          Wed Wednesday \
          Thu Thursday \
          Fri Friday \
          Sat Saturday \
          Sun Sunday \
          3>&1 1>&2 2>&3
      ) || return 1

      time=$(input_box "Time (24-hour HH:MM):" "03:00") ||
        return 1

      PLAN_CALENDAR="${day} *-*-* ${time}:00 ${PLAN_TIMEZONE}"
      ;;
    monthly)
      day=$(input_box "Day of month (1-28):" "1") ||
        return 1

      [[ $day =~ ^([1-9]|1[0-9]|2[0-8])$ ]] ||
        return 1

      time=$(input_box "Time (24-hour HH:MM):" "03:00") ||
        return 1

      PLAN_CALENDAR="*-*-${day} ${time}:00 ${PLAN_TIMEZONE}"
      ;;
    custom)
      PLAN_CALENDAR=$(
        input_box \
          "systemd OnCalendar value:" \
          "*-*-* 03:00:00 ${PLAN_TIMEZONE}"
      ) || return 1
      ;;
  esac

  systemd-analyze calendar "$PLAN_CALENDAR" >/dev/null 2>&1 || {
    msg "The schedule is not valid:

${PLAN_CALENDAR}"

    return 1
  }
}

write_plan() {
  local path="${PLAN_DIR}/${PLAN_SLUG}.conf"
  local vmid

  {
    printf 'PLAN_NAME=%q\n' "$PLAN_NAME"
    printf 'PLAN_SLUG=%q\n' "$PLAN_SLUG"
    printf 'PLAN_PROFILE=%q\n' "$PROFILE"
    printf 'PLAN_VMS=%q\n' "${SELECTED_VM_IDS[*]}"
    printf 'PLAN_TASKS=%q\n' "${SELECTED_TASKS[*]}"
    printf 'PLAN_NOTIFY=%q\n' "$PLAN_NOTIFY"
    printf 'PLAN_PROVIDERS=%q\n' "${SELECTED_PROVIDERS[*]}"
    printf 'PLAN_REPORT=%q\n' "$PLAN_REPORT"
    printf 'PLAN_CALENDAR=%q\n' "$PLAN_CALENDAR"
    printf 'PLAN_TIMEZONE=%q\n' "$PLAN_TIMEZONE"
    printf 'PLAN_ENABLED=%q\n' "$PLAN_ENABLED"

    for vmid in "${SELECTED_VM_IDS[@]}"; do
      printf 'STOPPED_%s=%q\n' \
        "$vmid" \
        "${STOPPED_POLICY[$vmid]:-$PLAN_STOPPED_DEFAULT}"
    done
  } >"$path"

  chmod 600 "$path"
}

load_plan() {
  local slug=$1
  local path="${PLAN_DIR}/${slug}.conf"
  local vmid
  local var

  [[ -r $path ]] || return 1

  # Root-owned configuration generated by this script.
  # shellcheck disable=SC1090
  source "$path"

  PROFILE=${PLAN_PROFILE:-weekly}

  read -r -a SELECTED_VM_IDS <<<"${PLAN_VMS:-}"
  read -r -a SELECTED_TASKS <<<"${PLAN_TASKS:-}"
  read -r -a SELECTED_PROVIDERS <<<"${PLAN_PROVIDERS:-}"

  for vmid in "${SELECTED_VM_IDS[@]}"; do
    var="STOPPED_${vmid}"
    STOPPED_POLICY["$vmid"]=${!var:-skip}
  done
}

plan_names() {
  local file

  for file in "$PLAN_DIR"/*.conf; do
    [[ -e $file ]] || continue
    basename "$file" .conf
  done
}

select_plan() {
  local -a items=()
  local slug

  while IFS= read -r slug; do
    [[ -n $slug ]] &&
      items+=("$slug" "$slug")
  done < <(plan_names)

  ((${#items[@]})) || {
    msg "No scheduled plans exist."
    return 1
  }

  whiptail \
    --title "Scheduled Plans" \
    --menu "Choose a plan." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

write_units() {
  local slug=$1
  local conf="${PLAN_DIR}/${slug}.conf"

  load_plan "$slug" || return 1
  install_self

  cat >"${SYSTEMD_DIR}/${UNIT_PREFIX}-${slug}.service" <<EOF
[Unit]
Description=SweenLab VM maintenance plan: ${slug}
Wants=network-online.target
After=network-online.target
ConditionPathExists=${conf}

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --run-plan ${slug}
EOF

  cat >"${SYSTEMD_DIR}/${UNIT_PREFIX}-${slug}.timer" <<EOF
[Unit]
Description=Timer for SweenLab VM maintenance plan: ${slug}

[Timer]
OnCalendar=${PLAN_CALENDAR}
Persistent=true
Unit=${UNIT_PREFIX}-${slug}.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload

  if [[ ${PLAN_ENABLED:-yes} == yes ]]; then
    systemctl enable \
      --now \
      "${UNIT_PREFIX}-${slug}.timer"
  else
    systemctl disable \
      --now \
      "${UNIT_PREFIX}-${slug}.timer" \
      >/dev/null 2>&1 ||
      true
  fi
}

create_or_edit_plan() {
  local existing=${1:-}

  if [[ -n $existing ]]; then
    load_plan "$existing" || return
    discover_vms
  else
    choose_vms || return
    choose_stopped_policies
    choose_profile || return
    choose_tasks || return
    choose_plan_notifications || return
    PLAN_REPORT=$(choose_report_format) || return
    choose_calendar || return

    PLAN_NAME=$(
      input_box \
        "Schedule name:" \
        "Weekly VM Maintenance"
    ) || return

    PLAN_SLUG=$(slugify "$PLAN_NAME")
    PLAN_ENABLED=yes
  fi

  if [[ -n $existing ]]; then
    PLAN_NAME=$(
      input_box \
        "Schedule name:" \
        "$PLAN_NAME"
    ) || return

    PLAN_SLUG=$existing

    choose_vms || return
    choose_stopped_policies
    choose_profile || return
    choose_tasks || return
    choose_plan_notifications || return
    PLAN_REPORT=$(choose_report_format) || return
    choose_calendar || return
  fi

  [[ -n $PLAN_SLUG ]] || {
    msg "A valid schedule name is required."
    return
  }

  write_plan
  write_units "$PLAN_SLUG"

  msg "Scheduled plan saved:

${PLAN_NAME}
${PLAN_CALENDAR}"
}

view_plans() {
  local output

  output=$(
    systemctl list-timers \
      --all \
      "${UNIT_PREFIX}-*.timer" \
      --no-pager 2>&1 ||
      true
  )

  msg "$output"
}

toggle_plan() {
  local slug
  local state

  slug=$(select_plan) || return
  load_plan "$slug" || return

  if systemctl is-enabled \
       --quiet \
       "${UNIT_PREFIX}-${slug}.timer"; then

    state=no

    systemctl disable \
      --now \
      "${UNIT_PREFIX}-${slug}.timer" \
      >/dev/null
  else
    state=yes

    systemctl enable \
      --now \
      "${UNIT_PREFIX}-${slug}.timer" \
      >/dev/null
  fi

  PLAN_ENABLED=$state
  write_plan

  msg "Plan '${slug}' is now $(
    [[ $state == yes ]] &&
      printf enabled ||
      printf disabled
  )."
}

delete_plan() {
  local slug

  slug=$(select_plan) || return
  yesno "Delete scheduled plan '${slug}'?" || return

  systemctl disable \
    --now \
    "${UNIT_PREFIX}-${slug}.timer" \
    >/dev/null 2>&1 ||
    true

  rm -f \
    "${SYSTEMD_DIR}/${UNIT_PREFIX}-${slug}.timer" \
    "${SYSTEMD_DIR}/${UNIT_PREFIX}-${slug}.service" \
    "${PLAN_DIR}/${slug}.conf"

  systemctl daemon-reload

  msg "Plan '${slug}' was deleted."
}

prepare_run() {
  local label=$1
  local count=0
  local vmid

  RUN_STARTED=$(date +%s)
  RUN_DIR="${LOG_ROOT}/$(date '+%Y%m%d-%H%M%S')-${label}"

  install -d -m 750 "$RUN_DIR"

  DETAIL_LINES=()
  TARGET_OK=()
  TARGET_FAILED=()
  TARGET_SKIPPED=()
  TARGET_RECLAIMED=()
  TEMP_STARTED=()
  SHUTDOWN_PENDING=()
  APT_READY=()

  TOTAL_OK=0
  TOTAL_FAILED=0
  TOTAL_SKIPPED=0
  CURRENT_STEP=0

  for vmid in "${SELECTED_VM_IDS[@]}"; do
    if [[ ${STOPPED_POLICY[$vmid]:-skip} == skip &&
          ${VM_STATUS[$vmid]:-stopped} != running ]]; then
      continue
    fi

    count=$((count + 1))
  done

  TOTAL_STEPS=$((count * ${#SELECTED_TASKS[@]}))
}

run_task() {
  local vmid=$1
  local task=$2
  local target="vm-${vmid}"
  local label
  local command
  local log
  local before
  local after
  local rc
  local requirement
  local failure_reason

  label=$(task_label "$task")
  command=$(task_command "$task") || return
  log="${RUN_DIR}/${target}-${task}.log"

  CURRENT_STEP=$((CURRENT_STEP + 1))

  printf '[%d/%d] VM %s (%s): %s... ' \
    "$CURRENT_STEP" \
    "$TOTAL_STEPS" \
    "$vmid" \
    "${VM_NAME[$vmid]}" \
    "$label"

  if [[ $task == apt-check ||
        $task == apt-upgrade ||
        $task == apt-autoremove ||
        $task == apt-clean ]] &&
     [[ ${APT_READY[$vmid]:-yes} == no ]]; then

    printf 'SKIPPED\n'

    TARGET_SKIPPED["$target"]=$(( ${TARGET_SKIPPED[$target]:-0} + 1 ))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))

    DETAIL_LINES+=(
      "VM ${vmid} ${VM_NAME[$vmid]}: ${label} - SKIPPED because package-list refresh failed"
    )

    return
  fi

  if requirement=$(task_requirement "$task" 2>/dev/null) &&
     ! guest_has_command "$vmid" "$requirement"; then

    printf 'SKIPPED (%s is not installed)\n' "$requirement"

    TARGET_SKIPPED["$target"]=$(( ${TARGET_SKIPPED[$target]:-0} + 1 ))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))

    DETAIL_LINES+=(
      "VM ${vmid} ${VM_NAME[$vmid]}: ${label} - SKIPPED; ${requirement} is not installed"
    )

    return
  fi

  before=$(
    guest_capture \
      "$vmid" \
      "df -B1 --output=avail / | tail -1" |
      tr -dc '0-9'
  )

  guest_exec "$vmid" "$command" >"$log" 2>&1
  rc=$?

  after=$(
    guest_capture \
      "$vmid" \
      "df -B1 --output=avail / | tail -1" |
      tr -dc '0-9'
  )

  if [[ $task == apt-update ]]; then
    if ((rc == 0)); then
      APT_READY["$vmid"]=yes
    else
      APT_READY["$vmid"]=no
    fi
  fi

  if ((rc == 0)); then
    printf 'OK\n'

    TARGET_OK["$target"]=$(( ${TARGET_OK[$target]:-0} + 1 ))
    TOTAL_OK=$((TOTAL_OK + 1))

    DETAIL_LINES+=(
      "VM ${vmid} ${VM_NAME[$vmid]}: ${label} - OK"
    )
  else
    printf 'FAILED\n'

    TARGET_FAILED["$target"]=$(( ${TARGET_FAILED[$target]:-0} + 1 ))
    TOTAL_FAILED=$((TOTAL_FAILED + 1))

    failure_reason=$(
      tail -n 5 "$log" 2>/dev/null |
        tr '\n' ' ' |
        sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' |
        cut -c1-300
    )

    if [[ -n $failure_reason ]]; then
      DETAIL_LINES+=(
        "VM ${vmid} ${VM_NAME[$vmid]}: ${label} - FAILED: ${failure_reason} (full log: ${log})"
      )
    else
      DETAIL_LINES+=(
        "VM ${vmid} ${VM_NAME[$vmid]}: ${label} - FAILED (see ${log})"
      )
    fi
  fi

  if [[ $before =~ ^[0-9]+$ &&
        $after =~ ^[0-9]+$ ]]; then

    TARGET_RECLAIMED["$target"]=$(( ${TARGET_RECLAIMED[$target]:-0} + after - before ))
  fi
}

handle_interruption() {
  printf '\nMaintenance interrupted. Requesting shutdowns for temporarily started VMs...\n' >&2

  request_remaining_shutdowns
  wait_for_pending_shutdowns

  exit 130
}

trap handle_interruption INT TERM

run_selected_plan() {
  discover_vms
  prepare_run "${PLAN_SLUG:-one-time}"

  local vmid
  local task
  local policy
  local target

  for vmid in "${SELECTED_VM_IDS[@]}"; do
    target="vm-${vmid}"

    if ! array_contains "$vmid" "${VM_IDS[@]}"; then
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))

      DETAIL_LINES+=(
        "VM ${vmid}: no longer exists on this node - SKIPPED"
      )

      continue
    fi

    if [[ -n ${VM_APPLIANCE[$vmid]:-} ]]; then
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
      TARGET_SKIPPED["$target"]=1

      DETAIL_LINES+=(
        "VM ${vmid} ${VM_NAME[$vmid]}: ${VM_APPLIANCE[$vmid]} appliance - SKIPPED; use its supported web interface"
      )

      continue
    fi

    policy=${STOPPED_POLICY[$vmid]:-skip}

    if [[ ${VM_STATUS[$vmid]} != running ]]; then
      case "$policy" in
        skip)
          TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
          TARGET_SKIPPED["$target"]=1

          DETAIL_LINES+=(
            "VM ${vmid} ${VM_NAME[$vmid]}: stopped - SKIPPED"
          )

          continue
          ;;
        temporary|leave-running)
          printf 'Starting VM %s (%s)...\n' \
            "$vmid" \
            "${VM_NAME[$vmid]}"

          if ! start_vm "$vmid"; then
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
            TARGET_FAILED["$target"]=1

            DETAIL_LINES+=(
              "VM ${vmid}: failed to start or QEMU Guest Agent did not become ready"
            )

            continue
          fi

          TEMP_STARTED["$vmid"]=$policy
          ;;
      esac
    elif ! agent_available "$vmid"; then
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      TARGET_FAILED["$target"]=1

      DETAIL_LINES+=(
        "VM ${vmid}: QEMU Guest Agent unavailable"
      )

      continue
    fi

    if ! guest_os_supported "$vmid"; then
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
      TARGET_SKIPPED["$target"]=1

      DETAIL_LINES+=(
        "VM ${vmid}: unsupported guest OS; a Debian-family system is required"
      )

      continue
    fi

    APT_READY["$vmid"]=yes

    for task in "${SELECTED_TASKS[@]}"; do
      run_task "$vmid" "$task"
    done

    if [[ ${TEMP_STARTED[$vmid]:-} == temporary ]]; then
      request_vm_shutdown "$vmid"
    fi
  done

  request_remaining_shutdowns
  wait_for_pending_shutdowns
  finish_report
}

finish_report() {
  local ended
  local elapsed
  local severity
  local title
  local summary
  local detailed
  local slug
  local body

  ended=$(date +%s)
  elapsed=$((ended - RUN_STARTED))

  if ((TOTAL_FAILED > 0)); then
    severity=error
  elif ((TOTAL_SKIPPED > 0)); then
    severity=warning
  else
    severity=info
  fi

  title="SweenLab VM Maintenance: $(
    [[ $severity == info ]] &&
      printf Complete ||
      printf Attention
  )"

  summary=$(
    printf \
      'Plan: %s\nSuccessful tasks: %d\nFailed tasks: %d\nSkipped VMs/tasks: %d\nRuntime: %dm %ds\nLogs: %s' \
      "${PLAN_NAME:-One-time Maintenance}" \
      "$TOTAL_OK" \
      "$TOTAL_FAILED" \
      "$TOTAL_SKIPPED" \
      "$((elapsed / 60))" \
      "$((elapsed % 60))" \
      "$RUN_DIR"
  )

  detailed="${summary}"$'\n\n'"$(
    printf '%s\n' "${DETAIL_LINES[@]}"
  )"

  printf '%s\n' "$detailed" |
    tee "${RUN_DIR}/report.txt"

  if [[ ${PLAN_NOTIFY:-none} == configured ]]; then
    for slug in "${SELECTED_PROVIDERS[@]}"; do
      load_provider "$slug" || continue

      body=$summary

      [[ ${PROVIDER_REPORT:-$PLAN_REPORT} == detailed ]] &&
        body=$detailed

      send_provider \
        "$slug" \
        "$title" \
        "$body" \
        "$severity" ||
        printf 'Notification failed: %s\n' \
          "$slug" \
          >>"${RUN_DIR}/notification-errors.log"
    done
  fi

  ((TOTAL_FAILED == 0))
}

one_time_run() {
  PLAN_NAME="One-time VM Maintenance"
  PLAN_SLUG="one-time"

  choose_vms || return
  choose_stopped_policies
  choose_profile || return
  choose_tasks || return
  choose_plan_notifications || return
  PLAN_REPORT=$(choose_report_format) || return

  yesno "Run this one-time maintenance plan now?

VMs: ${SELECTED_VM_IDS[*]}
Tasks: ${SELECTED_TASKS[*]}
Notifications: ${PLAN_NOTIFY}" ||
    return

  clear
  run_selected_plan
}

main_menu() {
  local action
  local slug

  while true; do
    action=$(
      whiptail \
        --title "$APP_NAME v${APP_VERSION}" \
        --menu \
        "Maintain Debian-family VMs through QEMU Guest Agent." \
        23 "$DIALOG_WIDTH" 9 \
        run "Run one-time maintenance" \
        create "Create a scheduled plan" \
        view "View scheduled plans" \
        edit "Edit a scheduled plan" \
        run-plan "Run a saved plan now" \
        toggle "Enable or disable a scheduled plan" \
        delete "Delete a scheduled plan" \
        notifications "Notification Settings" \
        exit "Exit" \
        3>&1 1>&2 2>&3
    ) || break

    case "$action" in
      run)
        one_time_run
        ;;
      create)
        create_or_edit_plan
        ;;
      view)
        view_plans
        ;;
      edit)
        slug=$(select_plan) &&
          create_or_edit_plan "$slug"
        ;;
      run-plan)
        slug=$(select_plan) || continue

        load_plan "$slug" &&
          PLAN_SOURCE=interactive && {
            clear
            run_selected_plan
          }
        ;;
      toggle)
        toggle_plan
        ;;
      delete)
        delete_plan
        ;;
      notifications)
        notification_center
        ;;
      exit)
        break
        ;;
    esac
  done
}

scheduled_entry() {
  local slug=$1

  load_plan "$slug" ||
    die "Scheduled plan not found: $slug"

  PLAN_SOURCE=scheduled

  discover_vms
  run_selected_plan
}

usage() {
  cat <<EOF
${APP_NAME} ${APP_VERSION}

Usage:
  sudo bash proxmox-vm-maintenance-wizard.sh
  ${INSTALL_PATH} --run-plan PLAN
  ${INSTALL_PATH} --help

Interactive mode creates and manages one-time and scheduled VM maintenance.
Scheduled mode is used by systemd and is not intended for manual editing.

Supported guests include Debian, Ubuntu, Kali Linux, Linux Mint, Pop!_OS,
Raspberry Pi OS, and other systems whose ID_LIKE includes debian.
EOF
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  require_root
  verify_host
  prepare_directories

  case "${1:-}" in
    --run-plan)
      [[ -n ${2:-} ]] ||
        die "--run-plan requires a plan name."

      command_exists jq ||
        die "jq is required to run scheduled maintenance."

      scheduled_entry "$2"
      ;;
    "")
      ensure_whiptail
      ensure_jq
      calculate_dialog_size
      main_menu
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
