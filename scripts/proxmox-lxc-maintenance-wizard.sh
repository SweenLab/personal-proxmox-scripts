#!/usr/bin/env bash

###############################################################################
# Proxmox Host & LXC Maintenance Wizard
#
# Repository:
#   https://github.com/SweenLab/personal-proxmox-scripts
#
# Purpose:
#   Perform guided maintenance on either:
#     - The local Proxmox VE host
#     - One or more locally managed LXC containers
#
# Supported container operating systems:
#     - Debian
#     - Ubuntu
#
# LXC commands are executed directly through Proxmox using pct exec.
#
# Safety design:
#     - Requires root
#     - Does not reboot the host or any container
#     - Does not remove Docker volumes
#     - Does not automatically start stopped containers
#     - Shows an execution plan before making changes
#     - Defaults to "No" at final confirmation
#
# License:
#   MIT
###############################################################################

set -uo pipefail

SCRIPT_NAME="Proxmox Host & LXC Maintenance Wizard"
SCRIPT_VERSION="1.0.0"

JOURNAL_RETENTION="14d"
TEMP_FILE_AGE_DAYS="7"
START_TIMEOUT_SECONDS="60"
SHUTDOWN_TIMEOUT_SECONDS="60"

declare -a ALL_LXC_IDS=()
declare -a RUNNING_LXC_IDS=()
declare -a STOPPED_LXC_IDS=()
declare -a SELECTED_LXC_IDS=()
declare -a SELECTED_TASKS=()
declare -a TEMPORARILY_STARTED_LXCS=()

declare -A LXC_NAME=()
declare -A LXC_STATUS=()
declare -A LXC_ORIGINAL_STATUS=()
declare -A LXC_STOPPED_ACTION=()

declare -A TARGET_SUCCESS_COUNT=()
declare -A TARGET_FAILURE_COUNT=()
declare -A TARGET_SKIP_COUNT=()
declare -A TARGET_SPACE_BEFORE=()
declare -A TARGET_SPACE_AFTER=()

TOTAL_SUCCESS_COUNT=0
TOTAL_FAILURE_COUNT=0
TOTAL_SKIP_COUNT=0

TARGET_MODE=""

###############################################################################
# Terminal colors
###############################################################################

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    COLOR_RESET="$(tput sgr0)"
    COLOR_BOLD="$(tput bold)"
    COLOR_RED="$(tput setaf 1)"
    COLOR_GREEN="$(tput setaf 2)"
    COLOR_YELLOW="$(tput setaf 3)"
    COLOR_BLUE="$(tput setaf 4)"
    COLOR_CYAN="$(tput setaf 6)"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_CYAN=""
fi

###############################################################################
# Display helpers
###############################################################################

print_header() {
    clear 2>/dev/null || true

    printf '%s\n' "${COLOR_CYAN}============================================================${COLOR_RESET}"
    printf '%s\n' "${COLOR_BOLD}       Proxmox Host & LXC Maintenance Wizard${COLOR_RESET}"
    printf '%s\n' "${COLOR_CYAN}============================================================${COLOR_RESET}"
    printf 'Version: %s\n\n' "$SCRIPT_VERSION"
}

print_section() {
    local title="$1"

    printf '\n%s\n' "${COLOR_BLUE}------------------------------------------------------------${COLOR_RESET}"
    printf '%s\n' "${COLOR_BOLD}${title}${COLOR_RESET}"
    printf '%s\n\n' "${COLOR_BLUE}------------------------------------------------------------${COLOR_RESET}"
}

print_info() {
    printf '%s\n' "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"
}

print_success() {
    printf '%s\n' "${COLOR_GREEN}[OK]${COLOR_RESET} $*"
}

print_warning() {
    printf '%s\n' "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $*"
}

print_error() {
    printf '%s\n' "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

pause_for_enter() {
    printf '\nPress Enter to continue...'
    read -r
}

confirm_yes_no() {
    local prompt="$1"
    local response

    printf '%s [y/N]: ' "$prompt"
    read -r response

    [[ "$response" =~ ^[Yy]$ ]]
}

###############################################################################
# General helpers
###############################################################################

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

format_bytes() {
    local bytes="${1:-0}"

    if ! [[ "$bytes" =~ ^-?[0-9]+$ ]]; then
        printf 'Unknown'
        return
    fi

    if (( bytes < 0 )); then
        printf '0 B'
        return
    fi

    if command_exists numfmt; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%s bytes' "$bytes"
    else
        printf '%s bytes' "$bytes"
    fi
}

array_contains() {
    local needle="$1"
    shift

    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done

    return 1
}

join_by_comma() {
    local IFS=", "
    printf '%s' "$*"
}

normalize_selection_input() {
    local raw="$1"

    raw="${raw//,/ }"
    raw="${raw//;/ }"

    printf '%s' "$raw"
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

verify_proxmox_host() {
    if ! command_exists pct; then
        print_error "The Proxmox pct command was not found."
        print_error "Run this script directly on a Proxmox VE host."
        exit 1
    fi

    if [[ ! -d /etc/pve ]]; then
        print_error "/etc/pve was not found."
        print_error "This does not appear to be a Proxmox VE host."
        exit 1
    fi
}

check_required_commands() {
    local required_commands=(
        awk
        bash
        df
        grep
        sed
        sort
    )

    local missing=()
    local command_name

    for command_name in "${required_commands[@]}"; do
        if ! command_exists "$command_name"; then
            missing+=("$command_name")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        print_error "Required commands are missing:"
        printf '  - %s\n' "${missing[@]}"
        exit 1
    fi
}

###############################################################################
# Target and operating-system checks
###############################################################################

get_host_os_id() {
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

get_lxc_os_id() {
    local vmid="$1"

    pct exec "$vmid" -- bash -c '
        if [[ -r /etc/os-release ]]; then
            . /etc/os-release
            printf "%s" "${ID:-unknown}"
        else
            printf "unknown"
        fi
    ' 2>/dev/null
}

is_supported_os_id() {
    local os_id="$1"

    case "$os_id" in
        debian|ubuntu)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

host_has_docker() {
    command_exists docker
}

lxc_has_docker() {
    local vmid="$1"

    pct exec "$vmid" -- bash -c 'command -v docker >/dev/null 2>&1' \
        >/dev/null 2>&1
}

host_has_systemd_journal() {
    command_exists journalctl
}

lxc_has_systemd_journal() {
    local vmid="$1"

    pct exec "$vmid" -- bash -c 'command -v journalctl >/dev/null 2>&1' \
        >/dev/null 2>&1
}

###############################################################################
# LXC discovery
###############################################################################

discover_lxcs() {
    ALL_LXC_IDS=()
    RUNNING_LXC_IDS=()
    STOPPED_LXC_IDS=()

    local vmid
    local status
    local name
    local template_value

    while read -r vmid; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue

        template_value="$(
            pct config "$vmid" 2>/dev/null |
                awk -F': ' '$1 == "template" {print $2; exit}'
        )"

        if [[ "$template_value" == "1" ]]; then
            continue
        fi

        status="$(
            pct status "$vmid" 2>/dev/null |
                awk '{print $2}'
        )"

        name="$(
            pct config "$vmid" 2>/dev/null |
                awk -F': ' '$1 == "hostname" {print $2; exit}'
        )"

        [[ -n "$name" ]] || name="unnamed-lxc"

        ALL_LXC_IDS+=("$vmid")
        LXC_NAME["$vmid"]="$name"
        LXC_STATUS["$vmid"]="${status:-unknown}"
        LXC_ORIGINAL_STATUS["$vmid"]="${status:-unknown}"

        case "$status" in
            running)
                RUNNING_LXC_IDS+=("$vmid")
                ;;
            stopped)
                STOPPED_LXC_IDS+=("$vmid")
                ;;
        esac
    done < <(
        pct list 2>/dev/null |
            awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}' |
            sort -n
    )
}

display_lxc_inventory() {
    local index=1
    local vmid

    printf '%-5s %-8s %-30s %-12s\n' \
        "No." "VMID" "Name" "Status"
    printf '%-5s %-8s %-30s %-12s\n' \
        "----" "------" "------------------------------" "------------"

    for vmid in "${ALL_LXC_IDS[@]}"; do
        printf '%-5s %-8s %-30s %-12s\n' \
            "$index" \
            "$vmid" \
            "${LXC_NAME[$vmid]}" \
            "${LXC_STATUS[$vmid]}"

        ((index++))
    done
}

###############################################################################
# Target selection
###############################################################################

choose_target_mode() {
    while true; do
        print_header

        printf 'Where would you like to perform maintenance?\n\n'
        printf '  1) Proxmox host\n'
        printf '  2) LXC containers\n'
        printf '  3) Exit\n\n'

        read -r -p "Select an option [1-3]: " selection

        case "$selection" in
            1)
                TARGET_MODE="host"
                return
                ;;
            2)
                TARGET_MODE="lxc"
                return
                ;;
            3)
                printf '\nNo changes were made.\n'
                exit 0
                ;;
            *)
                print_warning "Please enter 1, 2, or 3."
                sleep 1
                ;;
        esac
    done
}

select_lxcs() {
    discover_lxcs

    if (( ${#ALL_LXC_IDS[@]} == 0 )); then
        print_header
        print_warning "No locally managed LXC containers were found."
        pause_for_enter
        choose_target_mode
        return
    fi

    while true; do
        print_header
        print_section "Detected LXC Containers"

        display_lxc_inventory

        printf '\nSelection options:\n'
        printf '  Enter container numbers or VMIDs separated by commas\n'
        printf '  r = Select all running containers\n'
        printf '  a = Select all containers\n'
        printf '  b = Return to the previous menu\n\n'

        read -r -p "Selection: " raw_selection

        case "${raw_selection,,}" in
            r)
                if (( ${#RUNNING_LXC_IDS[@]} == 0 )); then
                    print_warning "No running LXC containers were found."
                    sleep 2
                    continue
                fi

                SELECTED_LXC_IDS=("${RUNNING_LXC_IDS[@]}")
                return
                ;;
            a)
                SELECTED_LXC_IDS=("${ALL_LXC_IDS[@]}")
                return
                ;;
            b)
                choose_target_mode
                return
                ;;
        esac

        SELECTED_LXC_IDS=()

        local normalized
        local token
        local selected_vmid
        local valid_selection=true

        normalized="$(normalize_selection_input "$raw_selection")"

        for token in $normalized; do
            selected_vmid=""

            if [[ "$token" =~ ^[0-9]+$ ]]; then
                if array_contains "$token" "${ALL_LXC_IDS[@]}"; then
                    selected_vmid="$token"
                elif (( token >= 1 && token <= ${#ALL_LXC_IDS[@]} )); then
                    selected_vmid="${ALL_LXC_IDS[$((token - 1))]}"
                else
                    valid_selection=false
                    print_warning "Unknown selection: $token"
                    break
                fi
            else
                valid_selection=false
                print_warning "Invalid selection: $token"
                break
            fi

            if ! array_contains "$selected_vmid" "${SELECTED_LXC_IDS[@]}"; then
                SELECTED_LXC_IDS+=("$selected_vmid")
            fi
        done

        if [[ "$valid_selection" == true ]] &&
            (( ${#SELECTED_LXC_IDS[@]} > 0 )); then
            return
        fi

        print_warning "No valid containers were selected."
        sleep 2
    done
}

###############################################################################
# Stopped-container handling
###############################################################################

configure_stopped_lxcs() {
    local vmid
    local selection

    for vmid in "${SELECTED_LXC_IDS[@]}"; do
        if [[ "${LXC_STATUS[$vmid]}" != "stopped" ]]; then
            LXC_STOPPED_ACTION["$vmid"]="already-running"
            continue
        fi

        while true; do
            print_header
            print_section "Stopped Container"

            printf 'Container:\n'
            printf '  VMID:   %s\n' "$vmid"
            printf '  Name:   %s\n' "${LXC_NAME[$vmid]}"
            printf '  Status: stopped\n\n'

            printf 'What should the wizard do?\n\n'
            printf '  1) Skip this container\n'
            printf '  2) Start it, perform maintenance, then stop it again\n'
            printf '  3) Start it, perform maintenance, and leave it running\n\n'

            read -r -p "Select an option [1-3, default 1]: " selection

            case "${selection:-1}" in
                1)
                    LXC_STOPPED_ACTION["$vmid"]="skip"
                    break
                    ;;
                2)
                    LXC_STOPPED_ACTION["$vmid"]="start-temporarily"
                    break
                    ;;
                3)
                    LXC_STOPPED_ACTION["$vmid"]="start-and-leave-running"
                    break
                    ;;
                *)
                    print_warning "Please enter 1, 2, or 3."
                    sleep 1
                    ;;
            esac
        done
    done
}

###############################################################################
# Task selection
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
            printf 'Remove system journal entries older than %s' \
                "$JOURNAL_RETENTION"
            ;;
        logrotate)
            printf 'Run normal log rotation'
            ;;
        temp-clean)
            printf 'Clean temporary files using system policies'
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

display_task_menu() {
    printf 'Select one or more maintenance tasks:\n\n'
    printf '  1) Update package lists\n'
    printf '  2) Install available package upgrades\n'
    printf '  3) Remove unused packages\n'
    printf '  4) Clean the APT package cache\n'
    printf '  5) Remove journal entries older than %s\n' \
        "$JOURNAL_RETENTION"
    printf '  6) Run normal log rotation\n'
    printf '  7) Clean temporary files using system policies\n'
    printf '  8) Trim supported filesystems\n'
    printf '  9) Remove unused Docker data, excluding volumes\n\n'
    printf '  a) Select all tasks\n'
    printf '  b) Go back\n\n'
}

selection_number_to_task() {
    case "$1" in
        1)
            printf 'apt-update'
            ;;
        2)
            printf 'apt-upgrade'
            ;;
        3)
            printf 'apt-autoremove'
            ;;
        4)
            printf 'apt-clean'
            ;;
        5)
            printf 'journal-clean'
            ;;
        6)
            printf 'logrotate'
            ;;
        7)
            printf 'temp-clean'
            ;;
        8)
            printf 'fstrim'
            ;;
        9)
            printf 'docker-prune'
            ;;
        *)
            return 1
            ;;
    esac
}

select_tasks() {
    while true; do
        print_header
        print_section "Maintenance Tasks"

        display_task_menu

        read -r -p "Selection: " raw_selection

        case "${raw_selection,,}" in
            a)
                SELECTED_TASKS=(
                    apt-update
                    apt-upgrade
                    apt-autoremove
                    apt-clean
                    journal-clean
                    logrotate
                    temp-clean
                    fstrim
                    docker-prune
                )
                return
                ;;
            b)
                if [[ "$TARGET_MODE" == "host" ]]; then
                    choose_target_mode
                else
                    select_lxcs
                    configure_stopped_lxcs
                fi
                return
                ;;
        esac

        SELECTED_TASKS=()

        local normalized
        local token
        local task
        local valid_selection=true

        normalized="$(normalize_selection_input "$raw_selection")"

        for token in $normalized; do
            if ! [[ "$token" =~ ^[1-9]$ ]]; then
                valid_selection=false
                print_warning "Invalid task selection: $token"
                break
            fi

            if ! task="$(selection_number_to_task "$token")"; then
                valid_selection=false
                print_warning "Unknown task selection: $token"
                break
            fi

            if ! array_contains "$task" "${SELECTED_TASKS[@]}"; then
                SELECTED_TASKS+=("$task")
            fi
        done

        if [[ "$valid_selection" == true ]] &&
            (( ${#SELECTED_TASKS[@]} > 0 )); then
            return
        fi

        print_warning "No valid tasks were selected."
        sleep 2
    done
}

###############################################################################
# Execution-plan display
###############################################################################

display_selected_targets() {
    local vmid

    if [[ "$TARGET_MODE" == "host" ]]; then
        printf '  - Proxmox host: %s\n' "$(hostname)"
        return
    fi

    for vmid in "${SELECTED_LXC_IDS[@]}"; do
        printf '  - %s (%s), status: %s' \
            "${LXC_NAME[$vmid]}" \
            "$vmid" \
            "${LXC_STATUS[$vmid]}"

        case "${LXC_STOPPED_ACTION[$vmid]:-already-running}" in
            skip)
                printf ', action: skip'
                ;;
            start-temporarily)
                printf ', action: start temporarily'
                ;;
            start-and-leave-running)
                printf ', action: start and leave running'
                ;;
        esac

        printf '\n'
    done
}

display_execution_plan() {
    print_header
    print_section "Execution Plan"

    printf '%s\n' "${COLOR_BOLD}Targets:${COLOR_RESET}"
    display_selected_targets

    printf '\n%s\n' "${COLOR_BOLD}Tasks:${COLOR_RESET}"

    local task
    for task in "${SELECTED_TASKS[@]}"; do
        printf '  - %s\n' "$(task_label "$task")"
    done

    printf '\n%s\n' "${COLOR_BOLD}Safety notes:${COLOR_RESET}"
    printf '  - No host or container will be rebooted.\n'
    printf '  - Docker volumes will not be removed.\n'
    printf '  - Unsupported tasks will be skipped.\n'
    printf '  - Failed tasks will not stop maintenance on other targets.\n'
    printf '  - A stopped container will only be started if explicitly selected.\n'

    printf '\n'
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

    pct exec "$vmid" -- df -B1 --output=avail / 2>/dev/null |
        awk 'NR == 2 {print $1}'
}

###############################################################################
# Result accounting
###############################################################################

record_success() {
    local target="$1"
    local message="$2"

    TARGET_SUCCESS_COUNT["$target"]=$(
        (${TARGET_SUCCESS_COUNT["$target"]:-0} + 1)
    )

    TOTAL_SUCCESS_COUNT=$((TOTAL_SUCCESS_COUNT + 1))

    print_success "$message"
}

record_failure() {
    local target="$1"
    local message="$2"

    TARGET_FAILURE_COUNT["$target"]=$(
        (${TARGET_FAILURE_COUNT["$target"]:-0} + 1)
    )

    TOTAL_FAILURE_COUNT=$((TOTAL_FAILURE_COUNT + 1))

    print_error "$message"
}

record_skip() {
    local target="$1"
    local message="$2"

    TARGET_SKIP_COUNT["$target"]=$(
        (${TARGET_SKIP_COUNT["$target"]:-0} + 1)
    )

    TOTAL_SKIP_COUNT=$((TOTAL_SKIP_COUNT + 1))

    print_warning "$message"
}

###############################################################################
# Command execution wrappers
###############################################################################

run_host_command() {
    local target="$1"
    local description="$2"
    shift 2

    printf '\n%s\n' "${COLOR_BOLD}${description}${COLOR_RESET}"

    if "$@"; then
        record_success "$target" "$description completed."
        return 0
    fi

    record_failure "$target" "$description failed."
    return 1
}

run_lxc_shell_command() {
    local vmid="$1"
    local target="$2"
    local description="$3"
    local command_string="$4"

    printf '\n%s\n' "${COLOR_BOLD}${description}${COLOR_RESET}"

    if pct exec "$vmid" -- bash -c "$command_string"; then
        record_success "$target" "$description completed."
        return 0
    fi

    record_failure "$target" "$description failed."
    return 1
}

###############################################################################
# Host task implementations
###############################################################################

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
            if ! host_has_systemd_journal; then
                record_skip "$target" \
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
                record_skip "$target" \
                    "logrotate is unavailable; log rotation skipped."
                return
            fi

            run_host_command \
                "$target" \
                "Running normal log rotation" \
                logrotate /etc/logrotate.conf
            ;;

        temp-clean)
            if command_exists systemd-tmpfiles; then
                run_host_command \
                    "$target" \
                    "Cleaning temporary files using system policies" \
                    systemd-tmpfiles --clean
            else
                record_skip "$target" \
                    "systemd-tmpfiles is unavailable; temporary-file cleanup skipped."
            fi
            ;;

        fstrim)
            if ! command_exists fstrim; then
                record_skip "$target" \
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
                record_skip "$target" \
                    "Docker was not detected on the host; Docker cleanup skipped."
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
# LXC task implementations
###############################################################################

run_lxc_task() {
    local vmid="$1"
    local task="$2"
    local target="lxc-${vmid}"

    case "$task" in
        apt-update)
            run_lxc_shell_command \
                "$vmid" \
                "$target" \
                "Updating package lists" \
                'DEBIAN_FRONTEND=noninteractive apt-get update'
            ;;

        apt-upgrade)
            run_lxc_shell_command \
                "$vmid" \
                "$target" \
                "Installing available package upgrades" \
                'DEBIAN_FRONTEND=noninteractive apt-get -y upgrade'
            ;;

        apt-autoremove)
            run_lxc_shell_command \
                "$vmid" \
                "$target" \
                "Removing unused packages" \
                'DEBIAN_FRONTEND=noninteractive apt-get -y autoremove'
            ;;

        apt-clean)
            run_lxc_shell_command \
                "$vmid" \
                "$target" \
                "Cleaning the APT package cache" \
                'apt-get clean'
            ;;

        journal-clean)
            if ! lxc_has_systemd_journal "$vmid"; then
                record_skip "$target" \
                    "journalctl is unavailable; journal cleanup skipped."
                return
            fi

            run_lxc_shell_command \
                "$vmid" \
                "$target" \
                "Removing journal entries older than ${JOURNAL_RETENTION}" \
                "journalctl --vacuum-time='${JOURNAL_RETENTION}'"
            ;;

        logrotate)
            if ! pct exec "$vmid" -- bash -c \
                'command -v logrotate >/dev/null 2>&1'; then
                record_skip "$target" \
                    "logrotate is unavailable; log rotation skipped."
                return
            fi

            run_lxc_shell_command \
                "$vmid" \
                "$target" \
                "Running normal log rotation" \
                'logrotate /etc/logrotate.conf'
            ;;

        temp-clean)
            if pct exec "$vmid" -- bash -c \
                'command -v systemd-tmpfiles >/dev/null 2>&1'; then
                run_lxc_shell_command \
                    "$vmid" \
                    "$target" \
                    "Cleaning temporary files using system policies" \
                    'systemd-tmpfiles --clean'
            else
                record_skip "$target" \
                    "systemd-tmpfiles is unavailable; temporary-file cleanup skipped."
            fi
            ;;

        fstrim)
            printf '\n%s\n' \
                "${COLOR_BOLD}Trimming supported container filesystems${COLOR_RESET}"

            if pct fstrim "$vmid"; then
                record_success "$target" \
                    "Filesystem trim completed."
            else
                record_failure "$target" \
                    "Filesystem trim failed or is unsupported."
            fi
            ;;

        docker-prune)
            if ! lxc_has_docker "$vmid"; then
                record_skip "$target" \
                    "Docker was not detected; Docker cleanup skipped."
                return
            fi

            run_lxc_shell_command \
                "$vmid" \
                "$target" \
                "Removing unused Docker data, excluding volumes" \
                'docker system prune -f'
            ;;

        *)
            record_skip "$target" "Unknown task skipped: $task"
            ;;
    esac
}

###############################################################################
# Container lifecycle helpers
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

start_lxc_for_maintenance() {
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
        record_failure "$target" \
            "The container did not reach running status within ${START_TIMEOUT_SECONDS} seconds."
        return 1
    fi

    LXC_STATUS["$vmid"]="running"
    TEMPORARILY_STARTED_LXCS+=("$vmid")

    print_success "Container ${vmid} is running."
    return 0
}

restore_temporarily_started_lxcs() {
    local vmid

    if (( ${#TEMPORARILY_STARTED_LXCS[@]} == 0 )); then
        return
    fi

    print_section "Restoring Original Container States"

    for vmid in "${TEMPORARILY_STARTED_LXCS[@]}"; do
        if [[ "${LXC_STOPPED_ACTION[$vmid]:-}" != "start-temporarily" ]]; then
            continue
        fi

        print_info "Shutting down LXC ${vmid} (${LXC_NAME[$vmid]})..."

        if pct shutdown "$vmid" \
            --timeout "$SHUTDOWN_TIMEOUT_SECONDS"; then
            if wait_for_lxc_status \
                "$vmid" \
                "stopped" \
                "$SHUTDOWN_TIMEOUT_SECONDS"; then
                print_success \
                    "Container ${vmid} was returned to stopped status."
            else
                print_warning \
                    "Container ${vmid} did not report stopped status before the timeout."
            fi
        else
            print_warning \
                "Graceful shutdown failed for container ${vmid}."
            print_warning \
                "The wizard will not force-stop it automatically."
        fi
    done
}

###############################################################################
# Maintenance execution
###############################################################################

perform_host_maintenance() {
    local host_os
    local task

    print_header
    print_section "Maintaining Proxmox Host"

    host_os="$(get_host_os_id)"

    if ! is_supported_os_id "$host_os"; then
        print_error "Unsupported host operating system: $host_os"
        print_error "This version supports Debian-based Proxmox VE hosts."
        return 1
    fi

    TARGET_SPACE_BEFORE["host"]="$(get_host_available_bytes)"

    for task in "${SELECTED_TASKS[@]}"; do
        run_host_task "$task"
    done

    TARGET_SPACE_AFTER["host"]="$(get_host_available_bytes)"
}

perform_lxc_maintenance() {
    local vmid
    local action
    local target
    local os_id
    local task

    for vmid in "${SELECTED_LXC_IDS[@]}"; do
        target="lxc-${vmid}"
        action="${LXC_STOPPED_ACTION[$vmid]:-already-running}"

        print_header
        print_section \
            "Maintaining LXC ${vmid}: ${LXC_NAME[$vmid]}"

        if [[ "$action" == "skip" ]]; then
            record_skip "$target" \
                "Container ${vmid} is stopped and was selected to be skipped."
            continue
        fi

        if [[ "${LXC_STATUS[$vmid]}" != "running" ]]; then
            if ! start_lxc_for_maintenance "$vmid"; then
                continue
            fi
        fi

        os_id="$(get_lxc_os_id "$vmid")"

        if ! is_supported_os_id "$os_id"; then
            record_skip "$target" \
                "Unsupported container operating system: ${os_id:-unknown}. Debian and Ubuntu are supported."
            continue
        fi

        print_info "Detected operating system: $os_id"

        TARGET_SPACE_BEFORE["$target"]="$(get_lxc_available_bytes "$vmid")"

        for task in "${SELECTED_TASKS[@]}"; do
            run_lxc_task "$vmid" "$task"
        done

        TARGET_SPACE_AFTER["$target"]="$(get_lxc_available_bytes "$vmid")"
    done

    restore_temporarily_started_lxcs
}

###############################################################################
# Summary
###############################################################################

calculate_recovered_bytes() {
    local target="$1"
    local before="${TARGET_SPACE_BEFORE[$target]:-}"
    local after="${TARGET_SPACE_AFTER[$target]:-}"

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
    local recovered

    recovered="$(calculate_recovered_bytes "$target")"

    printf '%s\n' "${COLOR_BOLD}${label}${COLOR_RESET}"
    printf '  Successful tasks: %s\n' \
        "${TARGET_SUCCESS_COUNT[$target]:-0}"
    printf '  Failed tasks:     %s\n' \
        "${TARGET_FAILURE_COUNT[$target]:-0}"
    printf '  Skipped tasks:    %s\n' \
        "${TARGET_SKIP_COUNT[$target]:-0}"

    if [[ "$recovered" =~ ^-?[0-9]+$ ]]; then
        if (( recovered > 0 )); then
            printf '  Space recovered:  %s\n' \
                "$(format_bytes "$recovered")"
        elif (( recovered < 0 )); then
            printf '  Disk change:      %s more used after maintenance\n' \
                "$(format_bytes "$((-recovered))")"
        else
            printf '  Disk change:      No measurable change\n'
        fi
    else
        printf '  Disk change:      Could not be measured\n'
    fi

    printf '\n'
}

display_summary() {
    print_header
    print_section "Maintenance Summary"

    if [[ "$TARGET_MODE" == "host" ]]; then
        display_target_summary \
            "host" \
            "Proxmox host: $(hostname)"
    else
        local vmid

        for vmid in "${SELECTED_LXC_IDS[@]}"; do
            display_target_summary \
                "lxc-${vmid}" \
                "LXC ${vmid}: ${LXC_NAME[$vmid]}"
        done
    fi

    printf '%s\n' "${COLOR_BOLD}Overall totals${COLOR_RESET}"
    printf '  Successful tasks: %s\n' "$TOTAL_SUCCESS_COUNT"
    printf '  Failed tasks:     %s\n' "$TOTAL_FAILURE_COUNT"
    printf '  Skipped tasks:    %s\n' "$TOTAL_SKIP_COUNT"

    printf '\n'

    if (( TOTAL_FAILURE_COUNT > 0 )); then
        print_warning \
            "Maintenance completed with one or more failures."
        printf 'Review the output above before running additional maintenance.\n'
    elif (( TOTAL_SUCCESS_COUNT == 0 )); then
        print_warning \
            "No maintenance tasks were completed."
    else
        print_success \
            "Maintenance completed without reported task failures."
    fi

    printf '\nNo host or container was rebooted.\n'
}

###############################################################################
# Signal handling
###############################################################################

cleanup_on_exit() {
    local exit_code=$?

    if (( ${#TEMPORARILY_STARTED_LXCS[@]} > 0 )); then
        printf '\n'
        print_warning \
            "The wizard is exiting. Checking temporarily started containers..."
        restore_temporarily_started_lxcs
    fi

    exit "$exit_code"
}

trap cleanup_on_exit INT TERM

###############################################################################
# Main program
###############################################################################

main() {
    require_root
    verify_proxmox_host
    check_required_commands

    choose_target_mode

    if [[ "$TARGET_MODE" == "lxc" ]]; then
        select_lxcs

        if [[ "$TARGET_MODE" == "lxc" ]]; then
            configure_stopped_lxcs
        fi
    fi

    select_tasks
    display_execution_plan

    if ! confirm_yes_no "Proceed with this maintenance plan?"; then
        printf '\nNo maintenance tasks were run.\n'
        exit 0
    fi

    if [[ "$TARGET_MODE" == "host" ]]; then
        perform_host_maintenance
    else
        perform_lxc_maintenance
    fi

    TEMPORARILY_STARTED_LXCS=()

    display_summary
}

main "$@"
