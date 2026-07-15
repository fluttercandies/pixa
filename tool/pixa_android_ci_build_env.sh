#!/usr/bin/env bash

run_memory_bounded_android_build() {
  local gradle_opts="${GRADLE_OPTS:-}"
  env \
    GRADLE_OPTS="${gradle_opts:+$gradle_opts }-Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2" \
    'ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy=in-process' \
    "$@"
}

run_memory_bounded_android_build_with_retry() {
  local max_attempts="${1:-}"
  if [[ ! "$max_attempts" =~ ^[1-9][0-9]*$ ]]; then
    echo "Android build retry count must be a positive integer." >&2
    return 64
  fi
  shift
  if (( $# == 0 )); then
    echo "Android build retry requires a command." >&2
    return 64
  fi

  local retry_delay_seconds="${PIXA_ANDROID_BUILD_RETRY_DELAY_SECONDS:-10}"
  if [[ ! "$retry_delay_seconds" =~ ^[0-9]+$ ]]; then
    echo "Android build retry delay must be a non-negative integer." >&2
    return 64
  fi

  local attempt
  local status
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if run_memory_bounded_android_build "$@"; then
      return 0
    else
      status=$?
    fi
    if (( attempt == max_attempts )); then
      return "$status"
    fi
    echo "Android build prerequisite failed on attempt $attempt/$max_attempts; retrying." >&2
    sleep "$((retry_delay_seconds * attempt))"
  done
}
