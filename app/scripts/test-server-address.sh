#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_dir=$(dirname "$script_dir")
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/freereps-address-tests.XXXXXX")
xcrun swiftc "$app_dir/Sources/FreeReps/Models/FreeRepsConfig.swift" \
    "$app_dir/Tests/ServerAddressTests.swift" -o "$test_dir/server-address-tests"
"$test_dir/server-address-tests"
