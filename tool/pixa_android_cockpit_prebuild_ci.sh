#!/usr/bin/env bash
set -euo pipefail

source tool/pixa_android_ci_build_env.sh

: "${PIXA_ANDROID_COCKPIT_LAUNCH_ID:?Missing Android Cockpit launch id.}"
: "${PIXA_ANDROID_COCKPIT_PREBUILT_APK:?Missing Android Cockpit APK path.}"

repo_root="$(pwd)"
prebuilt_apk="$PIXA_ANDROID_COCKPIT_PREBUILT_APK"
if [[ "$prebuilt_apk" != /* ]]; then
  prebuilt_apk="$repo_root/$prebuilt_apk"
fi

flutter_version="$(flutter --version --machine | jq -er '.frameworkVersion | select(type == "string" and length > 0)')"

(
  cd examples/pixa_gallery
  run_memory_bounded_android_build flutter build apk \
    --debug \
    --target cockpit/main.dart \
    --target-platform=android-x64 \
    --dart-define=FLUTTER_COCKPIT_REMOTE_ENABLED=true \
    --dart-define=FLUTTER_COCKPIT_REMOTE_HOST=0.0.0.0 \
    --dart-define=FLUTTER_COCKPIT_REMOTE_PORT=47331 \
    --dart-define="FLUTTER_COCKPIT_REMOTE_LAUNCH_ID=$PIXA_ANDROID_COCKPIT_LAUNCH_ID" \
    --dart-define="FLUTTER_COCKPIT_FLUTTER_VERSION=$flutter_version"
)

dart compilation-server shutdown

if [[ ! -s "$prebuilt_apk" ]]; then
  echo "Android Cockpit prebuilt APK is missing or empty: $prebuilt_apk" >&2
  exit 1
fi
