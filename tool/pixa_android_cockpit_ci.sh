#!/usr/bin/env bash

set +e

output_root="build/reports/pixa_gallery_cockpit_android"
diagnostics_dir="$output_root/android-diagnostics"

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

trap cleanup_live_diagnostics EXIT

adb -s emulator-5554 logcat -c || true
adb -s emulator-5554 logcat -v time > "$diagnostics_dir/live-logcat.txt" 2>&1 &
logcat_pid=$!
pixa_android_cockpit_monitor &
monitor_pid=$!

dart run tool/pixa_gallery_cockpit_acceptance.dart --platform=android --device-id=emulator-5554 --output-root="$output_root"
status=$?

if [ "$status" -ne 0 ]; then
  printf '%s\n' "$status" > "$diagnostics_dir/acceptance-exit-code.txt"
  adb devices -l > "$diagnostics_dir/adb-devices.txt" 2>&1 || true
  adb -s emulator-5554 forward --list > "$diagnostics_dir/adb-forward-list.txt" 2>&1 || true
  timeout 20s adb -s emulator-5554 shell pidof dev.pixa.pixa_gallery > "$diagnostics_dir/app-pid.txt" 2>&1 || true
  timeout 20s adb -s emulator-5554 shell dumpsys activity processes > "$diagnostics_dir/activity-processes.txt" 2>&1 || true
  timeout 20s adb -s emulator-5554 shell dumpsys window > "$diagnostics_dir/window.txt" 2>&1 || true
  timeout 30s adb -s emulator-5554 logcat -d -v time -t 2000 > "$diagnostics_dir/logcat-tail.txt" 2>&1 || true
fi

exit "$status"
