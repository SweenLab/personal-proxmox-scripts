#!/usr/bin/env bash

###############################################################################
# Proxmox Host & LXC Maintenance Wizard
#
# Repository:
#   https://github.com/SweenLab/personal-proxmox-scripts
#
# Purpose:
#   Perform guided maintenance on:
#     - The local Proxmox VE host
#     - One or more locally managed LXC containers
#
# Supported LXC operating systems:
#     - Debian
#     - Ubuntu
#
# Safety:
#     - Requires root
#     - Does not reboot the host or containers
#     - Does not remove Docker volumes
#     - Does not force-stop containers
#     - Does not start stopped containers without permission
#     - Displays an execution plan before making changes
#
# License:
#   MIT
###############################################################################

set -uo pipefail

###############################################################################
# Script configuration
###############################################################################

SCRIPT_VERSION="1.1.1"

JOURNAL_RETENTION="14d"
START_TIMEOUT_SECONDS=60
SHUTDOWN_TIMEOUT_SECONDS=60

TARGET_MODE=""

DIALOG_HEIGHT=20
DIALOG_WIDTH=70
LIST_HEIGHT=10

declare -a ALL_LXC_IDS=()
declare -a RUNNING_LXC_IDS=()
declare -a SELECTED_LXC_IDS=()
declare -a SELECTED_TASKS=()

declare -A LXC_NAME=()
declare -A LXC_STATUS=()
declare -A STOPPED_ACTION=()
declare -A TEMPORARILY_RUNNING=()

declare -A TARGET_OK=()
declare -A TARGET_FAILED=()
declare -A TARGET_SKIPPED=()
declare -A SPACE_BEFORE=()
declare -A SPACE_AFTER=()

TOTAL_OK=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0

###############################################################################
# Preserve interactive input when launched through curl
###############################################################################

# This allows both of these forms to work:
#
#   bash <(curl -fsSL URL)
#
#   curl -fsSL URL | bash
#
# Without this, Bash may consume the same standard input that the interactive
# menus need.

if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
    exec </dev/tty
fi

###############################################################################
# Terminal colors
###############################################################################

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RESET="$(tput sgr0 2>/dev/null || true)"
    BOLD="$(tput bold 2>/dev/null || true)"
    RED="$(tput setaf 1 2>/dev/null || true)"
    GREEN="$(tput setaf 2 2>/dev/null || true)"
    YELLOW="$(tput setaf 3 2>/dev/null || true)"
    CYAN="$(tput setaf 6 2>/dev/null || true)"
else
    RESET=""
    BOLD=""
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
fi

###############################################################################
# General helpers
###############################################################################

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_header() {
    clear 2>/dev/null || true

    printf '%s\n' \
        "${CYAN}============================================================${RESET}"
    printf '%s\n' \
        "${BOLD}       Proxmox Host & LXC Maintenance Wizard${RESET}"
    printf '%s\n' \
        "${CYAN}============================================================${RESET}"
    printf 'Version: %s\n\n' "$SCRIPT_VERSION"
}

print_section() {
    printf '\n%s\n' "${BOLD}$1${RESET}"
    printf '%s\n\n' \
        "------------------------------------------------------------"
}

print_info() {
    printf '%s\n' "${CYAN}[INFO]${RESET} $*"
}

print_success() {
    printf '%s\n' "${GREEN}[OK]${RESET} $*"
}

print_warning() {
    printf '%s\n' "${YELLOW}[WARNING]${RESET} $*"
}

print_error() {
    printf '%s\n' "${RED}[ERROR]${RESET} $*" >&2
}

plain_yes_no() {
    local prompt="$1"
    local response

    printf '%s [y/N]: ' "$prompt"
    read -r response

    [[ "$response" =~ ^[Yy]$ ]]
}

array_contains() {
    local wanted="$1"
    shift

    local value

    for value in "$@"; do
        if [[ "$value" == "$wanted" ]]; then
            return 0
        fi
    done

    return 1
}

format_bytes() {
    local bytes="${1:-0}"

    if ! [[ "$bytes" =~ ^-?[0-9]+$ ]]; then
        printf 'Unknown'
        return
    fi

    if (( bytes < 0 )); then
        bytes=0
    fi

    if command_exists numfmt; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null ||
            printf '%s bytes' "$bytes"
    else
        printf '%s bytes' "$bytes"
    fi
}

###############################################################################
# Responsive dialog sizing
###############################################################################

calculate_dialog_size() {
    local terminal_rows=24
    local terminal_cols=80

    if command_exists tput; then
        terminal_rows="$(tput lines 2>/dev/null || printf '24')"
        terminal_cols="$(tput cols 2>/dev/null || printf '80')"
    fi

    [[ "$terminal_rows" =~ ^[0-9]+$ ]] || terminal_rows=24
    [[ "$terminal_cols" =~ ^[0-9]+$ ]] || terminal_cols=80

    if (( terminal_rows < 18 || terminal_cols < 58 )); then
        clear 2>/dev/null || true

        print_warning \
            "Your terminal window is too small for the interactive menus."

        printf '\nCurrent terminal size: %s rows by %s columns\n' \
            "$terminal_rows" \
            "$terminal_cols"

        printf 'Recommended minimum: 18 rows by 58 columns\n\n'
        printf 'Enlarge the Terminal window and run the script again.\n'

        exit 1
    fi

    DIALOG_HEIGHT=$((terminal_rows - 4))
    DIALOG_WIDTH=$((terminal_cols - 4))

    if (( DIALOG_HEIGHT > 28 )); then
        DIALOG_HEIGHT=28
    fi

    if (( DIALOG_WIDTH > 88 )); then
        DIALOG_WIDTH=88
    fi

    if (( DIALOG_HEIGHT < 18 )); then
        DIALOG_HEIGHT=18
    fi

    if (( DIALOG_WIDTH < 58 )); then
        DIALOG_WIDTH=58
    fi

    LIST_HEIGHT=$((DIALOG_HEIGHT - 9))

    if (( LIST_HEIGHT < 6 )); then
        LIST_HEIGHT=6
    fi
}

###############################################################################
# Preflight checks
###############################################################################

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        print_error "This script must be run as root."

        printf '\nRun it with:\n\n'
        printf '  sudo bash %s\n\n' "$0"

        exit 1
    fi
}

verify_proxmox() {
    if ! command_exists pct || [[ ! -d /etc/pve ]]; then
        print_error "This does not appear to be a Proxmox VE host."
        print_error "The pct command or /etc/pve directory could not be found."

        exit 1
    fi
}

ensure_whiptail() {
    if command_exists whiptail; then
        return
    fi

    print_header

    print_warning \
        "The whiptail package is required for interactive checkbox menus."

    printf '\n'

    if ! plain_yes_no "Install whiptail now?"; then
        printf '\nNo changes were made.\n'
        exit 1
    fi

    printf '\nInstalling whiptail...\n\n'

    if ! apt-get update; then
        print_error "Package lists could not be updated."
        exit 1
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail; then
        print_error "whiptail could not be installed."
        exit 1
    fi

    print_success "whiptail was installed."

    sleep 1
}

###############################################################################
# Result accounting
###############################################################################

record_success() {
    local target="$1"
    local message="$2"

    TARGET_OK["$target"]=$(( ${TARGET_OK["$target"]:-0} + 1 ))
    TOTAL_OK=$((TOTAL_OK + 1))

    print_success "$message"
}

record_failure() {
    local target="$1"
    local message="$2"

    TARGET_FAILED["$target"]=$(( ${TARGET_FAILED["$target"]:-0} + 1 ))
    TOTAL_FAILED=$((TOTAL_FAILED + 1))

    print_error "$message"
}

record_skip() {
    local target="$1"
    local message="$2"

    TARGET_SKIPPED["$target"]=$(( ${TARGET_SKIPPED["$target"]:-0} + 1 ))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))

    print_warning "$message"
}

###############################################################################
# Operating-system detection
###############################################################################

get_host_os() {
    if [[ -r /etc/os-release ]]; then
        (
            # shellcheck disable=SC1091
            source /etc/os-release
            printf '%s' "${ID:-unknown}"
        )
    else
        printf 'unknown'
    fi
}

get_lxc_os() {
    local vmid="$1"

    pct exec "$vmid" -- bash -lc '
        if [[ -r /etc/os-release ]]; then
            . /etc/os-release
            printf "%s" "${ID:-unknown}"
        else
            printf "unknown"
        fi
    ' 2>/dev/null
}

is_supported_os() {
    case "$1" in
        debian|ubuntu)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

###############################################################################
# Target selection
###############################################################################

choose_target() {
    local result
    local exit_status

    calculate_dialog_size

    result="$(
        whiptail \
            --title "Proxmox Maintenance Wizard" \
            --menu \
            "Choose where maintenance should be performed." \
            "$DIALOG_HEIGHT" \
            "$DIALOG_WIDTH" \
            3 \
            "host" "Maintain the Proxmox host" \
            "lxc"  "Maintain one or more LXC containers" \
            "exit" "Exit without making changes" \
            3>&1 1>&2 2>&3
    )"

    exit_status=$?

    if (( exit_status != 0 )); then
        TARGET_MODE="exit"
    else
        TARGET_MODE="$result"
    fi

    if [[ "$TARGET_MODE" == "exit" ]]; then
        clear 2>/dev/null || true
        printf 'No changes were made.\n'
        exit 0
    fi
}

###############################################################################
# LXC discovery
###############################################################################

discover_lxcs() {
    ALL_LXC_IDS=()
    RUNNING_LXC_IDS=()

    local vmid
    local name
    local status
    local is_template

    while read -r vmid; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue

        is_template="$(
            pct config "$vmid" 2>/dev/null |
                awk -F': ' '$1 == "template" {print $2; exit}'
        )"

        if [[ "$is_template" == "1" ]]; then
            continue
        fi

        name="$(
            pct config "$vmid" 2>/dev/null |
                awk -F': ' '$1 == "hostname" {print $2; exit}'
        )"

        status="$(
            pct status "$vmid" 2>/dev/null |
                awk '{print $2}'
        )"

        [[ -n "$name" ]] || name="unnamed-lxc"
        [[ -n "$status" ]] || status="unknown"

        ALL_LXC_IDS+=("$vmid")
        LXC_NAME["$vmid"]="$name"
        LXC_STATUS["$vmid"]="$status"

        if [[ "$status" == "running" ]]; then
            RUNNING_LXC_IDS+=("$vmid")
        fi
    done < <(
        pct list 2>/dev/null |
            awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}' |
            sort -n
    )
}

###############################################################################
# LXC selection
###############################################################################

select_lxcs() {
    discover_lxcs
    calculate_dialog_size

    if (( ${#ALL_LXC_IDS[@]} == 0 )); then
        whiptail \
            --title "No LXC Containers Found" \
            --msgbox \
            "No locally managed LXC containers were detected on this node." \
            10 \
            "$DIALOG_WIDTH"

        exit 0
    fi

    local -a checklist_items=()
    local -a chosen=()
    local -A selected_map=()

    local vmid
    local output
    local exit_status
    local tag
    local description
    local default_state

    checklist_items+=(
        "__ALL_RUNNING__"
        "Select all running containers"
        "OFF"
    )

    checklist_items+=(
        "__ALL__"
        "Select all containers"
        "OFF"
    )

    for vmid in "${ALL_LXC_IDS[@]}"; do
        if [[ "${LXC_STATUS[$vmid]}" == "running" ]]; then
            default_state="ON"
        else
            default_state="OFF"
        fi

        description="${LXC_NAME[$vmid]} [${LXC_STATUS[$vmid]}]"

        checklist_items+=(
            "$vmid"
            "$description"
            "$default_state"
        )
    done

    while true; do
        calculate_dialog_size

        output="$(
            whiptail \
                --title "Select LXC Containers" \
                --checklist \
                "Arrow keys: move   Space: check/uncheck   Enter: continue" \
                "$DIALOG_HEIGHT" \
                "$DIALOG_WIDTH" \
                "$LIST_HEIGHT" \
                "${checklist_items[@]}" \
                --separate-output \
                3>&1 1>&2 2>&3
        )"

        exit_status=$?

        if (( exit_status != 0 )); then
            clear 2>/dev/null || true
            printf 'No changes were made.\n'
            exit 0
        fi

        chosen=()

        while IFS= read -r tag; do
            [[ -n "$tag" ]] && chosen+=("$tag")
        done <<< "$output"

        if (( ${#chosen[@]} == 0 )); then
            whiptail \
                --title "Nothing Selected" \
                --msgbox \
                "Select at least one LXC container." \
                9 \
                "$DIALOG_WIDTH"

            continue
        fi

        selected_map=()

        for tag in "${chosen[@]}"; do
            case "$tag" in
                __ALL__)
                    for vmid in "${ALL_LXC_IDS[@]}"; do
                        selected_map["$vmid"]=1
                    done
                    ;;

                __ALL_RUNNING__)
                    for vmid in "${RUNNING_LXC_IDS[@]}"; do
                        selected_map["$vmid"]=1
                    done
                    ;;

                *)
                    if array_contains "$tag" "${ALL_LXC_IDS[@]}"; then
                        selected_map["$tag"]=1
                    fi
                    ;;
            esac
        done

        SELECTED_LXC_IDS=()

        for vmid in "${ALL_LXC_IDS[@]}"; do
            if [[ -n "${selected_map[$vmid]:-}" ]]; then
                SELECTED_LXC_IDS+=("$vmid")
            fi
        done

        if (( ${#SELECTED_LXC_IDS[@]} == 0 )); then
            whiptail \
                --title "Nothing Selected" \
                --msgbox \
                "No matching LXC containers were selected." \
                9 \
                "$DIALOG_WIDTH"

            continue
        fi

        return
    done
}

###############################################################################
# Stopped-container handling
###############################################################################

configure_stopped_lxcs() {
    local vmid
    local result
    local exit_status
    local message

    for vmid in "${SELECTED_LXC_IDS[@]}"; do
        if [[ "${LXC_STATUS[$vmid]}" == "running" ]]; then
            STOPPED_ACTION["$vmid"]="already-running"
            continue
        fi

        calculate_dialog_size

        message="$(
            printf 'LXC %s (%s) is stopped.\n\nChoose how it should be handled.' \
                "$vmid" \
                "${LXC_NAME[$vmid]}"
        )"

        result="$(
            whiptail \
                --title "Stopped LXC Container" \
                --default-item "skip" \
                --menu \
                "$message" \
                "$DIALOG_HEIGHT" \
                "$DIALOG_WIDTH" \
                3 \
                "skip" \
                "Skip this container" \
                "temporary" \
                "Start, maintain, then stop" \
                "leave-running" \
                "Start, maintain, leave running" \
                3>&1 1>&2 2>&3
        )"

        exit_status=$?

        if (( exit_status != 0 )); then
            result="skip"
        fi

        STOPPED_ACTION["$vmid"]="$result"
    done
}

###############################################################################
# Maintenance-task selection
###############################################################################

task_label() {
    case "$1" in
        apt-update)
            printf 'Update package lists'
            ;;

        apt-upgrade)
            printf 'Install available package upgrades'
            ;;

        apt-autoremove)
            printf 'Remove unused packages'
            ;;

        apt-clean)
            printf 'Clean the APT package cache'
            ;;

        journal-clean)
            printf 'Remove journal entries older than %s' \
                "$JOURNAL_RETENTION"
            ;;

        logrotate)
            printf 'Run normal log rotation'
            ;;

        temp-clean)
            printf 'Clean temporary files'
            ;;

        fstrim)
            printf 'Trim supported filesystems'
            ;;

        docker-prune)
            printf 'Remove unused Docker data, excluding volumes'
            ;;

        *)
            printf '%s' "$1"
            ;;
    esac
}

select_tasks() {
    local output
    local exit_status
    local task

    while true; do
        calculate_dialog_size

        output="$(
            whiptail \
                --title "Select Maintenance Tasks" \
                --checklist \
                "Arrow keys: move   Space: check/uncheck   Enter: continue" \
                "$DIALOG_HEIGHT" \
                "$DIALOG_WIDTH" \
                "$LIST_HEIGHT" \
                "apt-update" \
                "Update package lists" \
                "ON" \
                "apt-upgrade" \
                "Install package upgrades" \
                "ON" \
                "apt-autoremove" \
                "Remove unused packages" \
                "OFF" \
                "apt-clean" \
                "Clean APT package cache" \
                "OFF" \
                "journal-clean" \
                "Clean journal older than ${JOURNAL_RETENTION}" \
                "OFF" \
                "logrotate" \
                "Run normal log rotation" \
                "OFF" \
                "temp-clean" \
                "Clean temporary files" \
                "OFF" \
                "fstrim" \
                "Trim supported filesystems" \
                "OFF" \
                "docker-prune" \
                "Clean unused Docker data" \
                "OFF" \
                --separate-output \
                3>&1 1>&2 2>&3
        )"

        exit_status=$?

        if (( exit_status != 0 )); then
            clear 2>/dev/null || true
            printf 'No changes were made.\n'
            exit 0
        fi

        SELECTED_TASKS=()

        while IFS= read -r task; do
            [[ -n "$task" ]] && SELECTED_TASKS+=("$task")
        done <<< "$output"

        if (( ${#SELECTED_TASKS[@]} == 0 )); then
            whiptail \
                --title "Nothing Selected" \
                --msgbox \
                "Select at least one maintenance task." \
                9 \
                "$DIALOG_WIDTH"

            continue
        fi

        return
    done
}

###############################################################################
# Execution-plan confirmation
###############################################################################

build_execution_plan() {
    local plan=""
    local vmid
    local task
    local action

    plan+="TARGETS"$'\n'
    plan+="-------"$'\n'

    if [[ "$TARGET_MODE" == "host" ]]; then
        plan+="Proxmox host: $(hostname)"$'\n'
    else
        for vmid in "${SELECTED_LXC_IDS[@]}"; do
            action="${STOPPED_ACTION[$vmid]:-already-running}"

            plan+="LXC ${vmid}: ${LXC_NAME[$vmid]}"
            plan+=" [${LXC_STATUS[$vmid]}]"

            case "$action" in
                skip)
                    plan+=" [skip]"
                    ;;

                temporary)
                    plan+=" [start temporarily]"
                    ;;

                leave-running)
                    plan+=" [leave running]"
                    ;;
            esac

            plan+=$'\n'
        done
    fi

    plan+=$'\n'
    plan+="TASKS"$'\n'
    plan+="-----"$'\n'

    for task in "${SELECTED_TASKS[@]}"; do
        plan+="* $(task_label "$task")"$'\n'
    done

    plan+=$'\n'
    plan+="SAFETY"$'\n'
    plan+="------"$'\n'
    plan+="* No automatic reboots"$'\n'
    plan+="* No Docker volume removal"$'\n'
    plan+="* No forced container shutdowns"$'\n'
    plan+="* Unsupported tasks are skipped"$'\n'

    printf '%s' "$plan"
}

confirm_execution_plan() {
    local plan

    calculate_dialog_size
    plan="$(build_execution_plan)"

    if ! whiptail \
        --title "Confirm Maintenance Plan" \
        --scrolltext \
        --yesno \
        "$plan" \
        "$DIALOG_HEIGHT" \
        "$DIALOG_WIDTH"; then

        clear 2>/dev/null || true
        printf 'No maintenance tasks were run.\n'
        exit 0
    fi
}

###############################################################################
# Space measurement
###############################################################################

get_host_available_bytes() {
    df -B1 --output=avail / 2>/dev/null |
        awk 'NR == 2 {print $1}'
}

get_lxc_available_bytes() {
    local vmid="$1"

    pct exec "$vmid" -- \
        df -B1 --output=avail / 2>/dev/null |
        awk 'NR == 2 {print $1}'
}

###############################################################################
# Command wrappers
###############################################################################

run_host_command() {
    local target="$1"
    local description="$2"

    shift 2

    printf '\n%s\n' "${BOLD}${description}${RESET}"

    if "$@"; then
        record_success "$target" "$description completed."
        return 0
    fi

    record_failure "$target" "$description failed."

    return 1
}

run_lxc_command() {
    local vmid="$1"
    local target="$2"
    local description="$3"
    local command_string="$4"

    printf '\n%s\n' "${BOLD}${description}${RESET}"

    if pct exec "$vmid" -- bash -lc "$command_string"; then
        record_success "$target" "$description completed."
        return 0
    fi

    record_failure "$target" "$description failed."

    return 1
}

###############################################################################
# Host maintenance tasks
###############################################################################

host_has_docker() {
    command_exists docker
}

run_host_task() {
    local task="$1"
    local target="host"

    case "$task" in
        apt-update)
            run_host_command \
                "$target" \
                "Updating package lists" \
                env DEBIAN_FRONTEND=noninteractive \
                apt-get update
            ;;

        apt-upgrade)
            run_host_command \
                "$target" \
                "Installing available package upgrades" \
                env DEBIAN_FRONTEND=noninteractive \
                apt-get -y upgrade
            ;;

        apt-autoremove)
            run_host_command \
                "$target" \
                "Removing unused packages" \
                env DEBIAN_FRONTEND=noninteractive \
                apt-get -y autoremove
            ;;

        apt-clean)
            run_host_command \
                "$target" \
                "Cleaning the APT package cache" \
                apt-get clean
            ;;

        journal-clean)
            if ! command_exists journalctl; then
                record_skip \
                    "$target" \
                    "journalctl is unavailable; journal cleanup skipped."

                return
            fi

            run_host_command \
                "$target" \
                "Removing journal entries older than ${JOURNAL_RETENTION}" \
                journalctl --vacuum-time="$JOURNAL_RETENTION"
            ;;

        logrotate)
            if ! command_exists logrotate; then
                record_skip \
                    "$target" \
                    "logrotate is unavailable; log rotation skipped."

                return
            fi

            run_host_command \
                "$target" \
                "Running normal log rotation" \
                logrotate /etc/logrotate.conf
            ;;

        temp-clean)
            if ! command_exists systemd-tmpfiles; then
                record_skip \
                    "$target" \
                    "systemd-tmpfiles is unavailable; temporary cleanup skipped."

                return
            fi

            run_host_command \
                "$target" \
                "Cleaning temporary files" \
                systemd-tmpfiles --clean
            ;;

        fstrim)
            if ! command_exists fstrim; then
                record_skip \
                    "$target" \
                    "fstrim is unavailable; filesystem trim skipped."

                return
            fi

            run_host_command \
                "$target" \
                "Trimming supported host filesystems" \
                fstrim -av
            ;;

        docker-prune)
            if ! host_has_docker; then
                record_skip \
                    "$target" \
                    "Docker was not detected on the host."

                return
            fi

            run_host_command \
                "$target" \
                "Removing unused Docker data, excluding volumes" \
                docker system prune -f
            ;;

        *)
            record_skip "$target" "Unknown task skipped: $task"
            ;;
    esac
}

###############################################################################
# LXC maintenance tasks
###############################################################################

lxc_has_command() {
    local vmid="$1"
    local command_name="$2"

    pct exec "$vmid" -- \
        bash -lc "command -v '$command_name' >/dev/null 2>&1" \
        >/dev/null 2>&1
}

run_lxc_task() {
    local vmid="$1"
    local task="$2"
    local target="lxc-${vmid}"

    case "$task" in
        apt-update)
            run_lxc_command \
                "$vmid" \
                "$target" \
                "Updating package lists" \
                "DEBIAN_FRONTEND=noninteractive apt-get update"
            ;;

        apt-upgrade)
            run_lxc_command \
                "$vmid" \
                "$target" \
                "Installing available package upgrades" \
                "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
            ;;

        apt-autoremove)
            run_lxc_command \
                "$vmid" \
                "$target" \
                "Removing unused packages" \
                "DEBIAN_FRONTEND=noninteractive apt-get -y autoremove"
            ;;

        apt-clean)
            run_lxc_command \
                "$vmid" \
                "$target" \
                "Cleaning the APT package cache" \
                "apt-get clean"
            ;;

        journal-clean)
            if ! lxc_has_command "$vmid" journalctl; then
                record_skip \
                    "$target" \
                    "journalctl is unavailable; journal cleanup skipped."

                return
            fi

            run_lxc_command \
                "$vmid" \
                "$target" \
                "Removing journal entries older than ${JOURNAL_RETENTION}" \
                "journalctl --vacuum-time='${JOURNAL_RETENTION}'"
            ;;

        logrotate)
            if ! lxc_has_command "$vmid" logrotate; then
                record_skip \
                    "$target" \
                    "logrotate is unavailable; log rotation skipped."

                return
            fi

            run_lxc_command \
                "$vmid" \
                "$target" \
                "Running normal log rotation" \
                "logrotate /etc/logrotate.conf"
            ;;

        temp-clean)
            if ! lxc_has_command "$vmid" systemd-tmpfiles; then
                record_skip \
                    "$target" \
                    "systemd-tmpfiles is unavailable; temporary cleanup skipped."

                return
            fi

            run_lxc_command \
                "$vmid" \
                "$target" \
                "Cleaning temporary files" \
                "systemd-tmpfiles --clean"
            ;;

        fstrim)
            printf '\n%s\n' \
                "${BOLD}Trimming supported container storage${RESET}"

            if pct fstrim "$vmid"; then
                record_success \
                    "$target" \
                    "Filesystem trim completed."
            else
                record_failure \
                    "$target" \
                    "Filesystem trim failed or is unsupported."
            fi
            ;;

        docker-prune)
            if ! lxc_has_command "$vmid" docker; then
                record_skip \
                    "$target" \
                    "Docker was not detected; Docker cleanup skipped."

                return
            fi

            run_lxc_command \
                "$vmid" \
                "$target" \
                "Removing unused Docker data, excluding volumes" \
                "docker system prune -f"
            ;;

        *)
            record_skip "$target" "Unknown task skipped: $task"
            ;;
    esac
}

###############################################################################
# LXC lifecycle management
###############################################################################

wait_for_lxc_status() {
    local vmid="$1"
    local desired_status="$2"
    local timeout="$3"

    local elapsed=0
    local current_status

    while (( elapsed < timeout )); do
        current_status="$(
            pct status "$vmid" 2>/dev/null |
                awk '{print $2}'
        )"

        if [[ "$current_status" == "$desired_status" ]]; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

start_lxc() {
    local vmid="$1"
    local target="lxc-${vmid}"

    print_info "Starting LXC ${vmid} (${LXC_NAME[$vmid]})..."

    if ! pct start "$vmid"; then
        record_failure "$target" "The container could not be started."
        return 1
    fi

    if ! wait_for_lxc_status \
        "$vmid" \
        "running" \
        "$START_TIMEOUT_SECONDS"; then

        record_failure \
            "$target" \
            "The container did not start within ${START_TIMEOUT_SECONDS} seconds."

        return 1
    fi

    LXC_STATUS["$vmid"]="running"

    print_success "LXC ${vmid} is running."

    return 0
}

stop_temporarily_started_lxc() {
    local vmid="$1"

    if [[ -z "${TEMPORARILY_RUNNING[$vmid]:-}" ]]; then
        return
    fi

    print_info "Returning LXC ${vmid} to stopped status..."

    if ! pct shutdown "$vmid" --timeout "$SHUTDOWN_TIMEOUT_SECONDS"; then
        print_warning "Graceful shutdown failed for LXC ${vmid}."
        print_warning "The wizard will not force-stop it."

        unset 'TEMPORARILY_RUNNING[$vmid]'

        return
    fi

    if wait_for_lxc_status \
        "$vmid" \
        "stopped" \
        "$SHUTDOWN_TIMEOUT_SECONDS"; then

        print_success "LXC ${vmid} was returned to stopped status."
    else
        print_warning \
            "LXC ${vmid} did not stop before the timeout."
    fi

    unset 'TEMPORARILY_RUNNING[$vmid]'
}

cleanup_interrupted_run() {
    local vmid

    printf '\n'
    print_warning "The wizard was interrupted."

    for vmid in "${!TEMPORARILY_RUNNING[@]}"; do
        stop_temporarily_started_lxc "$vmid"
    done

    exit 130
}

trap cleanup_interrupted_run INT TERM

###############################################################################
# Maintenance execution
###############################################################################

perform_host_maintenance() {
    local host_os
    local task

    print_header
    print_section "Maintaining Proxmox Host"

    host_os="$(get_host_os)"

    if ! is_supported_os "$host_os"; then
        print_error "Unsupported host operating system: $host_os"
        return 1
    fi

    SPACE_BEFORE["host"]="$(get_host_available_bytes)"

    for task in "${SELECTED_TASKS[@]}"; do
        run_host_task "$task"
    done

    SPACE_AFTER["host"]="$(get_host_available_bytes)"
}

perform_lxc_maintenance() {
    local vmid
    local target
    local action
    local os_id
    local task

    for vmid in "${SELECTED_LXC_IDS[@]}"; do
        target="lxc-${vmid}"
        action="${STOPPED_ACTION[$vmid]:-already-running}"

        print_header
        print_section "Maintaining LXC ${vmid}: ${LXC_NAME[$vmid]}"

        if [[ "$action" == "skip" ]]; then
            record_skip \
                "$target" \
                "This stopped container was selected to be skipped."

            continue
        fi

        if [[ "${LXC_STATUS[$vmid]}" != "running" ]]; then
            if ! start_lxc "$vmid"; then
                continue
            fi

            if [[ "$action" == "temporary" ]]; then
                TEMPORARILY_RUNNING["$vmid"]=1
            fi
        fi

        os_id="$(get_lxc_os "$vmid")"

        if ! is_supported_os "$os_id"; then
            record_skip \
                "$target" \
                "Unsupported operating system: ${os_id:-unknown}. Debian and Ubuntu are supported."

            stop_temporarily_started_lxc "$vmid"

            continue
        fi

        print_info "Detected operating system: $os_id"

        SPACE_BEFORE["$target"]="$(get_lxc_available_bytes "$vmid")"

        for task in "${SELECTED_TASKS[@]}"; do
            run_lxc_task "$vmid" "$task"
        done

        SPACE_AFTER["$target"]="$(get_lxc_available_bytes "$vmid")"

        stop_temporarily_started_lxc "$vmid"
    done
}

###############################################################################
# Summary
###############################################################################

calculate_space_change() {
    local target="$1"
    local before="${SPACE_BEFORE[$target]:-}"
    local after="${SPACE_AFTER[$target]:-}"

    if [[ "$before" =~ ^[0-9]+$ ]] &&
        [[ "$after" =~ ^[0-9]+$ ]]; then

        printf '%s' "$((after - before))"
    else
        printf ''
    fi
}

display_target_summary() {
    local target="$1"
    local label="$2"
    local difference

    difference="$(calculate_space_change "$target")"

    printf '%s\n' "${BOLD}${label}${RESET}"
    printf '  Successful: %s\n' "${TARGET_OK[$target]:-0}"
    printf '  Failed:     %s\n' "${TARGET_FAILED[$target]:-0}"
    printf '  Skipped:    %s\n' "${TARGET_SKIPPED[$target]:-0}"

    if [[ "$difference" =~ ^-?[0-9]+$ ]]; then
        if (( difference > 0 )); then
            printf '  Recovered:  %s\n' \
                "$(format_bytes "$difference")"
        elif (( difference < 0 )); then
            printf '  Disk use:   Increased by %s\n' \
                "$(format_bytes "$((-difference))")"
        else
            printf '  Disk use:   No measurable change\n'
        fi
    else
        printf '  Disk use:   Could not be measured\n'
    fi

    printf '\n'
}

display_summary() {
    local vmid

    print_header
    print_section "Maintenance Summary"

    if [[ "$TARGET_MODE" == "host" ]]; then
        display_target_summary \
            "host" \
            "Proxmox host: $(hostname)"
    else
        for vmid in "${SELECTED_LXC_IDS[@]}"; do
            display_target_summary \
                "lxc-${vmid}" \
                "LXC ${vmid}: ${LXC_NAME[$vmid]}"
        done
    fi

    printf '%s\n' "${BOLD}Overall totals${RESET}"
    printf '  Successful: %s\n' "$TOTAL_OK"
    printf '  Failed:     %s\n' "$TOTAL_FAILED"
    printf '  Skipped:    %s\n' "$TOTAL_SKIPPED"
    printf '\n'

    if (( TOTAL_FAILED > 0 )); then
        print_warning \
            "Maintenance completed with one or more failures."
    elif (( TOTAL_OK == 0 )); then
        print_warning \
            "No maintenance tasks were completed."
    else
        print_success \
            "Maintenance completed without reported task failures."
    fi

    printf '\nNo host or container was rebooted.\n'
}

###############################################################################
# Main
###############################################################################

main() {
    require_root
    verify_proxmox
    ensure_whiptail
    calculate_dialog_size

    choose_target

    if [[ "$TARGET_MODE" == "lxc" ]]; then
        select_lxcs
        configure_stopped_lxcs
    fi

    select_tasks
    confirm_execution_plan

    clear 2>/dev/null || true

    if [[ "$TARGET_MODE" == "host" ]]; then
        perform_host_maintenance
    else
        perform_lxc_maintenance
    fi

    display_summary
}

main "$@"
