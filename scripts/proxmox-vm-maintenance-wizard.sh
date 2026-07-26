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
readonly APP_VERSION="1.2.5"
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
declare -a RUNNING_VM_IDS=()
declare -a MAINTAINABLE_VM_IDS=()
declare -a APPLIANCE_VM_IDS=()
declare -a SELECTED_VM_IDS=()
declare -a SELECTED_TASKS=()
declare -a SELECTED_PROVIDERS=()
declare -a PROFILE_TASKS=()
declare -a RESULT_LINES=()
declare -a DETAIL_LINES=()

declare -A VM_NAME=()
declare -A VM_STATUS=()
declare -A VM_AGENT=()
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
PLAN_SEVERITIES="info warning error critical"
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
EXIT_REQUESTED=no

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

shell_quote() {
  printf '%q' "$1"
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

urlencode() {
  local value=$1 out="" char hex i
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}
    case "$char" in
      [a-zA-Z0-9.~_-]) out+=$char ;;
      ' ') out+="%20" ;;
      *)
        printf -v hex '%%%02X' "'$char"
        out+=$hex
        ;;
    esac
  done
  printf '%s' "$out"
}

truncate_text() {
  local value=$1 limit=$2
  if ((${#value} <= limit)); then
    printf '%s' "$value"
  else
    printf '%s\n[Report shortened; full report is stored on the Proxmox host.]' \
      "${value:0:$((limit - 70))}"
  fi
}

array_contains() {
  local needle=$1 item
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
  command_exists qm || die "The qm command was not found. Run this on Proxmox VE."
  [[ -d /etc/pve ]] || die "/etc/pve was not found. Run this on Proxmox VE."
  command_exists curl || die "curl is required."
  command_exists systemctl || die "systemd is required."
  command_exists timeout || die "GNU timeout is required (normally provided by coreutils)."
}

calculate_dialog_size() {
  local rows=24 cols=80
  if command_exists tput; then
    rows=$(tput lines 2>/dev/null || printf 24)
    cols=$(tput cols 2>/dev/null || printf 80)
  fi
  [[ $rows =~ ^[0-9]+$ ]] || rows=24
  [[ $cols =~ ^[0-9]+$ ]] || cols=80
  (( rows >= 18 && cols >= 58 )) ||
    die "Enlarge the terminal to at least 18 rows by 58 columns."
  DIALOG_HEIGHT=$((rows - 4))
  DIALOG_WIDTH=$((cols - 4))
  (( DIALOG_HEIGHT > 30 )) && DIALOG_HEIGHT=30
  (( DIALOG_WIDTH > 96 )) && DIALOG_WIDTH=96
  LIST_HEIGHT=$((DIALOG_HEIGHT - 9))
  (( LIST_HEIGHT < 6 )) && LIST_HEIGHT=6
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
    *) die "whiptail is required." ;;
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
  whiptail --title "$APP_NAME" --msgbox "$1" 14 "$DIALOG_WIDTH"
}

input_box() {
  whiptail --title "$APP_NAME" --inputbox "$1" 12 "$DIALOG_WIDTH" "${2:-}" \
    3>&1 1>&2 2>&3
}

password_box() {
  whiptail --title "$APP_NAME" --passwordbox "$1" 12 "$DIALOG_WIDTH" \
    3>&1 1>&2 2>&3
}

yesno() {
  whiptail --title "$APP_NAME" --defaultno --yesno "$1" 14 "$DIALOG_WIDTH"
}

install_self() {
  local source=${BASH_SOURCE[0]}
  [[ -r $source ]] || die "The running script cannot be copied for scheduling."
  install -m 755 "$source" "$INSTALL_PATH"
}

discover_vms() {
  VM_IDS=()
  RUNNING_VM_IDS=()
  MAINTAINABLE_VM_IDS=()
  APPLIANCE_VM_IDS=()
  local vmid name status
  while read -r vmid name status; do
    [[ $vmid =~ ^[0-9]+$ ]] || continue
    VM_IDS+=("$vmid")
    VM_NAME["$vmid"]=${name:-unnamed-vm}
    VM_STATUS["$vmid"]=${status:-unknown}
    VM_AGENT["$vmid"]="unknown"
    [[ $status == running ]] && RUNNING_VM_IDS+=("$vmid")
    detect_appliance_vm "$vmid"
    if [[ -n ${VM_APPLIANCE[$vmid]:-} ]]; then
      APPLIANCE_VM_IDS+=("$vmid")
    else
      MAINTAINABLE_VM_IDS+=("$vmid")
    fi
  done < <(qm list 2>/dev/null | awk 'NR>1 {print $1, $2, $3}' | sort -n)
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

  # Use QEMU Guest Agent OS information when available. Name matching above
  # still protects appliance VMs whose guest agent is unavailable.
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

show_appliance_notice() {
  ((${#APPLIANCE_VM_IDS[@]})) || return

  local vmid detected=""
  for vmid in "${APPLIANCE_VM_IDS[@]}"; do
    detected+=$'\n'
    detected+="VM ${vmid}: ${VM_NAME[$vmid]} (${VM_APPLIANCE[$vmid]})"
  done

  whiptail --title "Appliance VMs Excluded" --msgbox \
    "The following appliance VMs were detected and have been removed from the maintenance list:
${detected}

They must be maintained through their own supported interfaces:

Home Assistant OS:
Settings > System > Updates
https://www.home-assistant.io/common-tasks/os/

OPNsense:
System > Firmware > Status
https://docs.opnsense.org/manual/updates.html

This wizard will not run APT, cleanup, trim, or Docker maintenance inside these VMs." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
}

agent_available() {
  local vmid=$1
  [[ ${VM_STATUS[$vmid]:-} == running ]] || return 1
  if qm agent "$vmid" ping >/dev/null 2>&1; then
    VM_AGENT["$vmid"]="ready"
    return 0
  fi
  VM_AGENT["$vmid"]="unavailable"
  return 1
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

  if (( transport_exit != 0 )); then
    printf '%s\n' "$response" >&2
    return 125
  fi

  if ! printf '%s' "$response" | jq -e 'type == "object"' >/dev/null 2>&1; then
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

  [[ $guest_exit =~ ^[0-9]+$ ]] ||
    return 125

  if (( guest_exit > 255 )); then
    return 255
  fi

  return "$guest_exit"
}

guest_capture() {
  local vmid=$1 command=$2
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
  local vmid=$1 waited=0
  qm start "$vmid" >/dev/null || return 1
  while (( waited < 120 )); do
    VM_STATUS["$vmid"]=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    if [[ ${VM_STATUS[$vmid]} == running ]] && agent_available "$vmid"; then
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
  local waited=0 vmid target all_stopped

  ((${#SHUTDOWN_PENDING[@]})) || return

  printf 'Verifying temporarily started VMs are shutting down...\n'

  while (( waited < SHUTDOWN_TIMEOUT )); do
    all_stopped=yes

    for vmid in "${!SHUTDOWN_PENDING[@]}"; do
      if [[ $(qm status "$vmid" 2>/dev/null | awk '{print $2}') == stopped ]]; then
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
    DETAIL_LINES+=("VM ${vmid}: shutdown was requested but it did not stop within ${SHUTDOWN_TIMEOUT} seconds")
    TARGET_FAILED["$target"]=$(( ${TARGET_FAILED[$target]:-0} + 1 ))
    TOTAL_FAILED=$((TOTAL_FAILED+1))
  done
}

choose_vms() {
  discover_vms
  ((${#VM_IDS[@]})) || { msg "No VMs were detected on this node."; return 1; }
  show_appliance_notice
  ((${#MAINTAINABLE_VM_IDS[@]})) || {
    msg "No eligible VMs remain. Home Assistant OS and OPNsense must be maintained through their own web interfaces."
    return 1
  }
  local -a items=()
  local vmid state output tag
  for vmid in "${MAINTAINABLE_VM_IDS[@]}"; do
    state=OFF
    [[ ${VM_STATUS[$vmid]} == running ]] && state=ON
    items+=("$vmid" "${VM_NAME[$vmid]} [${VM_STATUS[$vmid]}]" "$state")
  done
  output=$(whiptail --title "Select Virtual Machines" --separate-output \
    --checklist "Space: select/unselect. Running Debian-family VMs are selected by default." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" "${items[@]}" \
    3>&1 1>&2 2>&3) || return 1
  SELECTED_VM_IDS=()
  while IFS= read -r tag; do
    [[ $tag =~ ^[0-9]+$ ]] && SELECTED_VM_IDS+=("$tag")
  done <<<"$output"
  ((${#SELECTED_VM_IDS[@]})) || { msg "Select at least one VM."; return 1; }
}

choose_stopped_policies() {
  local vmid choice
  for vmid in "${SELECTED_VM_IDS[@]}"; do
    if [[ ${VM_STATUS[$vmid]} == running ]]; then
      STOPPED_POLICY["$vmid"]="running"
      continue
    fi
    choice=$(whiptail --title "Stopped VM ${vmid}" --default-item skip --menu \
      "${VM_NAME[$vmid]} is stopped. Choose a policy." \
      17 "$DIALOG_WIDTH" 3 \
      skip "Skip this VM" \
      temporary "Start, maintain, then shut down" \
      leave-running "Start, maintain, and leave running" \
      3>&1 1>&2 2>&3) || choice=skip
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
      PROFILE_TASKS=(apt-update apt-upgrade apt-autoremove apt-clean)
      ;;
    monthly)
      PROFILE_TASKS=(apt-update apt-upgrade apt-autoremove apt-clean journal-clean temp-clean fstrim)
      ;;
    docker)
      PROFILE_TASKS=(apt-update apt-upgrade apt-autoremove apt-clean docker-prune)
      ;;
    full)
      PROFILE_TASKS=(apt-update apt-upgrade apt-autoremove apt-clean journal-clean temp-clean fstrim docker-prune)
      ;;
    custom) PROFILE_TASKS=(apt-update) ;;
  esac
}

profile_state() {
  array_contains "$1" "${PROFILE_TASKS[@]}" && printf ON || printf OFF
}

choose_tasks() {
  local output task
  output=$(whiptail --title "Select Maintenance Tasks" --separate-output \
    --checklist "Choose what maintenance should run. Space selects or unselects." \
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
    3>&1 1>&2 2>&3) || return 1
  SELECTED_TASKS=()
  while IFS= read -r task; do
    [[ -n $task ]] && SELECTED_TASKS+=("$task")
  done <<<"$output"
  ((${#SELECTED_TASKS[@]})) || { msg "Select at least one task."; return 1; }
}

task_label() {
  case "$1" in
    apt-update) printf "Refresh package lists" ;;
    apt-check) printf "Report available upgrades" ;;
    apt-upgrade) printf "Install package upgrades" ;;
    apt-autoremove) printf "Remove unused packages" ;;
    apt-clean) printf "Clean APT cache" ;;
    journal-clean) printf "Clean old journal entries" ;;
    temp-clean) printf "Clean temporary files" ;;
    fstrim) printf "Trim guest filesystems" ;;
    docker-prune) printf "Clean unused Docker data" ;;
    *) printf '%s' "$1" ;;
  esac
}

task_command() {
  case "$1" in
    apt-update) printf 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update' ;;
    apt-check) printf 'apt-get -s upgrade | awk '\''/^Inst /{count++} END{printf "Available upgrades: %%d\\n", count+0}'\''' ;;
    apt-upgrade) printf 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -y upgrade' ;;
    apt-autoremove) printf 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -y autoremove' ;;
    apt-clean) printf 'apt-get -o DPkg::Lock::Timeout=120 clean' ;;
    journal-clean) printf 'journalctl --vacuum-time=%q' "$JOURNAL_RETENTION" ;;
    temp-clean) printf 'systemd-tmpfiles --clean' ;;
    fstrim) printf 'fstrim -av' ;;
    docker-prune) printf 'docker system prune -f' ;;
    *) return 1 ;;
  esac
}

task_requirement() {
  case "$1" in
    journal-clean) printf 'journalctl' ;;
    temp-clean) printf 'systemd-tmpfiles' ;;
    fstrim) printf 'fstrim' ;;
    docker-prune) printf 'docker' ;;
    *) return 1 ;;
  esac
}

guest_has_command() {
  local vmid=$1 command_name=$2
  guest_exec "$vmid" "command -v ${command_name} >/dev/null 2>&1" \
    >/dev/null 2>&1
}

provider_paths() {
  find "$PROVIDER_DIR" -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | sort
}

provider_names() {
  local file
  while IFS= read -r file; do
    [[ -n $file ]] && basename "$file" .conf
  done < <(provider_paths)
}

providers_exist() {
  compgen -G "${PROVIDER_DIR}/*.conf" >/dev/null
}

provider_config_write() {
  local slug=$1 name=$2 type=$3 severities=$4 report=$5
  shift 5
  local path="${PROVIDER_DIR}/${slug}.conf" pair key value
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
  local output severity
  output=$(whiptail --title "Notification Severities" --separate-output \
    --checklist "Choose which severities this provider receives." \
    17 "$DIALOG_WIDTH" 4 \
    info "Successful and informational reports" ON \
    warning "Completed with skipped tasks or warnings" ON \
    error "Maintenance task failures" ON \
    critical "Critical failures" ON \
    3>&1 1>&2 2>&3) || return 1
  local values=()
  while IFS= read -r severity; do [[ -n $severity ]] && values+=("$severity"); done <<<"$output"
  ((${#values[@]})) || return 1
  printf '%s' "${values[*]}"
}

choose_report_format() {
  whiptail --title "Report Format" --menu "Choose the report detail." \
    15 "$DIALOG_WIDTH" 2 \
    summary "Short result and totals" \
    detailed "Per-VM task results and totals" \
    3>&1 1>&2 2>&3
}

ensure_apprise() {
  command_exists apprise && return 0
  yesno "Apprise is not installed. Install it now with apt and pipx?" || return 1
  apt-get update &&
    DEBIAN_FRONTEND=noninteractive apt-get install -y pipx &&
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install apprise
}

add_provider() {
  local type name slug severities report value1 value2 value3 value4
  type=$(whiptail --title "Add Notification Provider" --menu \
    "Choose a provider. No SweenLab backend is used." \
    24 "$DIALOG_WIDTH" 10 \
    none "No Notifications (do not add a provider)" \
    discord "Discord incoming webhook" \
    slack "Slack incoming webhook" \
    telegram "Telegram bot" \
    ntfy "ntfy server and topic" \
    gotify "Gotify server and application token" \
    pushover "Pushover application and user tokens" \
    smtp "SMTP email" \
    webhook "Generic JSON webhook" \
    apprise "Advanced Apprise URL" \
    3>&1 1>&2 2>&3) || return
  [[ $type == none ]] && return

  if [[ $type == pushover ]]; then
    while [[ -z ${value1:-} ]]; do
      value1=$(input_box \
        "Paste the Pushover Application API Token.\n\nThe token will be visible while you enter it and stored in a root-only file.") ||
        return
      [[ -n $value1 ]] || msg "The Pushover Application API Token cannot be blank.\n\nPress Enter to try again."
    done
    while [[ -z ${value2:-} ]]; do
      value2=$(input_box \
        "Paste the Pushover User Key or Group Key.\n\nThe key will be visible while you enter it and stored in a root-only file.") ||
        return
      [[ -n $value2 ]] || msg "The Pushover User Key cannot be blank.\n\nPress Enter to try again."
    done
  fi

  name=$(input_box "Friendly provider name:" "${type}-notifications") || return
  slug=$(slugify "$name")
  [[ -n $slug ]] || { msg "The provider name needs a letter or number."; return; }
  severities=$(choose_severities) || return
  report=$(choose_report_format) || return
  case "$type" in
    discord|slack|webhook)
      value1=$(password_box "Paste the webhook URL:") || return
      provider_config_write "$slug" "$name" "$type" "$severities" "$report" "WEBHOOK_URL=$value1"
      ;;
    telegram)
      value1=$(password_box "Telegram bot token:") || return
      value2=$(input_box "Telegram chat ID:") || return
      provider_config_write "$slug" "$name" "$type" "$severities" "$report" \
        "BOT_TOKEN=$value1" "CHAT_ID=$value2"
      ;;
    ntfy)
      value1=$(input_box "ntfy server URL:" "https://ntfy.sh") || return
      value2=$(input_box "ntfy topic:") || return
      value3=$(input_box "Optional access token (leave blank if unused):") || return
      provider_config_write "$slug" "$name" "$type" "$severities" "$report" \
        "SERVER_URL=$value1" "TOPIC=$value2" "ACCESS_TOKEN=$value3"
      ;;
    gotify)
      value1=$(input_box "Gotify server URL:") || return
      value2=$(password_box "Gotify application token:") || return
      provider_config_write "$slug" "$name" "$type" "$severities" "$report" \
        "SERVER_URL=$value1" "APP_TOKEN=$value2"
      ;;
    pushover)
      provider_config_write "$slug" "$name" "$type" "$severities" "$report" \
        "APP_TOKEN=$value1" "USER_KEY=$value2"
      ;;
    smtp)
      value1=$(input_box "SMTP URL (example smtps://smtp.example.com:465):") || return
      value2=$(input_box "SMTP username:") || return
      value3=$(password_box "SMTP password:") || return
      value4=$(input_box "From and recipient, separated by a comma (from@example.com,to@example.com):") || return
      provider_config_write "$slug" "$name" "$type" "$severities" "$report" \
        "SMTP_URL=$value1" "SMTP_USER=$value2" "SMTP_PASS=$value3" \
        "MAIL_FROM=${value4%%,*}" "MAIL_TO=${value4#*,}"
      ;;
    apprise)
      ensure_apprise || { msg "Apprise was not installed."; return; }
      value1=$(password_box "Apprise notification URL:") || return
      provider_config_write "$slug" "$name" "$type" "$severities" "$report" "APPRISE_URL=$value1"
      ;;
  esac
  if test_provider "$slug"; then
    msg "Test notification sent. Provider saved."
  else
    msg "The provider was saved, but its test failed. Edit or remove it from Notification Settings."
  fi
}

load_provider() {
  local slug=$1 path="${PROVIDER_DIR}/${slug}.conf"
  [[ -r $path ]] || return 1
  unset PROVIDER_NAME PROVIDER_TYPE PROVIDER_SEVERITIES PROVIDER_REPORT
  unset WEBHOOK_URL BOT_TOKEN CHAT_ID SERVER_URL TOPIC ACCESS_TOKEN APP_TOKEN USER_KEY
  unset SMTP_URL SMTP_USER SMTP_PASS MAIL_FROM MAIL_TO APPRISE_URL
  # Root-owned configuration generated by this script.
  # shellcheck disable=SC1090
  source "$path"
}

send_provider() {
  local slug=$1 title=$2 body=$3 severity=$4 force=${5:-no}
  load_provider "$slug" || return 1
  if [[ $force != yes ]]; then
    array_contains "$severity" ${PROVIDER_SEVERITIES:-} || return 0
  fi
  local payload auth=() mail message
  case "$PROVIDER_TYPE" in
    discord)
      body=$(truncate_text "$body" 1750)
      message="${title}"$'\n\n'"${body}"
      payload="{\"username\":\"SweenLab\",\"content\":\"$(json_escape "$message")\"}"
      curl -fsS --connect-timeout 5 --max-time 20 \
        -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null
      ;;
    slack)
      body=$(truncate_text "$body" 35000)
      message="*${title}*"$'\n'"${body}"
      payload="{\"text\":\"$(json_escape "$message")\"}"
      curl -fsS --connect-timeout 5 --max-time 20 \
        -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null
      ;;
    telegram)
      body=$(truncate_text "$body" 3800)
      curl -fsS --connect-timeout 5 --max-time 20 -X POST \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${title}"$'\n\n'"${body}" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" >/dev/null
      ;;
    ntfy)
      body=$(truncate_text "$body" 3500)
      [[ -n ${ACCESS_TOKEN:-} ]] && auth=(-H "Authorization: Bearer ${ACCESS_TOKEN}")
      curl -fsS --connect-timeout 5 --max-time 20 "${auth[@]}" -H "Title: ${title}" \
        -H "Priority: $([[ $severity == critical ]] && printf 5 || printf 3)" \
        -d "$body" "${SERVER_URL%/}/${TOPIC}" >/dev/null
      ;;
    gotify)
      body=$(truncate_text "$body" 15000)
      curl -fsS --connect-timeout 5 --max-time 20 -X POST \
        -F "title=$title" -F "message=$body" \
        -F "priority=$([[ $severity == critical ]] && printf 8 || printf 4)" \
        "${SERVER_URL%/}/message?token=${APP_TOKEN}" >/dev/null
      ;;
    pushover)
      body=$(truncate_text "$body" 900)
      curl -fsS --connect-timeout 5 --max-time 20 -X POST \
        --data-urlencode "token=${APP_TOKEN}" \
        --data-urlencode "user=${USER_KEY}" \
        --data-urlencode "title=${title}" \
        --data-urlencode "message=${body}" \
        -d "priority=$([[ $severity == critical ]] && printf 1 || printf 0)" \
        https://api.pushover.net/1/messages.json >/dev/null
      ;;
    smtp)
      mail=$(mktemp)
      {
        printf 'From: %s\r\n' "$MAIL_FROM"
        printf 'To: %s\r\n' "$MAIL_TO"
        printf 'Subject: %s\r\n' "$title"
        printf 'Content-Type: text/plain; charset=UTF-8\r\n\r\n%s\r\n' "$body"
      } >"$mail"
      curl -fsS --connect-timeout 5 --max-time 30 --url "$SMTP_URL" --ssl-reqd \
        --user "${SMTP_USER}:${SMTP_PASS}" --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" --upload-file "$mail" >/dev/null
      rm -f "$mail"
      ;;
    webhook)
      payload="{\"source\":\"SweenLab\",\"title\":\"$(json_escape "$title")\",\"severity\":\"$severity\",\"message\":\"$(json_escape "$body")\"}"
      curl -fsS --connect-timeout 5 --max-time 20 \
        -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null
      ;;
    apprise)
      command_exists apprise || return 1
      timeout 30 apprise -b "$body" -t "$title" "$APPRISE_URL" >/dev/null
      ;;
    *) return 1 ;;
  esac
}

test_provider() {
  send_provider "$1" "SweenLab Test Notification" \
    "The Proxmox VM Maintenance Wizard can reach this provider." info yes
}

select_existing_provider() {
  local -a items=()
  local slug
  while IFS= read -r slug; do
    [[ -n $slug ]] && items+=("$slug" "$slug")
  done < <(provider_names)
  ((${#items[@]})) || { msg "No providers are configured."; return 1; }
  whiptail --title "Notification Providers" --menu "Choose a provider." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" "${items[@]}" \
    3>&1 1>&2 2>&3
}

notification_center() {
  local action slug
  while true; do
    action=$(whiptail --title "Notification Settings" --menu \
      "Providers are stored locally with root-only permissions." \
      20 "$DIALOG_WIDTH" 6 \
      add "Add a provider" \
      test "Test a provider" \
      view "View configured provider names" \
      edit "Replace a provider's configuration" \
      remove "Remove a provider" \
      back "Return to the main menu" \
      3>&1 1>&2 2>&3) || return
    case "$action" in
      add) add_provider ;;
      test)
        if ! providers_exist; then
          yesno "No notification providers are configured.\n\nAdd one now?" && add_provider
          continue
        fi
        slug=$(select_existing_provider) || continue
        test_provider "$slug" && msg "Test sent successfully." || msg "The test failed."
        ;;
      view)
        msg "Configured providers:\n\n$(provider_names | sed 's/^/- /')"
        ;;
      edit)
        slug=$(select_existing_provider) || continue
        rm -f "${PROVIDER_DIR}/${slug}.conf"
        add_provider
        ;;
      remove)
        slug=$(select_existing_provider) || continue
        yesno "Remove provider '${slug}'?" && rm -f "${PROVIDER_DIR}/${slug}.conf"
        ;;
      back) return ;;
    esac
  done
}

choose_plan_notifications() {
  local choice output slug
  choice=$(whiptail --title "Notifications" --menu \
    "Choose whether this maintenance plan sends reports." \
    16 "$DIALOG_WIDTH" 2 \
    none "No Notifications" \
    configured "Use selected configured providers" \
    3>&1 1>&2 2>&3) || return 1
  PLAN_NOTIFY=$choice
  SELECTED_PROVIDERS=()
  [[ $choice == none ]] && return
  local -a items=()
  while IFS= read -r slug; do
    [[ -n $slug ]] && items+=("$slug" "$slug" ON)
  done < <(provider_names)
  if ((${#items[@]} == 0)); then
    yesno "No providers are configured.\n\nOpen Notification Settings now?" &&
      notification_center
    return 1
  fi
  output=$(whiptail --title "Plan Notification Providers" --separate-output \
    --checklist "Choose one or more providers." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" "${items[@]}" \
    3>&1 1>&2 2>&3) || return 1
  while IFS= read -r slug; do [[ -n $slug ]] && SELECTED_PROVIDERS+=("$slug"); done <<<"$output"
  ((${#SELECTED_PROVIDERS[@]})) || return 1
}

detect_timezone() {
  timedatectl show --property=Timezone --value 2>/dev/null ||
    cat /etc/timezone 2>/dev/null ||
    printf UTC
}

choose_calendar() {
  local frequency time day timezone
  timezone=$(detect_timezone)
  frequency=$(whiptail --title "Schedule Frequency" --menu "Choose a schedule." \
    18 "$DIALOG_WIDTH" 4 \
    daily "Every day" weekly "Once each week" monthly "Once each month" custom "Custom OnCalendar value" \
    3>&1 1>&2 2>&3) || return 1
  PLAN_TIMEZONE=$(input_box "Timezone (IANA name):" "$timezone") || return 1
  case "$frequency" in
    daily)
      time=$(input_box "Time (24-hour HH:MM):" "03:00") || return 1
      PLAN_CALENDAR="*-*-* ${time}:00 ${PLAN_TIMEZONE}"
      ;;
    weekly)
      day=$(whiptail --title "Day" --menu "Choose a weekday." 18 60 7 \
        Mon Monday Tue Tuesday Wed Wednesday Thu Thursday Fri Friday Sat Saturday Sun Sunday \
        3>&1 1>&2 2>&3) || return 1
      time=$(input_box "Time (24-hour HH:MM):" "03:00") || return 1
      PLAN_CALENDAR="${day} *-*-* ${time}:00 ${PLAN_TIMEZONE}"
      ;;
    monthly)
      day=$(input_box "Day of month (1-28):" "1") || return 1
      [[ $day =~ ^([1-9]|1[0-9]|2[0-8])$ ]] || return 1
      time=$(input_box "Time (24-hour HH:MM):" "03:00") || return 1
      PLAN_CALENDAR="*-*-${day} ${time}:00 ${PLAN_TIMEZONE}"
      ;;
    custom)
      PLAN_CALENDAR=$(input_box "systemd OnCalendar value:" "*-*-* 03:00:00 ${PLAN_TIMEZONE}") || return 1
      ;;
  esac
  systemd-analyze calendar "$PLAN_CALENDAR" >/dev/null 2>&1 || {
    msg "The schedule is not valid:\n\n${PLAN_CALENDAR}"
    return 1
  }
}

write_plan() {
  local path="${PLAN_DIR}/${PLAN_SLUG}.conf" vmid
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
      printf 'STOPPED_%s=%q\n' "$vmid" "${STOPPED_POLICY[$vmid]:-$PLAN_STOPPED_DEFAULT}"
    done
  } >"$path"
  chmod 600 "$path"
}

load_plan() {
  local slug=$1 path="${PLAN_DIR}/${slug}.conf" vmid var
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
  while IFS= read -r slug; do [[ -n $slug ]] && items+=("$slug" "$slug"); done < <(plan_names)
  ((${#items[@]})) || { msg "No scheduled plans exist."; return 1; }
  whiptail --title "Scheduled Plans" --menu "Choose a plan." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" "${items[@]}" \
    3>&1 1>&2 2>&3
}

write_units() {
  local slug=$1 conf="${PLAN_DIR}/${slug}.conf"
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
    systemctl enable --now "${UNIT_PREFIX}-${slug}.timer"
  else
    systemctl disable --now "${UNIT_PREFIX}-${slug}.timer" >/dev/null 2>&1 || true
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
    set_profile full
    choose_tasks || return
    choose_plan_notifications || return
    PLAN_REPORT=$(choose_report_format) || return
    choose_calendar || return
    PLAN_NAME=$(input_box "Schedule name:" "Weekly VM Maintenance") || return
    PLAN_SLUG=$(slugify "$PLAN_NAME")
    PLAN_ENABLED=yes
  fi
  if [[ -n $existing ]]; then
    PLAN_NAME=$(input_box "Schedule name:" "$PLAN_NAME") || return
    PLAN_SLUG=$existing
    choose_vms || return
    choose_stopped_policies
    PROFILE_TASKS=("${SELECTED_TASKS[@]}")
    choose_tasks || return
    choose_plan_notifications || return
    PLAN_REPORT=$(choose_report_format) || return
    choose_calendar || return
  fi
  [[ -n $PLAN_SLUG ]] || { msg "A valid schedule name is required."; return; }
  write_plan
  write_units "$PLAN_SLUG"
  msg "Scheduled plan saved:\n\n${PLAN_NAME}\n${PLAN_CALENDAR}"
}

view_plans() {
  local output
  output=$(systemctl list-timers --all "${UNIT_PREFIX}-*.timer" --no-pager 2>&1 || true)
  msg "$output"
}

toggle_plan() {
  local slug state
  slug=$(select_plan) || return
  load_plan "$slug" || return
  if systemctl is-enabled --quiet "${UNIT_PREFIX}-${slug}.timer"; then
    state=no
    systemctl disable --now "${UNIT_PREFIX}-${slug}.timer" >/dev/null
  else
    state=yes
    systemctl enable --now "${UNIT_PREFIX}-${slug}.timer" >/dev/null
  fi
  PLAN_ENABLED=$state
  write_plan
  msg "Plan '${slug}' is now $([[ $state == yes ]] && printf enabled || printf disabled)."
}

delete_plan() {
  local slug
  slug=$(select_plan) || return
  yesno "Delete scheduled plan '${slug}'?" || return
  systemctl disable --now "${UNIT_PREFIX}-${slug}.timer" >/dev/null 2>&1 || true
  rm -f "${SYSTEMD_DIR}/${UNIT_PREFIX}-${slug}.timer" \
    "${SYSTEMD_DIR}/${UNIT_PREFIX}-${slug}.service" \
    "${PLAN_DIR}/${slug}.conf"
  systemctl daemon-reload
  msg "Plan '${slug}' was deleted."
}

prepare_run() {
  local label=$1
  RUN_STARTED=$(date +%s)
  RUN_DIR="${LOG_ROOT}/$(date '+%Y%m%d-%H%M%S')-${label}"
  install -d -m 750 "$RUN_DIR"
  RESULT_LINES=()
  DETAIL_LINES=()
  TARGET_OK=()
  TARGET_FAILED=()
  TARGET_SKIPPED=()
  TARGET_RECLAIMED=()
  TEMP_STARTED=()
  SHUTDOWN_PENDING=()
  APT_READY=()
  TOTAL_OK=0 TOTAL_FAILED=0 TOTAL_SKIPPED=0 CURRENT_STEP=0
  local count=0 vmid
  for vmid in "${SELECTED_VM_IDS[@]}"; do
    [[ ${STOPPED_POLICY[$vmid]:-skip} == skip && ${VM_STATUS[$vmid]:-stopped} != running ]] || count=$((count+1))
  done
  TOTAL_STEPS=$((count * ${#SELECTED_TASKS[@]}))
}

run_task() {
  local vmid=$1 task=$2 target="vm-${vmid}" label command log before after rc
  local requirement failure_reason
  label=$(task_label "$task")
  command=$(task_command "$task") || return
  log="${RUN_DIR}/${target}-${task}.log"
  CURRENT_STEP=$((CURRENT_STEP+1))
  printf '[%d/%d] VM %s (%s): %s... ' "$CURRENT_STEP" "$TOTAL_STEPS" "$vmid" "${VM_NAME[$vmid]}" "$label"

  if [[ $task == apt-check || $task == apt-upgrade || $task == apt-autoremove || $task == apt-clean ]] &&
     [[ ${APT_READY[$vmid]:-yes} == no ]]; then
    printf 'SKIPPED\n'
    TARGET_SKIPPED["$target"]=$(( ${TARGET_SKIPPED[$target]:-0} + 1 ))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
    DETAIL_LINES+=("VM ${vmid} ${VM_NAME[$vmid]}: ${label} - SKIPPED because package-list refresh failed")
    return
  fi

  if requirement=$(task_requirement "$task" 2>/dev/null) &&
     ! guest_has_command "$vmid" "$requirement"; then
    printf 'SKIPPED (%s is not installed)\n' "$requirement"
    TARGET_SKIPPED["$target"]=$(( ${TARGET_SKIPPED[$target]:-0} + 1 ))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
    DETAIL_LINES+=("VM ${vmid} ${VM_NAME[$vmid]}: ${label} - SKIPPED; ${requirement} is not installed")
    return
  fi

  before=$(guest_capture "$vmid" "df -B1 --output=avail / | tail -1" | tr -dc '0-9')
  guest_exec "$vmid" "$command" >"$log" 2>&1
  rc=$?
  after=$(guest_capture "$vmid" "df -B1 --output=avail / | tail -1" | tr -dc '0-9')
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
    TOTAL_OK=$((TOTAL_OK+1))
    DETAIL_LINES+=("VM ${vmid} ${VM_NAME[$vmid]}: ${label} - OK")
  else
    printf 'FAILED\n'
    TARGET_FAILED["$target"]=$(( ${TARGET_FAILED[$target]:-0} + 1 ))
    TOTAL_FAILED=$((TOTAL_FAILED+1))
    failure_reason=$(
      tail -n 5 "$log" 2>/dev/null |
        tr '\n' ' ' |
        sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' |
        cut -c1-300
    )
    if [[ -n $failure_reason ]]; then
      DETAIL_LINES+=("VM ${vmid} ${VM_NAME[$vmid]}: ${label} - FAILED: ${failure_reason} (full log: ${log})")
    else
      DETAIL_LINES+=("VM ${vmid} ${VM_NAME[$vmid]}: ${label} - FAILED (see ${log})")
    fi
  fi
  if [[ $before =~ ^[0-9]+$ && $after =~ ^[0-9]+$ ]]; then
    TARGET_RECLAIMED["$target"]=$(( ${TARGET_RECLAIMED[$target]:-0} + after - before ))
  fi
}

handle_interruption() {
  printf '\nMaintenance was interrupted. Requesting shutdowns for temporarily started VMs...\n' >&2
  request_remaining_shutdowns
  wait_for_pending_shutdowns
  exit 130
}

trap handle_interruption INT TERM

run_selected_plan() {
  discover_vms
  prepare_run "${PLAN_SLUG:-one-time}"
  local vmid task policy target
  for vmid in "${SELECTED_VM_IDS[@]}"; do
    target="vm-${vmid}"
    if ! array_contains "$vmid" "${VM_IDS[@]}"; then
      TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
      DETAIL_LINES+=("VM ${vmid}: no longer exists on this node - SKIPPED")
      continue
    fi
    if [[ -n ${VM_APPLIANCE[$vmid]:-} ]]; then
      TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
      TARGET_SKIPPED["$target"]=1
      DETAIL_LINES+=("VM ${vmid} ${VM_NAME[$vmid]}: ${VM_APPLIANCE[$vmid]} appliance - SKIPPED; use its supported web interface")
      continue
    fi
    policy=${STOPPED_POLICY[$vmid]:-skip}
    if [[ ${VM_STATUS[$vmid]} != running ]]; then
      case "$policy" in
        skip)
          TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
          TARGET_SKIPPED["$target"]=1
          DETAIL_LINES+=("VM ${vmid} ${VM_NAME[$vmid]}: stopped - SKIPPED")
          continue
          ;;
        temporary|leave-running)
          printf 'Starting VM %s (%s)...\n' "$vmid" "${VM_NAME[$vmid]}"
          if ! start_vm "$vmid"; then
            TOTAL_FAILED=$((TOTAL_FAILED+1))
            TARGET_FAILED["$target"]=1
            DETAIL_LINES+=("VM ${vmid}: failed to start or QEMU Guest Agent did not become ready")
            continue
          fi
          TEMP_STARTED["$vmid"]=$policy
          ;;
      esac
    elif ! agent_available "$vmid"; then
      TOTAL_FAILED=$((TOTAL_FAILED+1))
      TARGET_FAILED["$target"]=1
      DETAIL_LINES+=("VM ${vmid}: QEMU Guest Agent unavailable")
      continue
    fi
    if ! guest_os_supported "$vmid"; then
      TOTAL_SKIPPED=$((TOTAL_SKIPPED+1))
      TARGET_SKIPPED["$target"]=1
      DETAIL_LINES+=("VM ${vmid}: unsupported guest OS; a Debian-family system is required")
      continue
    fi
    APT_READY["$vmid"]=yes
    for task in "${SELECTED_TASKS[@]}"; do run_task "$vmid" "$task"; done

    if [[ ${TEMP_STARTED[$vmid]:-} == temporary ]]; then
      request_vm_shutdown "$vmid"
    fi
  done

  request_remaining_shutdowns
  wait_for_pending_shutdowns
  finish_report
}

finish_report() {
  local ended elapsed severity title summary detailed slug body
  ended=$(date +%s)
  elapsed=$((ended-RUN_STARTED))
  if ((TOTAL_FAILED>0)); then severity=error
  elif ((TOTAL_SKIPPED>0)); then severity=warning
  else severity=info
  fi
  title="SweenLab VM Maintenance: $([[ $severity == info ]] && printf Complete || printf Attention)"
  summary=$(printf 'Plan: %s\nSuccessful tasks: %d\nFailed tasks: %d\nSkipped VMs/tasks: %d\nRuntime: %dm %ds\nLogs: %s' \
    "${PLAN_NAME:-One-time Maintenance}" "$TOTAL_OK" "$TOTAL_FAILED" "$TOTAL_SKIPPED" \
    "$((elapsed/60))" "$((elapsed%60))" "$RUN_DIR")
  detailed="${summary}"$'\n\n'"$(printf '%s\n' "${DETAIL_LINES[@]}")"
  printf '%s\n' "$detailed" | tee "${RUN_DIR}/report.txt"
  if [[ ${PLAN_NOTIFY:-none} == configured ]]; then
    for slug in "${SELECTED_PROVIDERS[@]}"; do
      load_provider "$slug" || continue
      body=$summary
      [[ ${PROVIDER_REPORT:-$PLAN_REPORT} == detailed ]] && body=$detailed
      send_provider "$slug" "$title" "$body" "$severity" ||
        printf 'Notification failed: %s\n' "$slug" >>"${RUN_DIR}/notification-errors.log"
    done
  fi
  ((TOTAL_FAILED==0))
}

one_time_run() {
  local action
  local run_another

  while true; do
    PLAN_NAME="One-time VM Maintenance"
    PLAN_SLUG="one-time"
    PLAN_CALENDAR=""
    PLAN_TIMEZONE=""
    run_another=no

    choose_vms || return
    choose_stopped_policies
    set_profile full
    choose_tasks || return
    choose_plan_notifications || return
    PLAN_REPORT=$(choose_report_format) || return

    yesno "Run this one-time maintenance plan now?\n\nVMs: ${SELECTED_VM_IDS[*]}\nTasks: ${SELECTED_TASKS[*]}\nNotifications: ${PLAN_NOTIFY}" ||
      return

    clear
    run_selected_plan || true

    while true; do
      action=$(whiptail --title "Maintenance Complete" --menu \
        "Successful tasks: ${TOTAL_OK}
Failed tasks: ${TOTAL_FAILED}
Skipped VMs/tasks: ${TOTAL_SKIPPED}

What would you like to do next?" \
        21 "$DIALOG_WIDTH" 4 \
        schedule "Schedule this same maintenance plan" \
        another "Run another one-time maintenance" \
        main "Return to the main menu" \
        exit "Exit the wizard" \
        3>&1 1>&2 2>&3) || action=exit

      case "$action" in
        schedule)
          schedule_completed_run
          ;;
        another)
          run_another=yes
          break
          ;;
        main)
          return
          ;;
        exit)
          EXIT_REQUESTED=yes
          return
          ;;
      esac
    done

    [[ $run_another == yes ]] || return
  done
}

schedule_completed_run() {
  local proposed_name
  local proposed_slug

  while true; do
    proposed_name=$(input_box \
      "Name this scheduled maintenance plan:" \
      "Scheduled VM Maintenance") || return 1

    proposed_slug=$(slugify "$proposed_name")

    [[ -n $proposed_slug ]] || {
      msg "The schedule name needs at least one letter or number."
      continue
    }

    if [[ -e "${PLAN_DIR}/${proposed_slug}.conf" ||
          -e "${SYSTEMD_DIR}/${UNIT_PREFIX}-${proposed_slug}.timer" ]]; then
      msg "A scheduled plan named '${proposed_slug}' already exists.\n\nChoose a different name."
      continue
    fi

    break
  done

  PLAN_NAME=$proposed_name
  PLAN_SLUG=$proposed_slug
  PLAN_ENABLED=yes

  choose_calendar || return 1
  write_plan
  write_units "$PLAN_SLUG"

  msg "Scheduled plan created from the completed maintenance run.\n\nName: ${PLAN_NAME}\nSchedule: ${PLAN_CALENDAR}"
}

main_menu() {
  local action slug
  while true; do
    action=$(whiptail --title "$APP_NAME v${APP_VERSION}" --menu \
      "Maintain Debian-family VMs through QEMU Guest Agent." \
      22 "$DIALOG_WIDTH" 8 \
      run "Run one-time maintenance" \
      view "View scheduled plans" \
      edit "Edit a scheduled plan" \
      run-plan "Run a saved plan now" \
      toggle "Enable or disable a scheduled plan" \
      delete "Delete a scheduled plan" \
      notifications "Notification Settings" \
      exit "Exit" \
      3>&1 1>&2 2>&3) || break
    case "$action" in
      run)
        one_time_run
        [[ $EXIT_REQUESTED == yes ]] && break
        ;;
      view) view_plans ;;
      edit) slug=$(select_plan) && create_or_edit_plan "$slug" ;;
      run-plan)
        slug=$(select_plan) || continue
        load_plan "$slug" && PLAN_SOURCE=interactive && { clear; run_selected_plan; }
        ;;
      toggle) toggle_plan ;;
      delete) delete_plan ;;
      notifications) notification_center ;;
      exit) break ;;
    esac
  done
}

scheduled_entry() {
  local slug=$1
  load_plan "$slug" || die "Scheduled plan not found: $slug"
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

Interactive mode runs one-time maintenance and manages saved scheduled plans.
After a one-time run completes, the wizard can save that run as a schedule.
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
      [[ -n ${2:-} ]] || die "--run-plan requires a plan name."
      command_exists jq || die "jq is required to run scheduled maintenance."
      scheduled_entry "$2"
      ;;
    "")
      ensure_whiptail
      ensure_jq
      calculate_dialog_size
      main_menu
      ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
