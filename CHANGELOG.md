# Changelog

All notable changes to FanPilot. Versions follow [semantic versioning](https://semver.org); 0.x releases may still change settings formats (old settings are migrated).

## Unreleased

### Changed
- Releases are built and published by GitHub Actions from the version tag, with build provenance attestations (`gh attestation verify`) next to the SHA-256 checksums.

## 0.2.4 — 2026-11-09

### Fixed
- **FanPilot used about half a CPU core all the time.** The fan icons spun forever, so the window was redrawn on every frame, and every reading animated on each update. Now nothing animates on its own: FanPilot uses about 0.6% of one core with no window open and under 1% with its window open (measured on Apple M4 Pro).
- With no FanPilot window or menu on screen, the app updates only the menu bar label, every 5 seconds, and reads nothing at all when the label is icon-only.
- The app now has its own version, separate from the helper's, so app-only updates don't touch the approved helper.

## 0.2.3 — 2026-11-08

First public release.

### Fan control
- Profiles switched from the menu bar: **macOS** (Apple's default), **Silent Cool**, **Cool**, **Balanced**, **Quiet**, **Full speed**, and your own. Every profile can be edited, duplicated or reset to its default.
- **Silent Cool**: fans on from 45 °C but held at up to about 28% of the fans' range until 82 °C, slow ramps and long smoothing; idles at minimum speed instead of stopping and starting.
- Curves you drag or type exactly, with a take-over temperature, a give-back temperature and a give-back delay (60 s by default) so brief dips don't hand the fans back and forth.
- Response tuning: hysteresis, smoothing, spin-up and spin-down rates, hold before slowing.
- Any temperature to follow: hottest CPU core, CPU average, GPU, SSD, battery, or a single sensor.
- Per-fan overrides, a separate profile on battery, and a safety override: full speed when the hottest CPU/GPU sensor stays at the limit (95 °C for 5 s by default).

### Helper
- Fan control runs in a small root helper that ships **inside the app** and is registered with macOS (`SMAppService`); macOS asks once to allow it in Login Items. It runs your profile with the app closed and is removed with the app.
- Handles the M3/M4 thermal-manager lock (`Ftst`), holds it only while FanPilot owns a fan, and always hands the fans back to macOS: when the profile says so, before sleep, when the helper stops, and at start-up after a crash.

### App
- Liquid Glass design: glass sidebar and cards, large readouts, a Control Center-style menu bar window, a heat map of every sensor, light and dark mode.
- 10-minute temperature and fan history; activity log of everything the helper did.
- `fanpilotctl` command-line tool: status, sensors, raw SMC keys, a fan test and recovery (`sudo fanpilotctl auto`).

### Known limits
- Not notarized yet (no Apple Developer ID): the first open needs **Open Anyway** in Privacy & Security, and an update may ask you to allow the helper again in Login Items.
- Tested on Apple M4 Pro with macOS 27. Intel and M5 code paths are untested.
