#!/usr/bin/env bash

# ============================================================
# Proxmox Homelab Health Check
#
# Performs a read-only health review of:
#   - System uptime
#   - Storage usage
#   - Available package updates
#   - SMART drive health
#   - Failed systemd services
#   - Default gateway and DNS resolution
#
# Intended to be run as root on a Proxmox host.
# ============================================================

set -uo pipefail

SCRIPT_NAME="Proxmox Homelab Health Check"
VERSION="0.1.0"

# ------------------------------------------------------------
# Terminal colors
# ------------------------------------------------------------

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
    RESET="\033[0m"
    BOLD="\033[1m"
    DIM="\033[2m"

    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[34m"
    CYAN="\033[36m"
    WHITE="\033[37m"
else
    RESET=""
    BOLD=""
    DIM=""

    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    WHITE=""
fi

# ------------------------------------------------------------
# Status collections
# ------------------------------------------------------------

declare -a GOOD_ITEMS=()
declare -a MAINTENANCE_ITEMS=()
declare -a ASAP_ITEMS=()
declare -a CRITICAL_ITEMS=()

# ------------------------------------------------------------
# Display helpers
# ------------------------------------------------------------

print_header() {
    clear 2>/dev/null || true

    printf "%b\n" "${BOLD}${CYAN}============================================================${RESET}"
    printf "%b\n" "${BOLD}${CYAN}  ${SCRIPT_NAME}${RESET}"
    printf "%b\n" "${DIM}  Version ${VERSION}${RESET}"
    printf "%b\n" "${BOLD}${CYAN}============================================================${RESET}"
    printf "\n"
}

print_section() {
    local title="$1"

    printf "\n"
    printf "%b\n" "${BOLD}${BLUE}------------------------------------------------------------${RESET}"
    printf "%b\n" "${BOLD}${BLUE}  ${title}${RESET}"
    printf "%b\n" "${BOLD}${BLUE}------------------------------------------------------------${RESET}"
}

print_info() {
    printf "%b\n" "${CYAN}[INFO]${RESET} $1"
}

print_good() {
    printf "%b\n" "${GREEN}[GOOD]${RESET} $1"
}

print_maintenance() {
    printf "%b\n" "${YELLOW}[MAINTENANCE DUE]${RESET} $1"
}

print_asap() {
    printf "%b\n" "${YELLOW}[ADDRESS ASAP]${RESET} $1"
}

print_critical() {
    printf "%b\n" "${RED}[CRITICAL]${RESET} $1"
}

add_good() {
    GOOD_ITEMS+=("$1")
}

add_maintenance() {
    MAINTENANCE_ITEMS+=("$1")
}

add_asap() {
    ASAP_ITEMS+=("$1")
}

add_critical() {
    CRITICAL_ITEMS+=("$1")
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

trim_whitespace() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    printf "%s" "$value"
}

is_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# ------------------------------------------------------------
# Preliminary checks
# ------------------------------------------------------------

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        printf "%b\n" "${RED}This script must be run as root.${RESET}"
        printf "%b\n" "Run it with:"
        printf "\n"
        printf "%b\n" "${BOLD}sudo bash proxmox-health-check.sh${RESET}"
        exit 1
    fi
}

detect_host() {
    HOSTNAME_DISPLAY="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf "Unknown")"

    if command_exists pveversion; then
        PROXMOX_VERSION="$(pveversion 2>/dev/null | head -n 1)"
    else
        PROXMOX_VERSION="Proxmox version command not found"
    fi
}

# ------------------------------------------------------------
# Uptime
# ------------------------------------------------------------

check_uptime() {
    print_section "System Uptime"

    local uptime_pretty
    local boot_time

    if [[ -r /proc/uptime ]]; then
        uptime_pretty="$(uptime -p 2>/dev/null || true)"
    else
        uptime_pretty=""
    fi

    boot_time="$(uptime -s 2>/dev/null || true)"

    printf "%b\n" "${BOLD}Host:${RESET} ${HOSTNAME_DISPLAY}"
    printf "%b\n" "${BOLD}Proxmox:${RESET} ${PROXMOX_VERSION}"

    if [[ -n "$uptime_pretty" ]]; then
        printf "%b\n" "${BOLD}Uptime:${RESET} ${uptime_pretty#up }"
    else
        printf "%b\n" "${BOLD}Uptime:${RESET} Unable to determine"
    fi

    if [[ -n "$boot_time" ]]; then
        printf "%b\n" "${BOLD}Last boot:${RESET} ${boot_time}"
    fi

    add_good "System uptime information was collected successfully."
}

# ------------------------------------------------------------
# Storage
# ------------------------------------------------------------

check_storage() {
    print_section "Storage Usage"

    printf "%b\n" "${DIM}Healthy: 0-69% | Attention Needed: 70-84% | Critical: 85-100%${RESET}"
    printf "\n"

    local storage_found=0
    local filesystem
    local size
    local used
    local available
    local use_percent
    local mountpoint
    local percent_number
    local display_line

    while read -r filesystem size used available use_percent mountpoint; do
        [[ -z "${filesystem:-}" ]] && continue

        storage_found=1
        percent_number="${use_percent%\%}"

        if ! is_nonnegative_integer "$percent_number"; then
            print_info "${mountpoint}: unable to interpret usage value ${use_percent}"
            continue
        fi

        display_line="${mountpoint} is ${use_percent} full (${used} used of ${size}, ${available} available)"

        if (( percent_number >= 85 )); then
            print_critical "$display_line"
            add_critical "Storage at ${mountpoint} is ${use_percent} full."
        elif (( percent_number >= 70 )); then
            print_asap "$display_line"
            add_asap "Storage at ${mountpoint} is ${use_percent} full."
        else
            print_good "$display_line"
            add_good "Storage at ${mountpoint} is within the healthy range at ${use_percent}."
        fi
    done < <(
        df -P -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null |
            awk 'NR > 1 {print $1, $2, $3, $4, $5, $6}'
    )

    if (( storage_found == 0 )); then
        print_critical "No storage information could be collected."
        add_critical "Storage usage could not be checked."
    fi
}

# ------------------------------------------------------------
# Package updates
# ------------------------------------------------------------

check_package_updates() {
    print_section "Package Updates"

    if ! command_exists apt-get; then
        print_asap "apt-get is not available on this system."
        add_asap "Package updates could not be checked because apt-get is unavailable."
        return
    fi

    print_info "Refreshing package information..."

    local update_output
    local update_status

    update_output="$(mktemp)"

    if apt-get update -qq >"$update_output" 2>&1; then
        update_status=0
    else
        update_status=$?
    fi

    if (( update_status != 0 )); then
        print_asap "Package information could not be refreshed."

        if [[ -s "$update_output" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && printf "       %s\n" "$line"
            done <"$update_output"
        fi

        add_asap "Package information could not be refreshed."
        rm -f "$update_output"
        return
    fi

    rm -f "$update_output"

    local updates
    local update_count
    local security_count

    updates="$(
        apt list --upgradable 2>/dev/null |
            sed '1d' |
            sed '/^[[:space:]]*$/d'
    )"

    if [[ -z "$updates" ]]; then
        print_good "No package updates are currently available."
        add_good "No package updates are currently available."
        return
    fi

    update_count="$(printf "%s\n" "$updates" | wc -l | tr -d ' ')"
    security_count="$(
        printf "%s\n" "$updates" |
            grep -Eci 'security|Debian-Security' ||
            true
    )"

    print_maintenance "${update_count} package update(s) are available."

    if (( security_count > 0 )); then
        print_maintenance "${security_count} available update(s) appear to be security-related."
    fi

    printf "\n"
    printf "%b\n" "${BOLD}Available updates:${RESET}"

    while IFS= read -r update_line; do
        [[ -n "$update_line" ]] && printf "  - %s\n" "$update_line"
    done <<<"$updates"

    add_maintenance "${update_count} package update(s) are available."
}

# ------------------------------------------------------------
# SMART helpers
# ------------------------------------------------------------

get_smart_value() {
    local smart_data="$1"
    local attribute_pattern="$2"

    printf "%s\n" "$smart_data" |
        awk -v pattern="$attribute_pattern" '
            BEGIN {
                IGNORECASE = 1
            }

            $0 ~ pattern {
                for (i = NF; i >= 1; i--) {
                    if ($i ~ /^[0-9]+$/) {
                        print $i
                        exit
                    }
                }
            }
        '
}

get_temperature() {
    local smart_data="$1"
    local temperature

    temperature="$(
        printf "%s\n" "$smart_data" |
            awk '
                BEGIN {
                    IGNORECASE = 1
                }

                /Temperature_Celsius|Airflow_Temperature_Cel/ {
                    for (i = NF; i >= 1; i--) {
                        if ($i ~ /^[0-9]+$/) {
                            print $i
                            exit
                        }
                    }
                }

                /Current Drive Temperature/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^[0-9]+$/) {
                            print $i
                            exit
                        }
                    }
                }

                /Temperature:/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^[0-9]+$/) {
                            print $i
                            exit
                        }
                    }
                }
            '
    )"

    printf "%s" "$temperature"
}

get_nvme_value() {
    local smart_data="$1"
    local label="$2"

    printf "%s\n" "$smart_data" |
        awk -F: -v label="$label" '
            BEGIN {
                IGNORECASE = 1
            }

            $1 ~ label {
                value = $2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        '
}

get_last_self_test() {
    local smart_data="$1"
    local self_test_line

    self_test_line="$(
        printf "%s\n" "$smart_data" |
            awk '
                /^# 1[[:space:]]/ {
                    print
                    exit
                }
            '
    )"

    if [[ -z "$self_test_line" ]]; then
        printf "No self-test history found"
        return
    fi

    self_test_line="$(
        printf "%s" "$self_test_line" |
            sed -E 's/[[:space:]]+/ /g' |
            sed -E 's/^ //; s/ $//'
    )"

    printf "%s" "$self_test_line"
}

classify_temperature() {
    local device="$1"
    local temperature="$2"

    if ! is_nonnegative_integer "$temperature"; then
        print_info "Temperature: unavailable"
        return
    fi

    if (( temperature >= 60 )); then
        print_critical "Temperature: ${temperature}°C"
        add_critical "${device} temperature is ${temperature}°C."
    elif (( temperature >= 50 )); then
        print_asap "Temperature: ${temperature}°C"
        add_asap "${device} temperature is elevated at ${temperature}°C."
    else
        print_good "Temperature: ${temperature}°C"
        add_good "${device} temperature is ${temperature}°C."
    fi
}

classify_sector_value() {
    local device="$1"
    local label="$2"
    local value="$3"
    local zero_message="$4"
    local nonzero_severity="$5"

    if [[ -z "$value" ]]; then
        print_info "${label}: unavailable or not applicable"
        return
    fi

    if ! is_nonnegative_integer "$value"; then
        print_info "${label}: ${value}"
        return
    fi

    if (( value == 0 )); then
        print_good "${label}: ${value}"
        add_good "${device} has ${zero_message}."
        return
    fi

    case "$nonzero_severity" in
        critical)
            print_critical "${label}: ${value}"
            add_critical "${device} reports ${value} ${label,,}."
            ;;
        *)
            print_asap "${label}: ${value}"
            add_asap "${device} reports ${value} ${label,,}."
            ;;
    esac
}

check_smart_device() {
    local scan_line="$1"
    local device
    local smart_options
    local smart_data
    local smart_status
    local model
    local serial
    local health_line
    local temperature
    local reallocated
    local pending
    local offline_uncorrectable
    local last_test
    local nvme_critical_warning
    local nvme_media_errors

    device="$(awk '{print $1}' <<<"$scan_line")"
    smart_options="$(sed -E 's/^[^[:space:]]+[[:space:]]*//' <<<"$scan_line")"

    printf "\n"
    printf "%b\n" "${BOLD}${WHITE}${device}${RESET}"

    if [[ -n "$smart_options" ]]; then
        # shellcheck disable=SC2206
        local option_array=( $smart_options )
        smart_data="$(smartctl -x "${option_array[@]}" "$device" 2>&1)"
        smart_status=$?
    else
        smart_data="$(smartctl -x "$device" 2>&1)"
        smart_status=$?
    fi

    # smartctl uses bitmask exit statuses. Some non-zero statuses still
    # include useful SMART information, so only reject clearly unreadable
    # devices.
    if grep -Eqi 'Permission denied|Unable to detect device type|No such device|Device open failed' <<<"$smart_data"; then
        print_asap "SMART data could not be read."
        printf "%s\n" "$smart_data" | sed 's/^/       /'
        add_asap "SMART data could not be read for ${device}."
        return
    fi

    model="$(
        printf "%s\n" "$smart_data" |
            awk -F: '
                /Device Model|Model Number|Product/ {
                    value = $2
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                    print value
                    exit
                }
            '
    )"

    serial="$(
        printf "%s\n" "$smart_data" |
            awk -F: '
                /Serial Number/ {
                    value = $2
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                    print value
                    exit
                }
            '
    )"

    [[ -n "$model" ]] && printf "%b\n" "${BOLD}Model:${RESET} ${model}"
    [[ -n "$serial" ]] && printf "%b\n" "${BOLD}Serial:${RESET} ${serial}"

    health_line="$(
        printf "%s\n" "$smart_data" |
            grep -Ei 'SMART overall-health self-assessment test result|SMART Health Status|SMART overall-health' |
            head -n 1 ||
            true
    )"

    if [[ -z "$health_line" ]]; then
        nvme_critical_warning="$(get_nvme_value "$smart_data" "Critical Warning")"

        if [[ "$nvme_critical_warning" =~ ^0x0+$ ]] || [[ "$nvme_critical_warning" == "0" ]]; then
            print_good "Overall SMART health: PASSED"
            add_good "${device} passed its overall SMART health assessment."
        elif [[ -n "$nvme_critical_warning" ]]; then
            print_critical "NVMe critical warning: ${nvme_critical_warning}"
            add_critical "${device} reports an NVMe critical warning."
        else
            print_info "Overall SMART health: unavailable"
        fi
    elif grep -Eqi 'PASSED|OK' <<<"$health_line"; then
        print_good "Overall SMART health: PASSED"
        add_good "${device} passed its overall SMART health assessment."
    else
        print_critical "Overall SMART health: FAILED"
        add_critical "${device} failed its overall SMART health assessment."
    fi

    temperature="$(get_temperature "$smart_data")"
    classify_temperature "$device" "$temperature"

    reallocated="$(get_smart_value "$smart_data" "Reallocated_Sector_Ct|Reallocated_Event_Count")"
    pending="$(get_smart_value "$smart_data" "Current_Pending_Sector")"
    offline_uncorrectable="$(get_smart_value "$smart_data" "Offline_Uncorrectable")"

    classify_sector_value \
        "$device" \
        "Reallocated sectors" \
        "$reallocated" \
        "no reallocated sectors" \
        "asap"

    classify_sector_value \
        "$device" \
        "Pending sectors" \
        "$pending" \
        "no pending sectors" \
        "critical"

    classify_sector_value \
        "$device" \
        "Offline uncorrectable sectors" \
        "$offline_uncorrectable" \
        "no offline uncorrectable sectors" \
        "critical"

    nvme_media_errors="$(get_nvme_value "$smart_data" "Media and Data Integrity Errors")"

    if [[ -n "$nvme_media_errors" ]]; then
        nvme_media_errors="${nvme_media_errors//,/}"
        nvme_media_errors="$(trim_whitespace "$nvme_media_errors")"

        if is_nonnegative_integer "$nvme_media_errors"; then
            if (( nvme_media_errors == 0 )); then
                print_good "NVMe media and data integrity errors: 0"
                add_good "${device} reports no NVMe media or data integrity errors."
            else
                print_critical "NVMe media and data integrity errors: ${nvme_media_errors}"
                add_critical "${device} reports ${nvme_media_errors} NVMe media or data integrity errors."
            fi
        fi
    fi

    last_test="$(get_last_self_test "$smart_data")"

    if [[ "$last_test" == "No self-test history found" ]]; then
        print_maintenance "Last self-test: no self-test history found"
        add_maintenance "${device} has no recorded SMART self-test history."
    elif grep -Eqi 'Completed without error' <<<"$last_test"; then
        print_good "Last self-test: ${last_test}"
        add_good "${device}'s most recent SMART self-test completed without error."
    elif grep -Eqi 'Interrupted|Aborted|In progress' <<<"$last_test"; then
        print_asap "Last self-test: ${last_test}"
        add_asap "${device}'s most recent SMART self-test did not complete normally."
    else
        print_critical "Last self-test: ${last_test}"
        add_critical "${device}'s most recent SMART self-test reported a problem."
    fi

    # Preserve smartctl's status for future debugging without treating every
    # non-zero bitmask as a failed read.
    if (( smart_status != 0 )); then
        printf "%b\n" "${DIM}smartctl returned status ${smart_status}; SMART attributes above were still evaluated.${RESET}"
    fi
}

check_smart() {
    print_section "SMART Drive Health"

    printf "%b\n" "${DIM}Temperature guidance: below 50°C healthy, 50-59°C elevated, 60°C or higher critical.${RESET}"

    if ! command_exists smartctl; then
        print_maintenance "smartctl is not installed."
        printf "%b\n" "Install it with:"
        printf "\n"
        printf "%b\n" "${BOLD}apt install smartmontools${RESET}"
        add_maintenance "SMART checks require the smartmontools package."
        return
    fi

    local scan_output
    local drive_count=0
    local scan_line

    scan_output="$(smartctl --scan-open 2>/dev/null || smartctl --scan 2>/dev/null || true)"

    if [[ -z "$scan_output" ]]; then
        print_asap "No SMART-capable drives were detected."
        add_asap "No SMART-capable drives were detected."
        return
    fi

    while IFS= read -r scan_line; do
        [[ -z "$scan_line" ]] && continue
        [[ "$scan_line" =~ ^# ]] && continue

        drive_count=$((drive_count + 1))
        check_smart_device "$scan_line"
    done <<<"$scan_output"

    if (( drive_count == 0 )); then
        print_asap "No SMART-capable drives were detected."
        add_asap "No SMART-capable drives were detected."
    fi
}

# ------------------------------------------------------------
# Failed systemd services
# ------------------------------------------------------------

check_failed_services() {
    print_section "Failed systemd Services"

    if ! command_exists systemctl; then
        print_asap "systemctl is not available."
        add_asap "Failed services could not be checked because systemctl is unavailable."
        return
    fi

    local failed_services
    local failed_count

    failed_services="$(
        systemctl --failed --no-legend --no-pager 2>/dev/null |
            sed '/^[[:space:]]*$/d'
    )"

    if [[ -z "$failed_services" ]]; then
        print_good "No failed systemd services were found."
        add_good "No failed systemd services were found."
        return
    fi

    failed_count="$(printf "%s\n" "$failed_services" | wc -l | tr -d ' ')"

    print_asap "${failed_count} failed systemd service(s) were found."
    printf "\n"

    while IFS= read -r service_line; do
        [[ -n "$service_line" ]] && printf "  - %s\n" "$service_line"
    done <<<"$failed_services"

    add_asap "${failed_count} systemd service(s) are currently failed."
}

# ------------------------------------------------------------
# Network and DNS
# ------------------------------------------------------------

check_network() {
    print_section "Network and DNS"

    if ! command_exists ip; then
        print_asap "The ip command is unavailable."
        add_asap "The default gateway could not be checked."
        return
    fi

    local default_route
    local gateway
    local interface

    default_route="$(ip -4 route show default 2>/dev/null | head -n 1)"

    if [[ -z "$default_route" ]]; then
        print_asap "No IPv4 default route is configured."
        add_asap "No IPv4 default route is configured."
    else
        gateway="$(
            awk '
                {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "via") {
                            print $(i + 1)
                            exit
                        }
                    }
                }
            ' <<<"$default_route"
        )"

        interface="$(
            awk '
                {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "dev") {
                            print $(i + 1)
                            exit
                        }
                    }
                }
            ' <<<"$default_route"
        )"

        if [[ -n "$gateway" ]]; then
            print_good "Default gateway configured: ${gateway} via ${interface:-unknown interface}"
            add_good "A default gateway is configured."

            if command_exists ping; then
                if ping -c 2 -W 2 "$gateway" >/dev/null 2>&1; then
                    print_good "Default gateway is reachable."
                    add_good "The default gateway is reachable."
                else
                    print_asap "Default gateway ${gateway} did not respond to ping."
                    add_asap "The default gateway did not respond to the connectivity check."
                fi
            else
                print_info "ping is unavailable; gateway reachability was not tested."
            fi
        else
            print_info "A default route exists without a separate gateway address."
            add_good "A default route is configured."
        fi
    fi

    if ! command_exists getent; then
        print_asap "getent is unavailable; DNS resolution was not tested."
        add_asap "DNS resolution could not be tested."
        return
    fi

    if getent ahosts debian.org >/dev/null 2>&1; then
        print_good "DNS resolution is working."
        add_good "DNS resolution is working."
    else
        print_asap "DNS resolution failed for debian.org."
        add_asap "DNS resolution is not working correctly."
    fi
}

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

print_summary_group() {
    local heading="$1"
    local color="$2"
    shift 2

    local -a items=("$@")
    local item

    printf "\n"
    printf "%b\n" "${BOLD}${color}${heading} (${#items[@]})${RESET}"

    if (( ${#items[@]} == 0 )); then
        printf "  None\n"
        return
    fi

    for item in "${items[@]}"; do
        printf "  - %s\n" "$item"
    done
}

print_summary() {
    print_section "Health Summary"

    print_summary_group \
        "GOOD TO GO" \
        "$GREEN" \
        "${GOOD_ITEMS[@]}"

    print_summary_group \
        "MAINTENANCE DUE" \
        "$YELLOW" \
        "${MAINTENANCE_ITEMS[@]}"

    print_summary_group \
        "ADDRESS ASAP" \
        "$YELLOW" \
        "${ASAP_ITEMS[@]}"

    print_summary_group \
        "CRITICAL" \
        "$RED" \
        "${CRITICAL_ITEMS[@]}"

    printf "\n"
    printf "%b\n" "${BOLD}${CYAN}Overall Result${RESET}"

    if (( ${#CRITICAL_ITEMS[@]} > 0 )); then
        printf "%b\n" "${RED}${BOLD}CRITICAL ISSUES FOUND${RESET}"
        printf "%b\n" "Review the Critical section immediately."
    elif (( ${#ASAP_ITEMS[@]} > 0 )); then
        printf "%b\n" "${YELLOW}${BOLD}ATTENTION REQUIRED${RESET}"
        printf "%b\n" "No critical issues were found, but one or more items should be addressed soon."
    elif (( ${#MAINTENANCE_ITEMS[@]} > 0 )); then
        printf "%b\n" "${YELLOW}${BOLD}HEALTHY WITH MAINTENANCE DUE${RESET}"
        printf "%b\n" "The host appears healthy, with routine maintenance waiting."
    else
        printf "%b\n" "${GREEN}${BOLD}GOOD TO GO${RESET}"
        printf "%b\n" "No health problems or pending maintenance were detected."
    fi

    printf "\n"
    printf "%b\n" "${DIM}Health check completed: $(date '+%Y-%m-%d %H:%M:%S %Z')${RESET}"
    printf "\n"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {
    check_root
    detect_host

    print_header

    check_uptime
    check_storage
    check_package_updates
    check_smart
    check_failed_services
    check_network
    print_summary
}

main "$@"
