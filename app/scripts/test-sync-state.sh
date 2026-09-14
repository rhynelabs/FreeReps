#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_dir=$(dirname "$script_dir")
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/freereps-state-tests.XXXXXX")
xcrun swiftc "$app_dir/Sources/FreeReps/Models/SyncState.swift" \
    "$app_dir/Tests/SyncStateTests.swift" -o "$test_dir/sync-state-tests"
"$test_dir/sync-state-tests"
