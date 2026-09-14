#!/bin/sh
# Builds TailscaleKit.xcframework into app/Vendor. Requires Go and Xcode.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_dir=$(dirname "$script_dir")
# Pinned so every build embeds the same Tailscale client.
revision=59d4bb82744915815178e0f0776d60026a397ee7
# Newer Go releases break a dependency of this revision (go-json-experiment).
export GOTOOLCHAIN=go1.25.5

work=$(mktemp -d "${TMPDIR:-/tmp}/tailscalekit.XXXXXX")
git -C "$work" init -q libtailscale
git -C "$work/libtailscale" fetch -q --depth 1 https://github.com/tailscale/libtailscale.git "$revision"
git -C "$work/libtailscale" checkout -q FETCH_HEAD
make -C "$work/libtailscale/swift" ios-fat

rm -rf "$app_dir/Vendor/TailscaleKit.xcframework"
mkdir -p "$app_dir/Vendor"
cp -R "$work/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework" "$app_dir/Vendor/"
echo "TailscaleKit.xcframework written to $app_dir/Vendor"
