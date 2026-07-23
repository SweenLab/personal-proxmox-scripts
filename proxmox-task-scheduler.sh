#!/usr/bin/env bash

set -Eeuo pipefail

readonly APP_NAME="Proxmox Task Scheduler"
readonly TIMEZONE="America/New_York"
readonly UNIT_PREFIX="proxmox-task"
readonly CONFIG_DIR="/etc/proxmox-task-scheduler"
readonly JOB_DIR="/usr/local/lib/proxmox-task-scheduler/jobs"
readonly SYSTEMD_DIR="/etc/systemd/system"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root on the Proxmox host."
}

install_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return
  command -v apt-get >/dev/null 2>&1 || die "whiptail is required and apt-get was not found."

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
  for command_name in systemctl systemd-analyze base64 ssh sed tr; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "Required command not found: $command_name"
  done
}

prepare_directories() {
  install -d -m 700 "$CONFIG_DIR" "$JOB_DIR"
}

input_box() {
  local prompt=$1
  local default_value=${2:-}
  whiptail \
    --title "$APP_NAME" \
    --inputbox "$prompt" 11 78 "$default_value" \
    3>&1 1>&2 2>&3
}

message_box() {
  whiptail --title "$APP_NAME" --msgbox "$1" 14 78
}

show_text() {
  local title=$1
  local content=$2
  local temporary_file
  temporary_file=$(mktemp)
  printf '%s\n' "$content" >"$temporary_file"
  whiptail --title "$title" --scrolltext --textbox "$temporary_file" 22 90
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

validate_time() {
  [[ $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

choose_time() {
  local value
  while true; do
    value=$(input_box "Enter the time in $TIMEZONE using 24-hour HH:MM format." "03:00") ||
      return 1
    if validate_time "$value"; then
      printf '%s' "$value"
      return
    fi
    message_box "That time is not valid.\n\nExample: 03:30 or 17:45"
  done
}

choose_schedule() {
  local schedule_type
  schedule_type=$(
    whiptail \
      --title "$APP_NAME" \
      --menu "How often should this task run?" 18 78 8 \
      "once" "One time" \
      "daily" "Every day" \
      "weekly" "Once each week" \
      "monthly" "Once each month" \
      "custom" "Custom systemd calendar expression" \
      3>&1 1>&2 2>&3
  ) || return 1

  local run_time date_value weekday month_day calendar
  case "$schedule_type" in
    once)
      date_value=$(input_box "Enter the date in YYYY-MM-DD format." "$(date +%F)") ||
        return 1
      run_time=$(choose_time) || return 1
      calendar="$date_value $run_time:00 $TIMEZONE"
      ;;
    daily)
      run_time=$(choose_time) || return 1
      calendar="*-*-* $run_time:00 $TIMEZONE"
      ;;
    weekly)
      weekday=$(
        whiptail \
          --title "$APP_NAME" \
          --menu "Choose the day of the week." 18 60 7 \
          "Mon" "Monday" \
          "Tue" "Tuesday" \
          "Wed" "Wednesday" \
          "Thu" "Thursday" \
          "Fri" "Friday" \
          "Sat" "Saturday" \
          "Sun" "Sunday" \
          3>&1 1>&2 2>&3
      ) || return 1
      run_time=$(choose_time) || return 1
      calendar="$weekday *-*-* $run_time:00 $TIMEZONE"
      ;;
    monthly)
      month_day=$(input_box "Enter the day of the month (1-28)." "1") ||
        return 1
      [[ $month_day =~ ^([1-9]|1[0-9]|2[0-8])$ ]] ||
        {
          message_box "Please use a day from 1 through 28."
          return 1
        }
      run_time=$(choose_time) || return 1
      calendar="*-*-$month_day $run_time:00 $TIMEZONE"
      ;;
    custom)
      calendar=$(
        input_box \
          "Enter a systemd OnCalendar expression.\n\nThe timezone must be included if you replace the example." \
          "*-*-* 03:00:00 $TIMEZONE"
      ) || return 1
      ;;
    *)
      return 1
      ;;
  esac

  if ! systemd-analyze calendar "$calendar" >/dev/null 2>&1; then
    message_box "The schedule could not be understood:\n\n$calendar"
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

  {
    printf 'DESCRIPTION=%q\n' "$description"
    printf 'TARGET=%q\n' "$target"
    printf 'CALENDAR=%q\n' "$calendar"
  } >"$path"
  chmod 600 "$path"
}

add_task() {
  local description target command_text calendar slug

  description=$(input_box "Enter a short description for this task.") || return
  [[ -n $description ]] ||
    {
      message_box "A description is required."
      return
    }

  slug=$(make_slug "$description")
  [[ -n $slug ]] ||
    {
      message_box "The description needs at least one letter or number."
      return
    }

  if [[ -e "$CONFIG_DIR/$slug.conf" || -e "$SYSTEMD_DIR/$UNIT_PREFIX-$slug.timer" ]]; then
    message_box "A task named '$slug' already exists.\n\nUse a different description."
    return
  fi

  target=$(
    input_box \
      "Where should the command run?\n\nUse local for the Proxmox host, or enter an SSH destination such as root@10.10.10.201." \
      "root@"
  ) || return

  if ! validate_target "$target"; then
    message_box "Use either:\n\nlocal\n\nor a destination such as:\nroot@10.10.10.201"
    return
  fi

  if ! test_ssh_target "$target"; then
    message_box "Passwordless SSH is not ready for:\n\n$target\n\nFrom the Proxmox shell, run:\n\nssh-copy-id $target\nssh $target true\n\nThen run this scheduler again."
    return
  fi

  command_text=$(
    input_box \
      "Enter the command exactly as it should run on $target.\n\nPasswords and other secrets should not be placed here."
  ) || return
  [[ -n $command_text ]] ||
    {
      message_box "A command is required."
      return
    }

  calendar=$(choose_schedule) || return

  local confirmation
  confirmation=$(
    printf 'Description: %s\nTarget: %s\nSchedule: %s\nCommand: %s' \
      "$description" "$target" "$calendar" "$command_text"
  )
  whiptail \
    --title "$APP_NAME" \
    --yesno "Create this task?\n\n$confirmation" 18 86 ||
    return

  local command_b64 runner_path service_path timer_path metadata_path
  command_b64=$(printf '%s' "$command_text" | base64 | tr -d '\n')
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
    printf '%s\n' '  printf "%s" "$COMMAND_B64" | base64 --decode | /bin/bash'
    printf '%s\n' 'else'
    printf '%s\n' '  printf "%s" "$COMMAND_B64" | base64 --decode | /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=30 "$TARGET" /bin/bash'
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

  write_metadata "$metadata_path" "$description" "$target" "$calendar"

  systemctl daemon-reload
  systemctl enable --now "$UNIT_PREFIX-$slug.timer"

  local next_run
  next_run=$(systemd-analyze calendar "$calendar" 2>/dev/null || true)
  message_box "Task created successfully.\n\nName: $slug\n\n$next_run"
}

task_choices() {
  local config_file slug
  shopt -s nullglob
  for config_file in "$CONFIG_DIR"/*.conf; do
    slug=${config_file##*/}
    slug=${slug%.conf}
    # Metadata files are root-owned and created by this script.
    # shellcheck disable=SC1090
    source "$config_file"
    printf '%s\n%s\n' "$slug" "${DESCRIPTION:-Scheduled task}"
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

  whiptail \
    --title "$APP_NAME" \
    --menu "Choose a task." 20 86 10 \
    "${choices[@]}" \
    3>&1 1>&2 2>&3
}

list_tasks() {
  local output
  output=$(systemctl list-timers --all "$UNIT_PREFIX-*.timer" --no-pager 2>&1 || true)
  show_text "Scheduled Tasks" "$output"
}

run_task_now() {
  local slug
  slug=$(select_task) || return
  systemctl start "$UNIT_PREFIX-$slug.service"
  local output
  output=$(journalctl -u "$UNIT_PREFIX-$slug.service" -n 40 --no-pager 2>&1 || true)
  show_text "Task Result: $slug" "$output"
}

view_logs() {
  local slug
  slug=$(select_task) || return
  local output
  output=$(journalctl -u "$UNIT_PREFIX-$slug.service" -n 100 --no-pager 2>&1 || true)
  show_text "Task Logs: $slug" "$output"
}

remove_task() {
  local slug
  slug=$(select_task) || return

  whiptail \
    --title "$APP_NAME" \
    --yesno "Delete the task '$slug'?\n\nIts service, timer, runner, and metadata will be removed." 13 76 ||
    return

  systemctl disable --now "$UNIT_PREFIX-$slug.timer" >/dev/null 2>&1 || true
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
    action=$(
      whiptail \
        --title "$APP_NAME" \
        --menu "Create and manage scheduled commands." 20 78 10 \
        "add" "Add a scheduled task" \
        "list" "List scheduled tasks" \
        "run" "Run a task now" \
        "logs" "View task logs" \
        "remove" "Remove a task" \
        "exit" "Exit" \
        3>&1 1>&2 2>&3
    ) || break

    case "$action" in
      add) add_task ;;
      list) list_tasks ;;
      run) run_task_now ;;
      logs) view_logs ;;
      remove) remove_task ;;
      exit) break ;;
    esac
  done
}

usage() {
  cat <<EOF
$APP_NAME

Usage:
  sudo bash proxmox-task-scheduler.sh

Run this script as root on a Proxmox host. It creates and manages systemd
services and timers for local commands or commands sent over passwordless SSH.
All wizard-created calendar schedules use $TIMEZONE.
EOF
}

main() {
  case "${1:-}" in
    -h | --help)
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
