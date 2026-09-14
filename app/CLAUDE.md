# iOS App

- Open `app/FreeReps.xcodeproj` in Xcode
- Requires physical device (HealthKit unavailable in Simulator)
- Bundle ID: `com.meltforce.freereps`

## Building

- `scripts/build-tailscalekit.sh` builds `Vendor/TailscaleKit.xcframework`
  (gitignored) from a pinned libtailscale revision. Run it once before the
  first Xcode build, and again when the pinned revision changes. *Why:* the
  project links the framework but does not build Go code itself.
- The script pins `GOTOOLCHAIN=go1.25.5`. *Why:* newer Go releases fail on a
  dependency of the pinned revision (`undefined: json.SkipFunc`).
- A development build next to the store app:
  `xcodebuild ... DEVELOPMENT_TEAM=<team> FREEREPS_BUNDLE_ID=<id> "FREEREPS_DISPLAY_NAME=<name>"`.
