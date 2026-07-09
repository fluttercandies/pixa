#!/usr/bin/env bash

set +e

output_root="build/reports/pixa_gallery_cockpit_android"
diagnostics_dir="$output_root/android-diagnostics"

adb -s emulator-5554 logcat -c || true
dart run tool/pixa_gallery_cockpit_acceptance.dart --platform=android --device-id=emulator-5554 --output-root="$output_root"
status=$?

if [ "$status" -ne 0 ]; then
  mkdir -p "$diagnostics_dir"
  printf '%s\n' "$status" > "$diagnostics_dir/acceptance-exit-code.txt"
  adb devices -l > "$diagnostics_dir/adb-devices.txt" 2>&1 || true
  adb -s emulator-5554 forward --list > "$diagnostics_dir/adb-forward-list.txt" 2>&1 || true
  timeout 20s adb -s emulator-5554 shell pidof dev.pixa.pixa_gallery > "$diagnostics_dir/app-pid.txt" 2>&1 || true
  timeout 20s adb -s emulator-5554 shell dumpsys activity processes > "$diagnostics_dir/activity-processes.txt" 2>&1 || true
  timeout 20s adb -s emulator-5554 shell dumpsys window > "$diagnostics_dir/window.txt" 2>&1 || true
  timeout 30s adb -s emulator-5554 logcat -d -v time -t 2000 > "$diagnostics_dir/logcat-tail.txt" 2>&1 || true
fi

exit "$status"
