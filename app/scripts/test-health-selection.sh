#!/bin/bash
set -euo pipefail
app_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/freereps-selection-tests.XXXXXX")"
xcrun swiftc "$app_dir/Sources/FreeReps/Models/FreeRepsConfig.swift" \
    "$app_dir/Tests/HealthSyncSelectionTests.swift" -o "$test_dir/health-selection-tests"
"$test_dir/health-selection-tests"
