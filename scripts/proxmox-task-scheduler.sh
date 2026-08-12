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

  default_timezone=$(detect_timezone)

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

  read -r height width < <(dialog_size 18 78)
  menu_height=$((height - 8))
  (( menu_height < 1 )) && menu_height=1
  (( menu_height > 8 )) && menu_height=8

  whiptail \
    --title "$APP_NAME - New Task" \
    --menu "What task should be scheduled?" "$height" "$width" "$menu_height" \
    "update" "Update packages" \
    "reboot" "Reboot" \
    "restart-service" "Restart a service" \
    "backup" "Run a Proxmox backup" \
    "custom" "Custom command" \
    3>&1 1>&2 2>&3
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
  local schedule_type
  local height width menu_height

  read -r height width < <(dialog_size 18 78)
  menu_height=$((height - 8))
  (( menu_height < 1 )) && menu_height=1
  (( menu_height > 8 )) && menu_height=8

  schedule_type=$(
    whiptail \
      --title "$APP_NAME - $task_name Schedule" \
      --menu "How often should $task_name run?" "$height" "$width" "$menu_height" \
      "daily" "Every day" \
      "weekly" "Selected day each week" \
      "monthly" "Selected date each month" \
      "custom" "Select multiple days, dates, or months" \
      3>&1 1>&2 2>&3
  ) || return 1

  local run_time
  local weekday
  local month_day
  local calendar

  case "$schedule_type" in
    daily)
      run_time=$(choose_time "$timezone" "$task_name") || return 1
      calendar="*-*-* $run_time:00 $timezone"
      ;;

    weekly)
      read -r height width < <(dialog_size 18 60)
      menu_height=$((height - 8))
      (( menu_height < 1 )) && menu_height=1
      (( menu_height > 7 )) && menu_height=7

      weekday=$(
        whiptail \
          --title "$APP_NAME" \
          --menu "Choose the day of the week." "$height" "$width" "$menu_height" \
          "Mon" "Monday" \
          "Tue" "Tuesday" \
          "Wed" "Wednesday" \
          "Thu" "Thursday" \
          "Fri" "Friday" \
          "Sat" "Saturday" \
          "Sun" "Sunday" \
          3>&1 1>&2 2>&3
      ) || return 1

      run_time=$(choose_time "$timezone" "$task_name") || return 1
      calendar="$weekday *-*-* $run_time:00 $timezone"
      ;;

    monthly)
      month_day=$(
        input_box \
          "Enter the day of the month (1-31)." \
          "1"
      ) || return 1

      [[ $month_day =~ ^([1-9]|[12][0-9]|3[01])$ ]] ||
        {
          message_box "Please use a day from 1 through 31."
          return 1
        }

      run_time=$(choose_time "$timezone" "$task_name") || return 1
      calendar="*-*-$month_day $run_time:00 $timezone"
      ;;

    custom)
      local -a selected_weekdays=()
      local -a selected_days=()
      local -a selected_months=()
      local weekdays="*"
      local days="*"
      local months="*"
      local selection

      selection=$(choose_multiple \
        "$APP_NAME - $task_name Schedule" \
        "Select weekdays, or leave all unchecked for any weekday." \
        Mon Monday OFF Tue Tuesday OFF Wed Wednesday OFF Thu Thursday OFF \
        Fri Friday OFF Sat Saturday OFF Sun Sunday OFF) || return 1
      [[ -n $selection ]] && mapfile -t selected_weekdays <<<"$selection"

      selection=$(choose_multiple \
        "$APP_NAME - $task_name Schedule" \
        "Select dates of the month, or leave all unchecked for any date." \
        1 1st OFF 2 2nd OFF 3 3rd OFF 4 4th OFF 5 5th OFF 6 6th OFF 7 7th OFF \
        8 8th OFF 9 9th OFF 10 10th OFF 11 11th OFF 12 12th OFF 13 13th OFF \
        14 14th OFF 15 15th OFF 16 16th OFF 17 17th OFF 18 18th OFF 19 19th OFF \
        20 20th OFF 21 21st OFF 22 22nd OFF 23 23rd OFF 24 24th OFF 25 25th OFF \
        26 26th OFF 27 27th OFF 28 28th OFF 29 29th OFF 30 30th OFF 31 31st OFF) || return 1
      [[ -n $selection ]] && mapfile -t selected_days <<<"$selection"

      selection=$(choose_multiple \
        "$APP_NAME - $task_name Schedule" \
        "Select months, or leave all unchecked for every month." \
        01 January OFF 02 February OFF 03 March OFF 04 April OFF \
        05 May OFF 06 June OFF 07 July OFF 08 August OFF \
        09 September OFF 10 October OFF 11 November OFF 12 December OFF) || return 1
      [[ -n $selection ]] && mapfile -t selected_months <<<"$selection"

      ((${#selected_weekdays[@]})) && weekdays=$(join_by_comma "${selected_weekdays[@]}")
      ((${#selected_days[@]})) && days=$(join_by_comma "${selected_days[@]}")
      ((${#selected_months[@]})) && months=$(join_by_comma "${selected_months[@]}")

      run_time=$(choose_time "$timezone" "$task_name") || return 1
      calendar="$weekdays *-$months-$days $run_time:00 $timezone"
      ;;

    *)
      return 1
      ;;
  esac

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

add_task() {
  local task_type
  local task_name
  local description
  local target
  local command_text
  local timezone
  local calendar
  local slug

  task_type=$(choose_task_type) || return

  case "$task_type" in
    update)
      task_name="Package Update"
      command_text="apt-get update && apt-get -y full-upgrade"
      ;;

    reboot)
      task_name="Reboot"
      command_text="systemctl reboot"
      ;;

    restart-service)
      task_name="Service Restart"
      local service_name
      service_name=$(input_box \
        "Enter the systemd service name to restart.

Examples: pveproxy, docker, ssh" "") || return

      [[ $service_name =~ ^[A-Za-z0-9@_.:-]+$ ]] || {
        message_box "Use a valid systemd service name."
        return
      }
      command_text="systemctl restart -- $service_name"
      ;;

    backup)
      task_name="Proxmox Backup"
      local backup_target
      backup_target=$(input_box \
        "Enter one VM/CT ID to back up, or enter all.

The backup uses snapshot mode and your configured default storage." "all") || return

      if [[ $backup_target == "all" ]]; then
        command_text="vzdump --all 1 --mode snapshot"
      elif [[ $backup_target =~ ^[0-9]+$ ]]; then
        command_text="vzdump $backup_target --mode snapshot"
      else
        message_box "Enter one numeric VM/CT ID or all."
        return
      fi
      ;;

    custom)
      task_name="Custom Command"
      command_text=$(input_box \
        "Enter the command exactly as it should run.

Passwords and other secrets should not be placed here." "") || return
      [[ -n $command_text ]] || {
        message_box "A command is required."
        return
      }
      ;;

    *)
      return
      ;;
  esac

  description=$(
    input_box "Enter a short description for this task." "$task_name"
  ) || return

  [[ -n $description ]] ||
    {
      message_box "A description is required."
      return
    }

  slug=$(make_slug "$description")

  [[ -n $slug ]] ||
    {
      message_box \
        "The description needs at least one letter or number."
      return
    }

  if [[ -e "$CONFIG_DIR/$slug.conf" ||
        -e "$SYSTEMD_DIR/$UNIT_PREFIX-$slug.timer" ]]; then

    message_box \
      "A task named '$slug' already exists.

Use a different description."

    return
  fi

  target=$(
    input_box \
      "Where should the command run?

Use local for the Proxmox host, or enter an SSH destination such as root@10.10.10.201." \
      "local"
  ) || return

  if ! validate_target "$target"; then
    message_box \
      "Use either:

local

or a destination such as:
root@10.10.10.201"

    return
  fi

  if ! test_ssh_target "$target"; then
    message_box \
      "Passwordless SSH is not ready for:

$target

From the Proxmox shell, run:

ssh-copy-id $target
ssh $target true

Then run this scheduler again."

    return
  fi

  timezone=$(choose_timezone) || return
  calendar=$(choose_schedule "$timezone" "$task_name") || return

  local confirmation

  confirmation=$(
    printf \
      'Description: %s\nTarget: %s\nTimezone: %s\nSchedule: %s\nCommand: %s' \
      "$description" \
      "$target" \
      "$timezone" \
      "$calendar" \
      "$command_text"
  )

  local height width
  read -r height width < <(dialog_size 20 86)

  whiptail \
    --title "$APP_NAME" \
    --yesno "Create this task?

$confirmation" "$height" "$width" ||
    return

  local command_b64
  local runner_path
  local service_path
  local timer_path
  local metadata_path

  command_b64=$(
    printf '%s' "$command_text" |
      base64 |
      tr -d '\n'
  )

  runner_path="$JOB_DIR/$slug.sh"
  service_path="$SYSTEMD_DIR/$UNIT_PREFIX-$slug.service"
  timer_path="$SYSTEMD_DIR/$UNIT_PREFIX-$slug.timer"
  metadata_path="$CONFIG_DIR/$slug.conf"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf 'readonly TARGET=%q\n' "$target"
    printf 'readonly COMMAND_B64=%q\n' "$command_b64"
    printf '%s\n' 'if [[ $TARGET == local ]]; then'
    printf '%s\n' \
      '  printf "%s" "$COMMAND_B64" | base64 --decode | /bin/bash'
    printf '%s\n' 'else'
    printf '%s\n' \
      '  printf "%s" "$COMMAND_B64" | base64 --decode | /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=30 "$TARGET" /bin/bash'
    printf '%s\n' 'fi'
  } >"$runner_path"

  chmod 700 "$runner_path"

  local safe_description=${description//$'\n'/ }
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

  write_metadata \
    "$metadata_path" \
    "$description" \
    "$target" \
    "$calendar" \
    "$timezone"

  systemctl daemon-reload
  systemctl enable --now "$UNIT_PREFIX-$slug.timer"

  local next_run

  next_run=$(
    systemd-analyze calendar "$calendar" 2>/dev/null ||
      true
  )

  message_box \
    "Task created successfully.

Name: $slug
Timezone: $timezone

$next_run"
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
        add_task
        ;;

      list)
        list_tasks
        ;;

      run)
        run_task_now
        ;;

      logs)
        view_logs
        ;;

      remove)
        remove_task
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

main "$@"
