#!/usr/bin/env bash

set +e

pixa_proc_stat_field() {
  local stat_line="$1"
  local field_number="$2"
  local fields_text="${stat_line##*) }"
  if [ "$fields_text" = "$stat_line" ] || ((field_number < 3)); then
    return 1
  fi
  local fields=()
  read -r -a fields <<< "$fields_text"
  local field_index=$((field_number - 3))
  if ((field_index >= ${#fields[@]})); then
    return 1
  fi
  printf '%s\n' "${fields[$field_index]}"
}

pixa_proc_stat_self_test() {
  local fields=(Z)
  local field_number
  for ((field_number = 4; field_number <= 52; field_number += 1)); do
    fields+=("$field_number")
  done
  fields[49]=2304
  local stat_line="4242 (qemu process (test)) ${fields[*]}"
  [ "$(pixa_proc_stat_field "$stat_line" 3)" = "Z" ] || return 1
  [ "$(pixa_proc_stat_field "$stat_line" 22)" = "22" ] || return 1
  [ "$(pixa_proc_stat_field "$stat_line" 52)" = "2304" ] || return 1
}

if [ "${1:-}" = "--self-test" ]; then
  pixa_proc_stat_self_test
  exit $?
fi

: "${PIXA_ANDROID_COCKPIT_LAUNCH_ID:?Missing Android Cockpit launch id.}"
: "${PIXA_ANDROID_COCKPIT_PREBUILT_APK:?Missing Android Cockpit APK path.}"

output_root="build/reports/pixa_gallery_cockpit_android"
diagnostics_dir="$output_root/android-diagnostics"
qemu_pid=""
qemu_start_time=""
qemu_exit_captured=0

mkdir -p "$diagnostics_dir"

cleanup_live_diagnostics() {
  if [ -n "${logcat_pid:-}" ]; then
    kill "$logcat_pid" 2>/dev/null || true
    wait "$logcat_pid" 2>/dev/null || true
  fi
  if [ -n "${monitor_pid:-}" ]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
  if [ -n "${qemu_monitor_pid:-}" ]; then
    kill "$qemu_monitor_pid" 2>/dev/null || true
    wait "$qemu_monitor_pid" 2>/dev/null || true
  fi
}

capture_qemu_process_state() {
  [ -n "$qemu_pid" ] || return 0
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  local stat_file="/proc/$qemu_pid/stat"
  local status_file="/proc/$qemu_pid/status"
  local stat_line
  if ! stat_line="$(cat "$stat_file" 2>/dev/null)"; then
    printf '%s pid=%s state=missing\n' "$timestamp" "$qemu_pid" \
      >> "$diagnostics_dir/qemu-process-timeline.txt"
    return 0
  fi

  local state current_start_time exit_code_raw
  state="$(pixa_proc_stat_field "$stat_line" 3 2>/dev/null)"
  current_start_time="$(pixa_proc_stat_field "$stat_line" 22 2>/dev/null)"
  exit_code_raw="$(pixa_proc_stat_field "$stat_line" 52 2>/dev/null)"
  if [ -n "$qemu_start_time" ] && [ "$current_start_time" != "$qemu_start_time" ]; then
    printf '%s pid=%s state=pid_reused expected_start_time=%s actual_start_time=%s\n' \
      "$timestamp" "$qemu_pid" "$qemu_start_time" "${current_start_time:-unavailable}" \
      >> "$diagnostics_dir/qemu-process-timeline.txt"
    qemu_exit_captured=1
    return 0
  fi
  printf '%s pid=%s state=%s exit_code_raw=%s\n' \
    "$timestamp" "$qemu_pid" "${state:-unknown}" "${exit_code_raw:-unavailable}" \
    >> "$diagnostics_dir/qemu-process-timeline.txt"

  local exit_reason=""
  if [ "$state" = "Z" ]; then
    exit_reason="zombie"
  elif [[ "$exit_code_raw" =~ ^[0-9]+$ ]] && [ "$exit_code_raw" != "0" ]; then
    exit_reason="nonzero_exit_code"
  fi
  if [ -n "$exit_reason" ] && [ "$qemu_exit_captured" -eq 0 ]; then
    qemu_exit_captured=1
    {
      printf 'timestamp_utc=%s\n' "$timestamp"
      printf 'pid=%s\n' "$qemu_pid"
      printf 'state=%s\n' "$state"
      printf 'reason=%s\n' "$exit_reason"
      printf 'exit_code_raw=%s\n' "${exit_code_raw:-unavailable}"
      if [[ "$exit_code_raw" =~ ^[0-9]+$ ]]; then
        printf 'exit_status=%s\n' "$(((exit_code_raw >> 8) & 255))"
        printf 'exit_signal=%s\n' "$((exit_code_raw & 127))"
        printf 'core_dumped=%s\n' "$(((exit_code_raw & 128) != 0))"
      fi
      printf '\n--- %s ---\n' "$stat_file"
      printf '%s\n' "$stat_line"
      printf '\n--- %s ---\n' "$status_file"
      cat "$status_file" 2>&1 || true
    } > "$diagnostics_dir/qemu-exit-proc.txt"
  fi
}

capture_qemu_pid() {
  qemu_pid="$(pgrep -f 'qemu-system.*-avd test' | head -1)"
  if ! [[ "$qemu_pid" =~ ^[0-9]+$ ]]; then
    printf 'QEMU process not found at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$diagnostics_dir/qemu-pid.txt"
    qemu_pid=""
    return 0
  fi
  local initial_stat
  initial_stat="$(cat "/proc/$qemu_pid/stat" 2>/dev/null)"
  qemu_start_time="$(pixa_proc_stat_field "$initial_stat" 22 2>/dev/null)"
  {
    printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    printf 'pid=%s\n' "$qemu_pid"
    printf 'start_time_ticks=%s\n' "${qemu_start_time:-unavailable}"
    printf 'cmdline='
    tr '\0' ' ' < "/proc/$qemu_pid/cmdline" 2>/dev/null || true
    printf '\n'
  } > "$diagnostics_dir/qemu-pid.txt"
  capture_qemu_process_state
}

pixa_qemu_monitor() {
  while true; do
    capture_qemu_process_state
    if [ "$qemu_exit_captured" -eq 1 ]; then
      return 0
    fi
    sleep 1
  done
}

pixa_android_cockpit_monitor() {
  while true; do
    {
      printf '=== %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      adb devices -l
      adb -s emulator-5554 get-state
      adb -s emulator-5554 forward --list
      adb -s emulator-5554 shell pidof dev.pixa.pixa_gallery
      printf '\n'
    } >> "$diagnostics_dir/live-adb-heartbeat.txt" 2>&1

    {
      printf '=== %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      ps -eo pid,ppid,stat,etime,comm,args | grep -E '(flutter|dart|gradle|adb|emulator|qemu|java)' | grep -v grep | head -80
      printf '\n'
    } >> "$diagnostics_dir/live-process-snapshot.txt" 2>&1

    sleep 30
  done
}

capture_host_emulator_diagnostics() {
  {
    printf '=== %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    free -b
    cat /proc/meminfo
    for cgroup_file in \
      /sys/fs/cgroup/memory.events \
      /sys/fs/cgroup/memory.events.local \
      /sys/fs/cgroup/memory.current \
      /sys/fs/cgroup/memory.max; do
      if [ -r "$cgroup_file" ]; then
        printf '\n=== %s ===\n' "$cgroup_file"
        cat "$cgroup_file"
      fi
    done
    printf '\n=== processes ===\n'
    ps -eo pid,ppid,stat,rss,vsz,etime,comm,args \
      | grep -E '(flutter|dart|gradle|adb|emulator|qemu|java)' \
      | grep -v grep \
      | head -80
  } > "$diagnostics_dir/host-memory.txt" 2>&1

  : > "$diagnostics_dir/host-qemu-process.txt"
  while IFS= read -r qemu_pid; do
    [ -n "$qemu_pid" ] || continue
    {
      printf '=== qemu pid %s ===\n' "$qemu_pid"
      for proc_file in status stat limits cgroup smaps_rollup; do
        printf '\n--- /proc/%s/%s ---\n' "$qemu_pid" "$proc_file"
        cat "/proc/$qemu_pid/$proc_file" 2>&1 || true
      done
    } >> "$diagnostics_dir/host-qemu-process.txt" 2>&1
  done < <(
    {
      [ -n "$qemu_pid" ] && printf '%s\n' "$qemu_pid"
      pgrep -f 'qemu-system.*-avd test' || true
    } | sort -u
  )

  timeout 15s sudo -n dmesg --ctime \
    > "$diagnostics_dir/host-kernel.log" 2>&1 || true

  : > "$diagnostics_dir/host-emulator-crash.txt"
  for crash_dir in /tmp/android-runner/emu-crash-*; do
    [ -d "$crash_dir" ] || continue
    {
      printf '=== %s ===\n' "$crash_dir"
      find "$crash_dir" -maxdepth 4 -type f -printf '%p %s bytes\n'
    } >> "$diagnostics_dir/host-emulator-crash.txt" 2>&1
  done
}

trap cleanup_live_diagnostics EXIT

required_guest_ram_kib=1900000
adb -s emulator-5554 shell cat /proc/meminfo \
  > "$diagnostics_dir/guest-meminfo.txt" 2>&1
guest_ram_kib="$(
  awk '/^MemTotal:/ { print $2; exit }' \
    "$diagnostics_dir/guest-meminfo.txt"
)"
if ! [[ "$guest_ram_kib" =~ ^[0-9]+$ ]]; then
  echo "Unable to read Android guest memory from /proc/meminfo." >&2
  exit 1
fi
if ((guest_ram_kib < required_guest_ram_kib)); then
  echo "Android guest RAM is ${guest_ram_kib} KiB; expected at least ${required_guest_ram_kib} KiB." >&2
  exit 1
fi

adb -s emulator-5554 logcat -c || true
adb -s emulator-5554 logcat -v time > "$diagnostics_dir/live-logcat.txt" 2>&1 &
logcat_pid=$!
pixa_android_cockpit_monitor &
monitor_pid=$!
: > "$diagnostics_dir/qemu-process-timeline.txt"
rm -f "$diagnostics_dir/qemu-exit-proc.txt"
capture_qemu_pid
pixa_qemu_monitor &
qemu_monitor_pid=$!

dart run tool/pixa_gallery_cockpit_acceptance.dart \
  --platform=android \
  --device-id=emulator-5554 \
  --output-root="$output_root" \
  --prebuilt-android-apk="$PIXA_ANDROID_COCKPIT_PREBUILT_APK" \
  --prebuilt-android-launch-id="$PIXA_ANDROID_COCKPIT_LAUNCH_ID" \
  --skip-pub-get
status=$?
if [ -n "${qemu_monitor_pid:-}" ]; then
  kill "$qemu_monitor_pid" 2>/dev/null || true
  wait "$qemu_monitor_pid" 2>/dev/null || true
  qemu_monitor_pid=""
fi
capture_qemu_process_state

if [ "$status" -ne 0 ]; then
  printf '%s\n' "$status" > "$diagnostics_dir/acceptance-exit-code.txt"
  capture_host_emulator_diagnostics
  adb devices -l > "$diagnostics_dir/adb-devices.txt" 2>&1 || true
  adb -s emulator-5554 forward --list > "$diagnostics_dir/adb-forward-list.txt" 2>&1 || true
  timeout 20s adb -s emulator-5554 shell pidof dev.pixa.pixa_gallery > "$diagnostics_dir/app-pid.txt" 2>&1 || true
  timeout 20s adb -s emulator-5554 shell dumpsys activity processes > "$diagnostics_dir/activity-processes.txt" 2>&1 || true
  timeout 20s adb -s emulator-5554 shell dumpsys window > "$diagnostics_dir/window.txt" 2>&1 || true
  timeout 30s adb -s emulator-5554 logcat -d -v time -t 2000 > "$diagnostics_dir/logcat-tail.txt" 2>&1 || true
fi

exit "$status"
