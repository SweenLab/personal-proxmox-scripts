#!/usr/bin/env bash

set -Eeuo pipefail

readonly APP_NAME="Proxmox Task Scheduler"
readonly UNIT_PREFIX="proxmox-task"
readonly CONFIG_DIR="/etc/proxmox-task-scheduler"
readonly JOB_DIR="/usr/local/lib/proxmox-task-scheduler/jobs"
readonly SYSTEMD_DIR="/etc/systemd/system"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] ||
    die "Run this script as root on the Proxmox host."
}

install_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return

  command -v apt-get >/dev/null 2>&1 ||
    die "whiptail is required and apt-get was not found."

  printf 'whiptail is required for the menu interface.\n'
  read -r -p "Install it now with apt-get? [Y/n] " answer

  case "${answer:-Y}" in
    [Yy]*)
      apt-get update
      apt-get install -y whiptail
      ;;
    *)
      die "whiptail was not installed."
      ;;
  esac
}

require_commands() {
  local command_name

  for command_name in \
    systemctl \
    systemd-analyze \
    timedatectl \
    base64 \
    ssh \
    pct \
    qm \
    awk \
    sed \
    tr \
    grep; do

    command -v "$command_name" >/dev/null 2>&1 ||
      die "Required command not found: $command_name"
  done
}

prepare_directories() {
  install -d -m 700 "$CONFIG_DIR" "$JOB_DIR"
}

dialog_size() {
  local preferred_height=$1
  local preferred_width=$2
  local terminal_height
  local terminal_width

  terminal_height=$(tput lines 2>/dev/null || printf '%s' "${LINES:-24}")
  terminal_width=$(tput cols 2>/dev/null || printf '%s' "${COLUMNS:-80}")

  [[ $terminal_height =~ ^[0-9]+$ ]] || terminal_height=24
  [[ $terminal_width =~ ^[0-9]+$ ]] || terminal_width=80

  (( preferred_height > terminal_height - 2 )) && preferred_height=$((terminal_height - 2))
  (( preferred_width > terminal_width - 2 )) && preferred_width=$((terminal_width - 2))

  (( preferred_height < 1 )) && preferred_height=1
  (( preferred_width < 1 )) && preferred_width=1

  printf '%s %s\n' "$preferred_height" "$preferred_width"
}

input_box() {
  local prompt=$1
  local default_value=${2:-}
  local height width

  read -r height width < <(dialog_size 11 78)

  whiptail \
    --title "$APP_NAME" \
    --cancel-button "Back" \
    --inputbox "$prompt" "$height" "$width" "$default_value" \
    3>&1 1>&2 2>&3
}

message_box() {
  local height width

  read -r height width < <(dialog_size 14 78)

  whiptail \
    --title "$APP_NAME" \
    --msgbox "$1" "$height" "$width"
}

show_text() {
  local title=$1
  local content=$2
  local temporary_file
  local height width

  temporary_file=$(mktemp)
  printf '%s\n' "$content" >"$temporary_file"
  read -r height width < <(dialog_size 22 90)

  whiptail \
    --title "$title" \
    --scrolltext \
    --textbox "$temporary_file" "$height" "$width"

  rm -f "$temporary_file"
}

make_slug() {
  local description=$1
  local slug

  slug=$(
    printf '%s' "$description" |
      tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
  )

  printf '%.48s' "$slug"
}

detect_timezone() {
  local detected_timezone

  detected_timezone=$(
    timedatectl show \
      --property=Timezone \
      --value 2>/dev/null ||
      true
  )

  if [[ -z $detected_timezone && -r /etc/timezone ]]; then
    detected_timezone=$(< /etc/timezone)
  fi

  if [[ -z $detected_timezone ]]; then
    detected_timezone="UTC"
  fi

  printf '%s' "$detected_timezone"
}

validate_timezone() {
  local timezone=$1

  [[ -n $timezone ]] || return 1

  timedatectl list-timezones 2>/dev/null |
    grep -Fxq -- "$timezone"
}

choose_timezone() {
  local default_timezone
  local selected_timezone

  default_timezone=${1:-$(detect_timezone)}

  while true; do
    selected_timezone=$(
      input_box \
        "Enter the timezone for this task.

The Proxmox host timezone was detected as:
$default_timezone

Use an IANA timezone such as:
America/New_York
America/Chicago
America/Los_Angeles
Europe/London

Press Enter to use the displayed timezone." \
        "$default_timezone"
    ) || return 1

    if validate_timezone "$selected_timezone"; then
      printf '%s' "$selected_timezone"
      return
    fi

    message_box \
      "That timezone was not recognized:

$selected_timezone

Use a complete IANA timezone name, such as:

America/New_York
America/Chicago
America/Los_Angeles
Europe/London"
  done
}

validate_time() {
  [[ $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

choose_time() {
  local timezone=$1
  local task_name=${2:-Task}
  local value

  while true; do
    value=$(
      input_box \
        "$task_name schedule

Enter the time in $timezone using 24-hour HH:MM format." \
        "03:00"
    ) || return 1

    if validate_time "$value"; then
      printf '%s' "$value"
      return
    fi

    message_box \
      "That time is not valid.

Example: 03:30 or 17:45"
  done
}

choose_task_type() {
  local height width menu_height
  local selection

  read -r height width < <(dialog_size 18 78)
  menu_height=$((height - 8))
  (( menu_height < 1 )) && menu_height=1
  (( menu_height > 8 )) && menu_height=8

  selection=$(
    whiptail \
      --title "$APP_NAME - New Task" \
      --cancel-button "Back" \
      --menu "What task should be scheduled?" "$height" "$width" "$menu_height" \
      "update" "Update packages" \
      "reboot" "Reboot" \
      "restart-service" "Restart a service" \
      "backup" "Run a Proxmox backup" \
      "custom" "Custom command" \
      3>&1 1>&2 2>&3
  ) || {
    printf '%s' "back"
    return 0
  }

  printf '%s' "$selection"
}

choose_multiple() {
  local title=$1
  local prompt=$2
  shift 2
  local height width list_height

  read -r height width < <(dialog_size 22 78)
  list_height=$((height - 8))
  (( list_height < 1 )) && list_height=1
  (( list_height > 14 )) && list_height=14

  whiptail \
    --title "$title" \
    --cancel-button "Back" \
    --separate-output \
    --checklist "$prompt" "$height" "$width" "$list_height" \
    "$@" \
    3>&1 1>&2 2>&3
}

join_by_comma() {
  local IFS=,
  printf '%s' "$*"
}

choose_schedule() {
  local timezone=$1
  local task_name=${2:-Task}
  local run_time
  local calendar
  local -a selected_weekdays=()
  local -a selected_days=()
  local -a selected_months=()
  local weekdays="*"
  local days="*"
  local months="*"
  local selection

  selection=$(choose_multiple \
    "$APP_NAME - $task_name Schedule" \
    "Select weekdays with Space, then press Enter. Leave all unchecked for every weekday." \
    Mon Monday OFF Tue Tuesday OFF Wed Wednesday OFF Thu Thursday OFF \
    Fri Friday OFF Sat Saturday OFF Sun Sunday OFF) || return 1
  [[ -n $selection ]] && mapfile -t selected_weekdays <<<"$selection"

  selection=$(choose_multiple \
    "$APP_NAME - $task_name Schedule" \
    "Select dates with Space, then press Enter. Leave all unchecked for every date." \
    1 1st OFF 2 2nd OFF 3 3rd OFF 4 4th OFF 5 5th OFF 6 6th OFF 7 7th OFF \
    8 8th OFF 9 9th OFF 10 10th OFF 11 11th OFF 12 12th OFF 13 13th OFF \
    14 14th OFF 15 15th OFF 16 16th OFF 17 17th OFF 18 18th OFF 19 19th OFF \
    20 20th OFF 21 21st OFF 22 22nd OFF 23 23rd OFF 24 24th OFF 25 25th OFF \
    26 26th OFF 27 27th OFF 28 28th OFF 29 29th OFF 30 30th OFF 31 31st OFF) || return 1
  [[ -n $selection ]] && mapfile -t selected_days <<<"$selection"

  selection=$(choose_multiple \
    "$APP_NAME - $task_name Schedule" \
    "Select months with Space, then press Enter. Leave all unchecked for every month." \
    01 January OFF 02 February OFF 03 March OFF 04 April OFF \
    05 May OFF 06 June OFF 07 July OFF 08 August OFF \
    09 September OFF 10 October OFF 11 November OFF 12 December OFF) || return 1
  [[ -n $selection ]] && mapfile -t selected_months <<<"$selection"

  ((${#selected_weekdays[@]})) && weekdays=$(join_by_comma "${selected_weekdays[@]}")
  ((${#selected_days[@]})) && days=$(join_by_comma "${selected_days[@]}")
  ((${#selected_months[@]})) && months=$(join_by_comma "${selected_months[@]}")

  run_time=$(choose_time "$timezone" "$task_name") || return 1
  calendar="$weekdays *-$months-$days $run_time:00 $timezone"

  if ! systemd-analyze calendar "$calendar" >/dev/null 2>&1; then
    message_box \
      "The schedule could not be understood:

$calendar"
    return 1
  fi

  printf '%s' "$calendar"
}

validate_target() {
  local target=$1

  [[ $target == "local" ]] ||
    [[ $target =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]]
}

test_ssh_target() {
  local target=$1

  [[ $target == "local" ]] && return 0

  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new \
    "$target" true >/dev/null 2>&1
}

write_metadata() {
  local path=$1
  local description=$2
  local target=$3
  local calendar=$4
  local timezone=$5

  {
    printf 'DESCRIPTION=%q\n' "$description"
    printf 'TARGET=%q\n' "$target"
    printf 'CALENDAR=%q\n' "$calendar"
    printf 'TIMEZONE=%q\n' "$timezone"
  } >"$path"

  chmod 600 "$path"
}

guest_choices() {
  local kind=$1
  local id status name line
  local -a fields=()

  if [[ $kind == "lxc" ]]; then
    while IFS= read -r line; do
      read -r -a fields <<<"$line"
      id=${fields[0]:-}
      [[ $id =~ ^[0-9]+$ ]] || continue
      status=${fields[1]:-unknown}
      name=${fields[${#fields[@]}-1]:-LXC $id}
      printf '%s\n%s (%s)\n' "$id" "${name:-LXC $id}" "$status"
    done < <(pct list 2>/dev/null)
  else
    while read -r id name status _; do
      [[ $id =~ ^[0-9]+$ ]] || continue
      printf '%s\n%s (%s)\n' "$id" "${name:-VM $id}" "$status"
    done < <(qm list 2>/dev/null)
  fi
}

select_guests() {
  local kind=$1
  local label=$2
  local -a choices=("all" "Select all $label" OFF)
  local -a discovered=()
  local id description

  mapfile -t discovered < <(guest_choices "$kind")
  if ((${#discovered[@]} == 0)); then
    message_box "No $label were found on this Proxmox host."
    return 1
  fi

  while ((${#discovered[@]})); do
    id=${discovered[0]}
    description=${discovered[1]}
    choices+=("$id" "$description" OFF)
    discovered=("${discovered[@]:2}")
  done

  choose_multiple \
    "$APP_NAME - Select $label" \
    "Select the $label you would like to schedule, or choose Select all for a bulk task." \
    "${choices[@]}"
}

select_all_guests() {
  local -a choices=("all" "All LXCs and VMs" OFF)
  local -a discovered=()
  local id description

  mapfile -t discovered < <(guest_choices lxc)
  while ((${#discovered[@]})); do
    id=${discovered[0]}
    description=${discovered[1]}
    choices+=("lxc:$id" "LXC $description" OFF)
    discovered=("${discovered[@]:2}")
  done

  mapfile -t discovered < <(guest_choices vm)
  while ((${#discovered[@]})); do
    id=${discovered[0]}
    description=${discovered[1]}
    choices+=("vm:$id" "VM $description" OFF)
    discovered=("${discovered[@]:2}")
  done

  ((${#choices[@]} > 3)) || {
    message_box "No LXCs or VMs were found on this Proxmox host."
    return 1
  }

  choose_multiple \
    "$APP_NAME - Select Guests" \
    "Select guests, or choose All LXCs and VMs." \
    "${choices[@]}"
}

ask_bulk() {
  local label=$1
  simple_menu "$APP_NAME - Scheduling Method" \
    "How should the selected $label be scheduled?" \
    together "Run all selected items together" \
    individually "Set a separate schedule for each item"
}

create_scheduled_task() {
  local description=$1
  local command_text=$2
  local timezone=$3
  local calendar=$4
  local slug
  local suffix=2
  local command_b64 runner_path service_path timer_path metadata_path safe_description

  slug=$(make_slug "$description")
  while [[ -e "$CONFIG_DIR/$slug.conf" ||
           -e "$SYSTEMD_DIR/$UNIT_PREFIX-$slug.timer" ]]; do
    slug="$(make_slug "$description")-$suffix"
    ((suffix += 1))
  done

  command_b64=$(printf '%s' "$command_text" | base64 | tr -d '\n')
  runner_path="$JOB_DIR/$slug.sh"
  service_path="$SYSTEMD_DIR/$UNIT_PREFIX-$slug.service"
  timer_path="$SYSTEMD_DIR/$UNIT_PREFIX-$slug.timer"
  metadata_path="$CONFIG_DIR/$slug.conf"

  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
    printf 'readonly COMMAND_B64=%q\n' "$command_b64"
    printf '%s\n' 'printf "%s" "$COMMAND_B64" | base64 --decode | /bin/bash'
  } >"$runner_path"
  chmod 700 "$runner_path"

  safe_description=${description//$'\n'/ }
  safe_description=${safe_description//%/%%}
  cat >"$service_path" <<EOF
[Unit]
Description=Scheduled task: $safe_description
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$runner_path
EOF

  cat >"$timer_path" <<EOF
[Unit]
Description=Timer for: $safe_description

[Timer]
OnCalendar=$calendar
Persistent=true
Unit=$UNIT_PREFIX-$slug.service

[Install]
WantedBy=timers.target
EOF

  write_metadata "$metadata_path" "$description" "local" "$calendar" "$timezone"
  systemctl daemon-reload
  systemctl enable --now "$UNIT_PREFIX-$slug.timer" >/dev/null
}

contains_selection() {
  local needle=$1
  shift
  local item
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

simple_menu() {
  local title=$1
  local prompt=$2
  shift 2
  local height width menu_height
  read -r height width < <(dialog_size 18 78)
  menu_height=$((height - 8))
  ((menu_height < 1)) && menu_height=1

  whiptail \
    --title "$title" \
    --cancel-button "Back" \
    --menu "$prompt" "$height" "$width" "$menu_height" \
    "$@" \
    3>&1 1>&2 2>&3
}

select_reboot_targets() {
  local -a choices=(host "Proxmox host (must be selected alone)" OFF)
  local -a discovered=()
  local id description

  mapfile -t discovered < <(guest_choices lxc)
  while ((${#discovered[@]})); do
    id=${discovered[0]}; description=${discovered[1]}
    choices+=("lxc:$id" "LXC $description" OFF)
    discovered=("${discovered[@]:2}")
  done
  mapfile -t discovered < <(guest_choices vm)
  while ((${#discovered[@]})); do
    id=${discovered[0]}; description=${discovered[1]}
    choices+=("vm:$id" "VM $description" OFF)
    discovered=("${discovered[@]:2}")
  done

  choose_multiple "$APP_NAME - Reboot" \
    "Select the host, LXCs, or VMs to reboot. The host cannot be combined with guests." \
    "${choices[@]}"
}

select_services() {
  choose_multiple "$APP_NAME - Restart Services" \
    "Select one or more services to restart." \
    ssh "SSH server" OFF \
    pveproxy "Proxmox web proxy" OFF \
    pvedaemon "Proxmox API daemon" OFF \
    pvestatd "Proxmox status daemon" OFF \
    pve-cluster "Proxmox cluster filesystem" OFF \
    corosync "Corosync cluster service" OFF \
    custom "Custom systemd service" OFF
}

completion_menu() {
  simple_menu "$APP_NAME - Tasks Created" \
    "The selected tasks were scheduled successfully. What would you like to do?" \
    back "Back to Add options" \
    main "Return to main menu" \
    exit "Exit scheduler"
}

add_task() {
  local task_type timezone target_type selection item id service custom_service
  local description command_text calendar post_action bulk_choice
  local -a selected=()
  local -a commands=()
  local -a descriptions=()
  local -a calendars=()

  while true; do
    task_type=$(choose_task_type)
    [[ $task_type == "back" ]] && return 0
    selected=()
    commands=()
    descriptions=()
    calendars=()

    case "$task_type" in
      update)
        target_type=$(simple_menu "$APP_NAME - Package Updates" \
          "What should receive package updates?" \
          host "Proxmox host" lxc "LXCs" vm "VMs") || continue
        if [[ $target_type == host ]]; then
          descriptions=("Host Package Update")
          commands=("apt-get update && apt-get -y full-upgrade")
        else
          selection=$(select_guests "$target_type" "$([[ $target_type == lxc ]] && printf LXCs || printf VMs)") || continue
          [[ -n $selection ]] && mapfile -t selected <<<"$selection"
          ((${#selected[@]})) || { message_box "Select at least one guest."; continue; }
          if contains_selection all "${selected[@]}"; then
            if [[ $target_type == lxc ]]; then
              descriptions=("Update All LXCs")
              commands=('pct list | awk '\''NR > 1 {print $1}'\'' | while read -r id; do pct exec "$id" -- bash -lc '\''apt-get update && apt-get -y full-upgrade'\''; done')
            else
              descriptions=("Update All VMs")
              commands=('qm list | awk '\''NR > 1 {print $1}'\'' | while read -r id; do qm guest exec "$id" -- /bin/bash -lc '\''apt-get update && apt-get -y full-upgrade'\''; done')
            fi
          else
            for id in "${selected[@]}"; do
              if [[ $target_type == lxc ]]; then
                descriptions+=("Update LXC $id")
                commands+=("pct exec $id -- bash -lc 'apt-get update && apt-get -y full-upgrade'")
              else
                descriptions+=("Update VM $id")
                commands+=("qm guest exec $id -- /bin/bash -lc 'apt-get update && apt-get -y full-upgrade'")
              fi
            done
          fi
        fi
        ;;

      reboot)
        selection=$(select_reboot_targets) || continue
        [[ -n $selection ]] && mapfile -t selected <<<"$selection"
        ((${#selected[@]})) || { message_box "Select at least one target."; continue; }
        if contains_selection host "${selected[@]}"; then
          ((${#selected[@]} == 1)) || { message_box "Host cannot be combined with LXC or VM reboots."; continue; }
          descriptions=("Reboot Proxmox Host")
          commands=("systemctl reboot")
        else
          for item in "${selected[@]}"; do
            id=${item#*:}
            if [[ $item == lxc:* ]]; then
              descriptions+=("Reboot LXC $id")
              commands+=("pct reboot $id")
            else
              descriptions+=("Reboot VM $id")
              commands+=("qm reboot $id")
            fi
          done
        fi
        ;;

      restart-service)
        selection=$(select_services) || continue
        [[ -n $selection ]] && mapfile -t selected <<<"$selection"
        ((${#selected[@]})) || { message_box "Select at least one service."; continue; }
        if contains_selection custom "${selected[@]}"; then
          custom_service=$(input_box "Enter the custom systemd service name." "") || continue
          [[ $custom_service =~ ^[A-Za-z0-9@_.:-]+$ ]] || { message_box "Use a valid systemd service name."; continue; }
        fi
        for service in "${selected[@]}"; do
          [[ $service == custom ]] && service=$custom_service
          descriptions+=("Restart $service Service")
          commands+=("systemctl restart -- $service")
        done
        ;;

      backup)
        selection=$(select_all_guests) || continue
        [[ -n $selection ]] && mapfile -t selected <<<"$selection"
        ((${#selected[@]})) || { message_box "Select at least one guest."; continue; }
        if contains_selection all "${selected[@]}"; then
          descriptions=("Backup All LXCs and VMs")
          commands=("vzdump --all 1 --mode snapshot")
        else
          for item in "${selected[@]}"; do
            id=${item#*:}
            if [[ $item == lxc:* ]]; then
              descriptions+=("Backup LXC $id")
            else
              descriptions+=("Backup VM $id")
            fi
            commands+=("vzdump $id --mode snapshot")
          done
        fi
        ;;

      custom)
        command_text=$(input_box \
          "Enter the command exactly as it should run.

Passwords and other secrets should not be placed here." "") || continue
        [[ -n $command_text ]] || { message_box "A command is required."; continue; }
        description=$(input_box "Enter a short description for this task." "Custom Command") || continue
        [[ -n $(make_slug "$description") ]] || { message_box "A description is required."; continue; }
        descriptions=("$description")
        commands=("$command_text")
        ;;
    esac

    timezone=$(choose_timezone "$(detect_timezone)") || continue

    if ((${#commands[@]} == 1)); then
      calendar=$(choose_schedule "$timezone" "${descriptions[0]}") || continue
      create_scheduled_task "${descriptions[0]}" "${commands[0]}" "$timezone" "$calendar"
    else
      bulk_choice=$(ask_bulk "tasks") || continue
      if [[ $bulk_choice == together ]]; then
        command_text=$(printf '%s\n' "${commands[@]}")
        description="Bulk ${descriptions[0]} and Selected Tasks"
        calendar=$(choose_schedule "$timezone" "$description") || continue
        create_scheduled_task "$description" "$command_text" "$timezone" "$calendar"
      else
        for ((id = 0; id < ${#commands[@]}; id++)); do
          calendar=$(choose_schedule "$timezone" "${descriptions[id]}") || break
          calendars+=("$calendar")
        done
        ((id == ${#commands[@]})) || continue
        for ((id = 0; id < ${#commands[@]}; id++)); do
          create_scheduled_task \
            "${descriptions[id]}" "${commands[id]}" "$timezone" "${calendars[id]}"
        done
      fi
    fi

    post_action=$(completion_menu) || return 0
    case "$post_action" in
      back) continue ;;
      main) return 0 ;;
      exit) return 10 ;;
    esac
  done
}

task_choices() {
  local config_file
  local slug

  shopt -s nullglob

  for config_file in "$CONFIG_DIR"/*.conf; do
    slug=${config_file##*/}
    slug=${slug%.conf}

    # Metadata files are root-owned and created by this script.
    # shellcheck disable=SC1090
    source "$config_file"

    printf '%s\n%s\n' \
      "$slug" \
      "${DESCRIPTION:-Scheduled task}"
  done

  shopt -u nullglob
}

select_task() {
  local -a choices=()

  mapfile -t choices < <(task_choices)

  if ((${#choices[@]} == 0)); then
    message_box "No managed tasks exist yet."
    return 1
  fi

  local height width menu_height
  read -r height width < <(dialog_size 20 86)
  menu_height=$((height - 8))
  (( menu_height < 1 )) && menu_height=1
  (( menu_height > 10 )) && menu_height=10

  whiptail \
    --title "$APP_NAME" \
    --menu "Choose a task." "$height" "$width" "$menu_height" \
    "${choices[@]}" \
    3>&1 1>&2 2>&3
}

list_tasks() {
  local output

  output=$(
    systemctl \
      list-timers \
      --all \
      "$UNIT_PREFIX-*.timer" \
      --no-pager 2>&1 ||
      true
  )

  show_text "Scheduled Tasks" "$output"
}

run_task_now() {
  local slug

  slug=$(select_task) || return

  systemctl start "$UNIT_PREFIX-$slug.service"

  local output

  output=$(
    journalctl \
      -u "$UNIT_PREFIX-$slug.service" \
      -n 40 \
      --no-pager 2>&1 ||
      true
  )

  show_text "Task Result: $slug" "$output"
}

view_logs() {
  local slug

  slug=$(select_task) || return

  local output

  output=$(
    journalctl \
      -u "$UNIT_PREFIX-$slug.service" \
      -n 100 \
      --no-pager 2>&1 ||
      true
  )

  show_text "Task Logs: $slug" "$output"
}

remove_task() {
  local slug
  local height width

  slug=$(select_task) || return
  read -r height width < <(dialog_size 13 76)

  whiptail \
    --title "$APP_NAME" \
    --yesno "Delete the task '$slug'?

Its service, timer, runner, and metadata will be removed." "$height" "$width" ||
    return

  systemctl \
    disable \
    --now \
    "$UNIT_PREFIX-$slug.timer" >/dev/null 2>&1 ||
    true

  rm -f \
    "$SYSTEMD_DIR/$UNIT_PREFIX-$slug.service" \
    "$SYSTEMD_DIR/$UNIT_PREFIX-$slug.timer" \
    "$JOB_DIR/$slug.sh" \
    "$CONFIG_DIR/$slug.conf"

  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  message_box "Task '$slug' was removed."
}

main_menu() {
  while true; do
    local action
    local height width menu_height

    read -r height width < <(dialog_size 20 78)
    menu_height=$((height - 8))
    (( menu_height < 1 )) && menu_height=1
    (( menu_height > 10 )) && menu_height=10

    action=$(
      whiptail \
        --title "$APP_NAME" \
        --menu "Create and manage scheduled commands." "$height" "$width" "$menu_height" \
        "add" "Add a scheduled task" \
        "list" "List scheduled tasks" \
        "run" "Run a task now" \
        "logs" "View task logs" \
        "remove" "Remove a task" \
        "exit" "Exit" \
        3>&1 1>&2 2>&3
    ) || break

    case "$action" in
      add)
        if add_task; then
          :
        elif [[ $? -eq 10 ]]; then
          break
        fi
        ;;

      list)
        list_tasks || true
        ;;

      run)
        run_task_now || true
        ;;

      logs)
        view_logs || true
        ;;

      remove)
        remove_task || true
        ;;

      exit)
        break
        ;;
    esac
  done
}

usage() {
  local detected_timezone

  detected_timezone=$(detect_timezone)

  cat <<EOF
$APP_NAME

Usage:
  sudo bash proxmox-task-scheduler.sh

Run this script as root on a Proxmox host. It creates and manages systemd
services and timers for local commands or commands sent over passwordless SSH.

When creating a task, the script detects the Proxmox host's timezone and lets
the user accept it or enter another valid IANA timezone.

Detected host timezone:
  $detected_timezone
EOF
}

main() {
  case "${1:-}" in
    -h | --help)
      require_commands
      usage
      exit 0
      ;;
  esac

  require_root
  install_whiptail
  require_commands
  prepare_directories
  main_menu
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
