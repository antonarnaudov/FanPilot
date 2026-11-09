# Contributing to FanPilot

Thanks for helping. Reports from Macs other than the MacBook Pro M4 Pro it was built on are the most useful thing right now.

## Reporting a problem or a new Mac

Open an [issue](https://github.com/antonarnaudov/FanPilot/issues) with:

- Mac model (`sysctl -n hw.model`), chip and macOS version.
- What you expected and what happened.
- The output of these (no root needed, nothing is changed):
  ```bash
  /Applications/FanPilot.app/Contents/MacOS/fanpilotctl status
  /Applications/FanPilot.app/Contents/MacOS/fanpilotctl keys F
  /Applications/FanPilot.app/Contents/MacOS/fanpilotctl helper
  ```
- If the helper misbehaved, the end of its log: `tail -100 /Library/Logs/FanPilot-helper.log`.

## Building and testing

Needs macOS 26+ and Xcode 26+.

```bash
make build     # swift build
make test      # unit tests (control engine, SMC codec, config)
make app       # build/FanPilot.app
make install   # copy to /Applications and open
```

`make dev-helper` runs the helper as your user in dry-run mode (it never writes to the SMC); point the app at it with `defaults write com.antonarnaudov.fanpilot devHelper -bool true`.

## Pull requests

- One change per pull request, with a short description of what and why.
- `swift build` without warnings and `make test` green. CI runs both.
- Anything that writes to the SMC (`FanController`, `SMC.write`) must keep the rule: **the fans always go back to macOS** when FanPilot stops owning them, and `Ftst` is never left at 1. Say how you tested it on real hardware.
- UI follows Apple's current design (Liquid Glass); prefer system components.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
