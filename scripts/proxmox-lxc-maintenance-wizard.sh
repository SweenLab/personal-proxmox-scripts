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
# Supported operating systems:
#     - Debian
#     - Ubuntu
#
# Safety:
#     - Requires root
#     - Does not reboot the host or containers
#     - Does not remove Docker volumes
#     - Does not force-stop containers
#     - Does not start stopped containers without permission
#     - Shows the complete execution plan before running
#
# License:
#   MIT
###############################################################################

set -uo pipefail

###############################################################################
# Script configuration
###############################################################################

SCRIPT_VERSION="1.2.0"

JOURNAL_RETENTION="14d"
START_TIMEOUT_SECONDS=60
SHUTDOWN_TIMEOUT_SECONDS=60

LOG_ROOT="/var/log/proxmox-lxc-maintenance"
RUN_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
RUN_LOG_DIR="${LOG_ROOT}/${RUN_TIMESTAMP}"

TARGET_MODE=""
PROFILE_NAME=""
RUN_START_EPOCH=0
RUN_END_EPOCH=0

DIALOG_HEIGHT=20
DIALOG_WIDTH=70
LIST_HEIGHT=10

CURRENT_STEP=0
TOTAL_STEPS=0

TOTAL_OK=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
TOTAL_SPACE_CHANGE=0

declare -a ALL_LXC_IDS=()
declare -a RUNNING_LXC_IDS=()
declare -a SELECTED_LXC_IDS=()
declare -a SELECTED_TASKS=()
declare -a PROFILE_TASKS=()

declare -A LXC_NAME=()
declare -A LXC_STATUS=()
declare -A STOPPED_ACTION=()
declare -A TEMPORARILY_RUNNING=()

declare -A TARGET_OK=()
declare -A TARGET_FAILED=()
declare -A TARGET_SKIPPED=()
declare -A TARGET_STATUS=()

declare -A SPACE_BEFORE=()
declare -A SPACE_AFTER=()
declare -A TARGET_DURATION=()
declare -A TARGET_START_EPOCH=()

declare -A TASK_STATE=()

###############################################################################
# Preserve terminal input when launched through curl
###############################################################################

# Supported launch methods:
#
#   bash <(curl -fsSL URL)
#
#   curl -fsSL URL | bash
#
# When the script is piped into Bash, standard input normally belongs to the
# pipe. Redirecting from /dev/tty allows interactive menus to receive input.

if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
    exec </dev/tty
fi

###############################################################################
# Terminal colors
###############################################################################

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RESET="$(tput sgr0 2>/dev/null || true)"
    BOLD="$(tput bold 2>/dev/null || true)"
    DIM="$(tput dim 2>/dev/null || true)"
    RED="$(tput setaf 1 2>/dev/null || true)"
    GREEN="$(tput setaf 2 2>/dev/null || true)"
    YELLOW="$(tput setaf 3 2>/dev/null || true)"
    CYAN="$(tput setaf 6 2>/dev/null || true)"
else
    RESET=""
    BOLD=""
    DIM=""
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

sanitize_filename() {
    printf '%s' "$1" |
        tr '[:upper:]' '[:lower:]' |
        tr -cs 'a-z0-9._-' '-'
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

format_duration() {
    local total_seconds="${1:-0}"
    local hours
    local minutes
    local seconds

    [[ "$total_seconds" =~ ^[0-9]+$ ]] || total_seconds=0

    hours=$((total_seconds / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    if (( hours > 0 )); then
        printf '%dh %dm %ds' "$hours" "$minutes" "$seconds"
    elif (( minutes > 0 )); then
        printf '%dm %ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
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
        printf 'Enlarge the terminal window and run the script again.\n'

        exit 1
    fi

    DIALOG_HEIGHT=$((terminal_rows - 4))
    DIALOG_WIDTH=$((terminal_cols - 4))

    (( DIALOG_HEIGHT > 30 )) && DIALOG_HEIGHT=30
    (( DIALOG_WIDTH > 92 )) && DIALOG_WIDTH=92
    (( DIALOG_HEIGHT < 18 )) && DIALOG_HEIGHT=18
    (( DIALOG_WIDTH < 58 )) && DIALOG_WIDTH=58

    LIST_HEIGHT=$((DIALOG_HEIGHT - 9))

    (( LIST_HEIGHT < 6 )) && LIST_HEIGHT=6
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
        "The whiptail package is required for interactive menus."

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

initialize_logging() {
    if ! mkdir -p "$RUN_LOG_DIR"; then
        print_error "Could not create the log directory:"
        print_error "$RUN_LOG_DIR"
        exit 1
    fi

    chmod 750 "$LOG_ROOT" "$RUN_LOG_DIR" 2>/dev/null || true
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
                --separate-output \
                --checklist \
                "Arrow keys: move   Space: check/uncheck   Enter: continue" \
                "$DIALOG_HEIGHT" \
                "$DIALOG_WIDTH" \
                "$LIST_HEIGHT" \
                "${checklist_items[@]}" \
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
# Maintenance profiles
###############################################################################

set_profile_tasks() {
    local profile="$1"

    PROFILE_TASKS=()

    case "$profile" in
        weekly)
            PROFILE_NAME="Weekly Maintenance"

            PROFILE_TASKS=(
                "apt-update"
                "apt-upgrade"
                "apt-autoremove"
                "apt-clean"
            )
            ;;

        monthly)
            PROFILE_NAME="Monthly Maintenance"

            PROFILE_TASKS=(
                "apt-update"
                "apt-upgrade"
                "apt-autoremove"
                "apt-clean"
                "journal-clean"
                "logrotate"
                "temp-clean"
                "fstrim"
            )
            ;;

        docker)
            PROFILE_NAME="Docker Maintenance"

            PROFILE_TASKS=(
                "apt-update"
                "apt-upgrade"
                "apt-autoremove"
                "apt-clean"
                "docker-prune"
            )
            ;;

        full)
            PROFILE_NAME="Full Maintenance"

            PROFILE_TASKS=(
                "apt-update"
                "apt-upgrade"
                "apt-autoremove"
                "apt-clean"
                "journal-clean"
                "logrotate"
                "temp-clean"
                "fstrim"
                "docker-prune"
            )
            ;;

        custom)
            PROFILE_NAME="Custom Maintenance"

            PROFILE_TASKS=(
                "apt-update"
                "apt-upgrade"
            )
            ;;

        *)
            PROFILE_NAME="Custom Maintenance"

            PROFILE_TASKS=(
                "apt-update"
                "apt-upgrade"
            )
            ;;
    esac
}

choose_profile() {
    local result
    local exit_status

    calculate_dialog_size

    result="$(
        whiptail \
            --title "Maintenance Profile" \
            --menu \
            "Choose a starting profile. You can edit the selected tasks on the next screen." \
            "$DIALOG_HEIGHT" \
            "$DIALOG_WIDTH" \
            5 \
            "weekly" \
            "Updates, upgrades, autoremove, and APT cleanup" \
            "monthly" \
            "Weekly tasks plus logs, temporary files, and trim" \
            "docker" \
            "Package maintenance plus Docker cleanup" \
            "full" \
            "All available maintenance tasks" \
            "custom" \
            "Choose tasks manually" \
            3>&1 1>&2 2>&3
    )"

    exit_status=$?

    if (( exit_status != 0 )); then
        clear 2>/dev/null || true
        printf 'No changes were made.\n'
        exit 0
    fi

    set_profile_tasks "$result"
}

task_enabled_by_profile() {
    local task="$1"

    if array_contains "$task" "${PROFILE_TASKS[@]}"; then
        printf 'ON'
    else
        printf 'OFF'
    fi
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
                --title "${PROFILE_NAME}" \
                --separate-output \
                --checklist \
                "Review the profile. Press Space to change any selection." \
                "$DIALOG_HEIGHT" \
                "$DIALOG_WIDTH" \
                "$LIST_HEIGHT" \
                "apt-update" \
                "Update package lists" \
                "$(task_enabled_by_profile "apt-update")" \
                "apt-upgrade" \
                "Install package upgrades" \
                "$(task_enabled_by_profile "apt-upgrade")" \
                "apt-autoremove" \
                "Remove unused packages" \
                "$(task_enabled_by_profile "apt-autoremove")" \
                "apt-clean" \
                "Clean APT package cache" \
                "$(task_enabled_by_profile "apt-clean")" \
                "journal-clean" \
                "Clean journal older than ${JOURNAL_RETENTION}" \
                "$(task_enabled_by_profile "journal-clean")" \
                "logrotate" \
                "Run normal log rotation" \
                "$(task_enabled_by_profile "logrotate")" \
                "temp-clean" \
                "Clean temporary files" \
                "$(task_enabled_by_profile "temp-clean")" \
                "fstrim" \
                "Trim supported filesystems" \
                "$(task_enabled_by_profile "fstrim")" \
                "docker-prune" \
                "Clean unused Docker data" \
                "$(task_enabled_by_profile "docker-prune")" \
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
# Runtime estimation
###############################################################################

estimate_runtime_minutes() {
    local target_count=1
    local task_count="${#SELECTED_TASKS[@]}"
    local estimate

    if [[ "$TARGET_MODE" == "lxc" ]]; then
        target_count=0

        local vmid

        for vmid in "${SELECTED_LXC_IDS[@]}"; do
            if [[ "${STOPPED_ACTION[$vmid]:-already-running}" != "skip" ]]; then
                target_count=$((target_count + 1))
            fi
        done

        (( target_count < 1 )) && target_count=1
    fi

    estimate=$(((target_count * task_count * 25) / 60))

    (( estimate < 1 )) && estimate=1

    printf '%s' "$estimate"
}

###############################################################################
# Execution-plan confirmation
###############################################################################

build_execution_plan() {
    local plan=""
    local vmid
    local task
    local action
    local estimate_minutes

    estimate_minutes="$(estimate_runtime_minutes)"

    plan+="PROFILE"$'\n'
    plan+="-------"$'\n'
    plan+="${PROFILE_NAME}"$'\n'

    plan+=$'\n'
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
    plan+="ESTIMATED RUNTIME"$'\n'
    plan+="-----------------"$'\n'
    plan+="Approximately ${estimate_minutes} minutes"$'\n'

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
# Progress tracking
###############################################################################

calculate_total_steps() {
    local target_count=1
    local vmid

    if [[ "$TARGET_MODE" == "lxc" ]]; then
        target_count=0

        for vmid in "${SELECTED_LXC_IDS[@]}"; do
            if [[ "${STOPPED_ACTION[$vmid]:-already-running}" != "skip" ]]; then
                target_count=$((target_count + 1))
            fi
        done
    fi

    TOTAL_STEPS=$((target_count * ${#SELECTED_TASKS[@]}))
    CURRENT_STEP=0
}

render_progress_bar() {
    local percent="$1"
    local width=30
    local filled
    local empty
    local bar=""

    filled=$((percent * width / 100))
    empty=$((width - filled))

    if (( filled > 0 )); then
        bar+="$(printf '%*s' "$filled" '' | tr ' ' '#')"
    fi

    if (( empty > 0 )); then
        bar+="$(printf '%*s' "$empty" '' | tr ' ' '.')"
    fi

    printf '%s' "$bar"
}

show_progress() {
    local target_label="$1"
    local task="$2"
    local percent=100
    local bar

    CURRENT_STEP=$((CURRENT_STEP + 1))

    if (( TOTAL_STEPS > 0 )); then
        percent=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    fi

    bar="$(render_progress_bar "$percent")"

    printf '\n%s\n' \
        "${CYAN}============================================================${RESET}"

    printf '%s\n' "${BOLD}${target_label}${RESET}"

    printf '[%s/%s] [%s] %s%%\n' \
        "$CURRENT_STEP" \
        "$TOTAL_STEPS" \
        "$bar" \
        "$percent"

    printf '%s\n' "$(task_label "$task")"

    printf '%s\n' \
        "${CYAN}============================================================${RESET}"
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

###############################################################################
# Logging and quiet command execution
###############################################################################

task_log_path() {
    local target="$1"
    local task="$2"

    printf '%s/%s-%s.log' \
        "$RUN_LOG_DIR" \
        "$(sanitize_filename "$target")" \
        "$(sanitize_filename "$task")"
}

show_failure_log_prompt() {
    local description="$1"
    local log_file="$2"

    calculate_dialog_size

    if whiptail \
        --title "Task Failed" \
        --yesno \
        "${description} failed.\n\nView the task log now?" \
        12 \
        "$DIALOG_WIDTH"; then

        clear 2>/dev/null || true

        printf '%s\n' \
            "${BOLD}Task log: ${log_file}${RESET}"

        printf '%s\n\n' \
            "------------------------------------------------------------"

        if [[ -s "$log_file" ]]; then
            cat "$log_file"
        else
            printf 'The task did not produce any log output.\n'
        fi

        printf '\n'
        read -r -p "Press Enter to continue..."
    fi
}

run_quiet_host_command() {
    local target="$1"
    local task="$2"
    local description="$3"

    shift 3

    local log_file
    local exit_code

    log_file="$(task_log_path "$target" "$task")"

    printf '%s...' "$description"

    "$@" >"$log_file" 2>&1
    exit_code=$?

    if (( exit_code == 0 )); then
        printf ' %s\n' "${GREEN}Complete${RESET}"
        record_success "$target" "$description completed."
        return 0
    fi

    printf ' %s\n' "${RED}Failed${RESET}"
    record_failure "$target" "$description failed."
    show_failure_log_prompt "$description" "$log_file"

    return "$exit_code"
}

run_quiet_lxc_command() {
    local vmid="$1"
    local target="$2"
    local task="$3"
    local description="$4"
    local command_string="$5"

    local log_file
    local exit_code

    log_file="$(task_log_path "$target" "$task")"

    printf '%s...' "$description"

    pct exec "$vmid" -- \
        bash -lc "$command_string" >"$log_file" 2>&1

    exit_code=$?

    if (( exit_code == 0 )); then
        printf ' %s\n' "${GREEN}Complete${RESET}"
        record_success "$target" "$description completed."
        return 0
    fi

    printf ' %s\n' "${RED}Failed${RESET}"
    record_failure "$target" "$description failed."
    show_failure_log_prompt "$description" "$log_file"

    return "$exit_code"
}

run_logged_host_command() {
    local target="$1"
    local task="$2"
    local description="$3"

    shift 3

    local log_file
    local exit_code

    log_file="$(task_log_path "$target" "$task")"

    printf '%s...\n' "$description"

    "$@" 2>&1 | tee "$log_file"
    exit_code=${PIPESTATUS[0]}

    if (( exit_code == 0 )); then
        record_success "$target" "$description completed."
        return 0
    fi

    record_failure "$target" "$description failed."

    return "$exit_code"
}

run_logged_lxc_command() {
    local vmid="$1"
    local target="$2"
    local task="$3"
    local description="$4"
    local command_string="$5"

    local log_file
    local exit_code

    log_file="$(task_log_path "$target" "$task")"

    printf '%s...\n' "$description"

    pct exec "$vmid" -- \
        bash -lc "$command_string" 2>&1 | tee "$log_file"

    exit_code=${PIPESTATUS[0]}

    if (( exit_code == 0 )); then
        record_success "$target" "$description completed."
        return 0
    fi

    record_failure "$target" "$description failed."

    return "$exit_code"
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
            run_quiet_host_command \
                "$target" \
                "$task" \
                "Updating package lists" \
                env DEBIAN_FRONTEND=noninteractive \
                apt-get update
            ;;

        apt-upgrade)
            run_quiet_host_command \
                "$target" \
                "$task" \
                "Installing package upgrades" \
                env DEBIAN_FRONTEND=noninteractive \
                apt-get -y upgrade
            ;;

        apt-autoremove)
            run_quiet_host_command \
                "$target" \
                "$task" \
                "Removing unused packages" \
                env DEBIAN_FRONTEND=noninteractive \
                apt-get -y autoremove
            ;;

        apt-clean)
            run_quiet_host_command \
                "$target" \
                "$task" \
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

            run_logged_host_command \
                "$target" \
                "$task" \
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

            run_quiet_host_command \
                "$target" \
                "$task" \
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

            run_quiet_host_command \
                "$target" \
                "$task" \
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

            run_logged_host_command \
                "$target" \
                "$task" \
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

            run_logged_host_command \
                "$target" \
                "$task" \
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
            run_quiet_lxc_command \
                "$vmid" \
                "$target" \
                "$task" \
                "Updating package lists" \
                "DEBIAN_FRONTEND=noninteractive apt-get update"
            ;;

        apt-upgrade)
            run_quiet_lxc_command \
                "$vmid" \
                "$target" \
                "$task" \
                "Installing package upgrades" \
                "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
            ;;

        apt-autoremove)
            run_quiet_lxc_command \
                "$vmid" \
                "$target" \
                "$task" \
                "Removing unused packages" \
                "DEBIAN_FRONTEND=noninteractive apt-get -y autoremove"
            ;;

        apt-clean)
            run_quiet_lxc_command \
                "$vmid" \
                "$target" \
                "$task" \
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

            run_logged_lxc_command \
                "$vmid" \
                "$target" \
                "$task" \
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

            run_quiet_lxc_command \
                "$vmid" \
                "$target" \
                "$task" \
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

            run_quiet_lxc_command \
                "$vmid" \
                "$target" \
                "$task" \
                "Cleaning temporary files" \
                "systemd-tmpfiles --clean"
            ;;

        fstrim)
            local log_file
            local exit_code

            log_file="$(task_log_path "$target" "$task")"

            printf 'Trimming supported container storage...\n'

            pct fstrim "$vmid" 2>&1 | tee "$log_file"
            exit_code=${PIPESTATUS[0]}

            if (( exit_code == 0 )); then
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

            run_logged_lxc_command \
                "$vmid" \
                "$target" \
                "$task" \
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
# Target timing and status
###############################################################################

start_target_timer() {
    local target="$1"

    TARGET_START_EPOCH["$target"]="$(date +%s)"
}

stop_target_timer() {
    local target="$1"
    local start="${TARGET_START_EPOCH[$target]:-}"
    local end

    end="$(date +%s)"

    if [[ "$start" =~ ^[0-9]+$ ]]; then
        TARGET_DURATION["$target"]=$((end - start))
    else
        TARGET_DURATION["$target"]=0
    fi
}

determine_target_status() {
    local target="$1"
    local successful="${TARGET_OK[$target]:-0}"
    local failed="${TARGET_FAILED[$target]:-0}"
    local skipped="${TARGET_SKIPPED[$target]:-0}"

    if (( failed > 0 )); then
        TARGET_STATUS["$target"]="Failed"
    elif (( successful > 0 && skipped > 0 )); then
        TARGET_STATUS["$target"]="Completed with skips"
    elif (( successful > 0 )); then
        TARGET_STATUS["$target"]="Success"
    elif (( skipped > 0 )); then
        TARGET_STATUS["$target"]="Skipped"
    else
        TARGET_STATUS["$target"]="No tasks completed"
    fi
}

###############################################################################
# Maintenance execution
###############################################################################

perform_host_maintenance() {
    local host_os
    local task
    local target="host"
    local target_label="Proxmox host: $(hostname)"

    print_header
    print_section "Maintaining Proxmox Host"

    host_os="$(get_host_os)"

    if ! is_supported_os "$host_os"; then
        print_error "Unsupported host operating system: $host_os"
        record_failure "$target" "Host operating system is unsupported."
        determine_target_status "$target"
        return 1
    fi

    start_target_timer "$target"

    SPACE_BEFORE["$target"]="$(get_host_available_bytes)"

    for task in "${SELECTED_TASKS[@]}"; do
        show_progress "$target_label" "$task"
        run_host_task "$task"
    done

    SPACE_AFTER["$target"]="$(get_host_available_bytes)"

    stop_target_timer "$target"
    determine_target_status "$target"
}

perform_lxc_maintenance() {
    local vmid
    local target
    local target_label
    local action
    local os_id
    local task

    for vmid in "${SELECTED_LXC_IDS[@]}"; do
        target="lxc-${vmid}"
        target_label="LXC ${vmid}: ${LXC_NAME[$vmid]}"
        action="${STOPPED_ACTION[$vmid]:-already-running}"

        print_header
        print_section "Maintaining ${target_label}"

        start_target_timer "$target"

        if [[ "$action" == "skip" ]]; then
            record_skip \
                "$target" \
                "This stopped container was selected to be skipped."

            stop_target_timer "$target"
            determine_target_status "$target"
            continue
        fi

        if [[ "${LXC_STATUS[$vmid]}" != "running" ]]; then
            if ! start_lxc "$vmid"; then
                stop_target_timer "$target"
                determine_target_status "$target"
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
            stop_target_timer "$target"
            determine_target_status "$target"

            continue
        fi

        print_info "Detected operating system: $os_id"

        SPACE_BEFORE["$target"]="$(get_lxc_available_bytes "$vmid")"

        for task in "${SELECTED_TASKS[@]}"; do
            show_progress "$target_label" "$task"
            run_lxc_task "$vmid" "$task"
        done

        SPACE_AFTER["$target"]="$(get_lxc_available_bytes "$vmid")"

        stop_temporarily_started_lxc "$vmid"

        stop_target_timer "$target"
        determine_target_status "$target"
    done
}

###############################################################################
# Summary helpers
###############################################################################

status_symbol() {
    local status="$1"

    case "$status" in
        Success)
            printf '%s' "${GREEN}[OK]${RESET}"
            ;;

        "Completed with skips")
            printf '%s' "${YELLOW}[ATTENTION]${RESET}"
            ;;

        Failed)
            printf '%s' "${RED}[FAILED]${RESET}"
            ;;

        Skipped)
            printf '%s' "${YELLOW}[SKIPPED]${RESET}"
            ;;

        *)
            printf '%s' "${YELLOW}[UNKNOWN]${RESET}"
            ;;
    esac
}

display_target_scorecard() {
    local target="$1"
    local label="$2"

    local difference
    local status
    local duration

    difference="$(calculate_space_change "$target")"
    status="${TARGET_STATUS[$target]:-Unknown}"
    duration="${TARGET_DURATION[$target]:-0}"

    printf '%s %s\n' \
        "$(status_symbol "$status")" \
        "${BOLD}${label}${RESET}"

    printf '    Result:     %s\n' "$status"
    printf '    Successful: %s\n' "${TARGET_OK[$target]:-0}"
    printf '    Failed:     %s\n' "${TARGET_FAILED[$target]:-0}"
    printf '    Skipped:    %s\n' "${TARGET_SKIPPED[$target]:-0}"
    printf '    Runtime:    %s\n' "$(format_duration "$duration")"

    if [[ "$difference" =~ ^-?[0-9]+$ ]]; then
        TOTAL_SPACE_CHANGE=$((TOTAL_SPACE_CHANGE + difference))

        if (( difference > 0 )); then
            printf '    Recovered:  %s\n' \
                "$(format_bytes "$difference")"
        elif (( difference < 0 )); then
            printf '    Disk use:   Increased by %s\n' \
                "$(format_bytes "$((-difference))")"
        else
            printf '    Disk use:   No measurable change\n'
        fi
    else
        printf '    Disk use:   Could not be measured\n'
    fi

    printf '\n'
}

display_space_total() {
    print_section "Disk Space Result"

    if (( TOTAL_SPACE_CHANGE > 0 )); then
        printf 'Net space recovered: %s\n' \
            "$(format_bytes "$TOTAL_SPACE_CHANGE")"
    elif (( TOTAL_SPACE_CHANGE < 0 )); then
        printf 'Net disk use increased by: %s\n' \
            "$(format_bytes "$((-TOTAL_SPACE_CHANGE))")"
    else
        printf 'No measurable net disk-space change.\n'
    fi
}

display_overall_result() {
    print_section "Overall Result"

    if (( TOTAL_FAILED > 0 )); then
        printf '%s\n' \
            "${RED}[FAILED] Maintenance completed with one or more failures.${RESET}"
    elif (( TOTAL_OK == 0 )); then
        printf '%s\n' \
            "${YELLOW}[ATTENTION] No maintenance tasks were completed.${RESET}"
    elif (( TOTAL_SKIPPED > 0 )); then
        printf '%s\n' \
            "${YELLOW}[ATTENTION] Maintenance completed with skipped tasks.${RESET}"
    else
        printf '%s\n' \
            "${GREEN}[OK] Maintenance completed successfully.${RESET}"
    fi
}

###############################################################################
# Final summary
###############################################################################

display_summary() {
    local vmid
    local total_runtime

    RUN_END_EPOCH="$(date +%s)"
    total_runtime=$((RUN_END_EPOCH - RUN_START_EPOCH))

    TOTAL_SPACE_CHANGE=0

    print_header
    print_section "Maintenance Scorecard"

    printf 'Profile: %s\n' "$PROFILE_NAME"
    printf 'Started: %s\n' \
        "$(date -d "@${RUN_START_EPOCH}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
            date '+%Y-%m-%d %H:%M:%S')"

    printf 'Runtime: %s\n\n' \
        "$(format_duration "$total_runtime")"

    if [[ "$TARGET_MODE" == "host" ]]; then
        display_target_scorecard \
            "host" \
            "Proxmox host: $(hostname)"
    else
        for vmid in "${SELECTED_LXC_IDS[@]}"; do
            display_target_scorecard \
                "lxc-${vmid}" \
                "LXC ${vmid}: ${LXC_NAME[$vmid]}"
        done
    fi

    display_space_total

    print_section "Task Totals"

    printf 'Successful: %s\n' "$TOTAL_OK"
    printf 'Failed:     %s\n' "$TOTAL_FAILED"
    printf 'Skipped:    %s\n' "$TOTAL_SKIPPED"

    display_overall_result

    print_section "Logs"

    printf 'Task logs were saved to:\n\n'
    printf '  %s\n' "$RUN_LOG_DIR"

    printf '\nNo host or container was rebooted.\n'
    printf 'Docker volumes were not removed.\n'
}

###############################################################################
# Main
###############################################################################

main() {
    require_root
    verify_proxmox
    ensure_whiptail
    calculate_dialog_size
    initialize_logging

    choose_target

    if [[ "$TARGET_MODE" == "lxc" ]]; then
        select_lxcs
        configure_stopped_lxcs
    fi

    choose_profile
    select_tasks
    confirm_execution_plan
    calculate_total_steps

    RUN_START_EPOCH="$(date +%s)"

    clear 2>/dev/null || true

    if [[ "$TARGET_MODE" == "host" ]]; then
        perform_host_maintenance
    else
        perform_lxc_maintenance
    fi

    display_summary
}

main "$@"
