#!/usr/bin/env bash
set -euo pipefail

device=emulator-5554
page_size="$(adb -s "$device" shell getconf PAGE_SIZE | tr -d '\r')"
if [[ "$page_size" != "16384" ]]; then
  echo "Expected Android 16 KB page size, got $page_size." >&2
  exit 1
fi

dart run tool/pixa_platform_build.dart \
  --platform=android \
  --enable-native-roi \
  --run-self-check \
  --device="$device" \
  --device-kind=emulator \
  --connection=local \
  --signing=debug \
  --report-output=build/reports/pixa_platform_probe_self_check_android.json

apk=.dart_tool/pixa_platform_probe/android/build/app/outputs/flutter-apk/app-debug.apk
"$ANDROID_HOME/build-tools/36.0.0/zipalign" -c -P 16 -v 4 "$apk"

runtime="$RUNNER_TEMP/libpixa_runtime.so"
unzip -p "$apk" lib/x86_64/libpixa_runtime.so >"$runtime"
readelf="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
mapfile -t load_alignments < <(
  "$readelf" -lW "$runtime" | awk '$1 == "LOAD" { print $NF }'
)
if (( ${#load_alignments[@]} == 0 )); then
  echo "libpixa_runtime.so has no ELF LOAD segments." >&2
  exit 1
fi
for alignment in "${load_alignments[@]}"; do
  if (( alignment < 0x4000 )); then
    echo "libpixa_runtime.so LOAD alignment $alignment is below 0x4000." >&2
    exit 1
  fi
done

.dart_tool/pixa_platform_probe/android/android/gradlew --stop
bash tool/pixa_android_cockpit_ci.sh
