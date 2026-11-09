# Security

## What runs with privileges

FanPilot's helper (`Contents/MacOS/fanpilotd`, registered from `Contents/Library/LaunchDaemons/com.antonarnaudov.fanpilot.helper.plist`) runs as **root**, because macOS only lets root change fan speed. It:

- reads temperature and fan keys from the SMC and writes only fan keys (`F<n>Md`, `F<n>Tg`, `Ftst`; `FS! ` on Intel), with targets clamped to each fan's own range;
- listens on one XPC service, `com.antonarnaudov.fanpilot.helper`, and accepts connections only from root and the user logged in at the console;
- stores its settings in `/Library/Application Support/FanPilot/config.json` and logs to `/Library/Logs/FanPilot-helper.log`;
- makes no network connections.

The app itself runs as you and needs no special permissions to read sensors.

## Known limits

- Releases are not notarized yet (no Apple Developer ID). Builds are ad-hoc signed, so the helper can't check its callers by Team ID; it checks the caller's user id instead.
- Any process running as the logged-in user can change the fan profile through the helper. The worst it can do is change fan speeds; the safety override still forces full speed at the temperature limit.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's [private vulnerability reporting](https://github.com/antonarnaudov/FanPilot/security/advisories/new) for this repository, with steps to reproduce. You'll get an answer as soon as possible.
