#!/usr/bin/env bash

run_memory_bounded_android_build() {
  local gradle_opts="${GRADLE_OPTS:-}"
  env \
    GRADLE_OPTS="${gradle_opts:+$gradle_opts }-Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2" \
    'ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy=in-process' \
    "$@"
}
