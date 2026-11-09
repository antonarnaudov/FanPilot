# FanPilot — agent guide

## What this is
Open-source (MIT) fan control for Apple Silicon Macs: a SwiftUI menu bar app (`Sources/FanPilotApp`), a root LaunchDaemon that runs the control loop (`Sources/fanpilotd`), a CLI (`Sources/fanpilotctl`), and the shared core (`Sources/FanPilotCore`, `Sources/SMCKit`, `Sources/CSMC`). Developed and tested on Apple M4 Pro with macOS 27. Maintainer-specific notes, if any, live in `CLAUDE.local.md` (git-ignored): read it when it exists.

## Commands
All checked against the Makefile:
- `make build`: `swift build` (debug)
- `make test`: `swift test` (swift-testing; control engine, SMC codec, config)
- `make app`: `scripts/build-app.sh` → `build/FanPilot.app` (release, ad-hoc signed). `CONFIG=debug`, `UNIVERSAL=1`, `SIGN_IDENTITY=…` (names in `.env.example`)
- `make run`: build and open the app from `build/`
- `make install`: copy to `/Applications` and open. The app registers its built-in helper (SMAppService); macOS asks once to allow it in Login Items
- `make uninstall`: remove the app (turn the helper off in the app first)
- `make dev-helper` / `make dev-helper-remove`: the helper as a user LaunchAgent in **dry run**; point the app at it with `defaults write com.antonarnaudov.fanpilot devHelper -bool true`
- `make screenshots`: render every screen offscreen to `build/snapshots` (`FANPILOT_SNAPSHOT=<dir>`). Layout only: Liquid Glass doesn't render offscreen.
- Design review in a live window: `open --env FANPILOT_PAGE=overview|sensors|helper|menu|profile:<name> --env FANPILOT_APPEARANCE=light|dark --env FANPILOT_SCROLL=bottom build/FanPilot.app`. README screenshots are captures of the live window (`docs/screenshots/*.jpg`).
- `make icon`: regenerate `Resources/AppIcon.icns`
- `make release`: `scripts/release.sh` → `build/release/FanPilot-<version>.dmg`, `.zip`, `SHA256SUMS.txt` (notarized when `NOTARY_PROFILE` and a Developer ID exist). Publishing: tag `v<version>` and `gh release create v<version> build/release/* --notes-file …`, only with the maintainer's yes. Update CHANGELOG.md and VERSION first.

## How changes land
- Base branch `main`. One task = one branch (`feat/…`, `fix/…`) = one worktree. PRs into `main` once the repo is on GitHub.
- The app's version is the `VERSION` file. `FanPilot.version` in `Sources/FanPilotCore/Constants.swift` is the helper's: bump it only when the helper or the XPC protocol changes (that changes the helper binary, which users may have to approve again).

## Parallel work
Several agents may work on this repo at once.
- **One task = one branch = one worktree.** Never edit in a checkout another agent may be using:
  `git worktree add ../FanPilot-<topic> -b <type>/<topic> main`.
- **Check before you start:** `git worktree list`, `git branch -a --sort=-committerdate | head`, If another branch already changes the files your task needs, don't start; pick another task or ask the maintainer.
- **Never two writers on the same files.** Never stash, reset, switch branches or delete worktrees you didn't create.
- **Other machine?** Worktrees aren't shared across machines: `git fetch` first and treat recent remote branches as claimed.
- **Hand back:** rebase on `main`, pass the verification gate, merge per "How changes land" (or leave the branch with a clear last commit message), remove your worktree.

## Verification gate
1. `swift build` with no warnings, and `make test` green.
2. `make app` succeeds.
3. UI changes: `make screenshots` and look at the PNGs.
4. Helper or control changes: `make dev-helper`, then `fanpilotctl helper --dev` and `fanpilotctl profile <name> --dev` show the expected decisions. Remove it afterwards with `make dev-helper-remove`, `defaults delete com.antonarnaudov.fanpilot` and `rm -rf ~/Library/Application\ Support/FanPilot`.
5. Anything that writes to the SMC (`FanController`, `SMC.write`): only a person at the Mac can verify, with `sudo fanpilotctl test`. Say so in the hand-back; never claim it works on hardware without that run.

## Deploys and outward actions
Nothing deploys automatically. Pushing to GitHub (the repo is public), creating releases, tags that publish builds, and posting about the project happen **only with the maintainer's explicit yes, per action**. Agents prepare everything and ask.

## Secrets
None in the repo. A Developer ID signing identity stays in the maintainer's keychain and is passed by name as `SIGN_IDENTITY`. Never commit certificates or notarization credentials.

## Gotchas
- **`Ftst` is held while FanPilot owns any fan** (macOS reclaims manual fans otherwise) **and cleared as soon as it owns none. Never leave it at 1.** It keeps macOS's thermal manager from running the fans. Every path that takes fans must give them back (`FanController.release` / `releaseAll`). Recovery: `sudo fanpilotctl auto` or a reboot.
- Writing to the SMC needs root. Agents can't run sudo here: use dry run (`--dry-run`, forced automatically when not root).
- Many SMC `T…` keys are placeholders stuck at a round number (dozens of `Tp0*` read exactly 40.00 at idle, and turn live under load). `SensorReader` hides them until they move. Don't "fix" this by listing them.
- Fan mode 0 (auto) and 3 (system) both mean macOS is in charge; only 1 is manual.
- SwiftPM product names are case-insensitive on APFS: that's why the app target is `FanPilotApp` and the CLI `fanpilotctl`.
- In swift-testing, compare a `Double?` with a `Double` literal (`2150.0`), not an integer expression.
- The helper is an SMAppService daemon embedded in the bundle (`Contents/Library/LaunchDaemons/*.plist`, `BundleProgram` `Contents/MacOS/fanpilotd`); no installer script. Never-registered daemons report `.notFound`; `register()` throws "Operation not permitted" while approval is pending (not an error). macOS pins the approved helper by cdhash (LWCR) and re-pins only when CFBundleVersion changes, so `build-app.sh` stamps a unique build number (epoch seconds) on every build; a rebuild with the same number makes launchd refuse the helper (`launchctl print system/com.antonarnaudov.fanpilot.helper` shows `last exit code = 78: EX_CONFIG`). The app also re-registers an ad-hoc build when it changes (`HelperService.prepare`, waiting until the old registration is gone). **Ad-hoc builds may need the user's Login Items approval again after an update** (macOS can't tie them to an identity); with an Apple Development/Developer ID identity in the keychain, `build-app.sh` signs with it automatically, the app skips re-registering, and approval survives updates. Don't reinstall casually on a Mac whose helper is approved: an ad-hoc install with a changed helper can cost a re-approval.
- The app talks to the helper over XPC with `.privileged` (the daemon). The dev agent needs the non-privileged connection (`devHelper` default).
- Design is Apple's Liquid Glass (macOS 26+, the minimum): `GlassPage` (scrolling page over a neutral backdrop, extended under the glass sidebar with `backgroundExtensionEffect`; keep it neutral), `GlassCard`, glass button styles, `GlassEffectContainer` for groups, big SF Rounded numbers. Glass is for surfaces and controls; don't stack glass on glass except the menu window's modules (Control Center does the same). The Settings window stays a grouped `Form`, which is what Apple's own settings use.
- Toolbars render labels icon-only; `.labelStyle(.titleAndIcon)` where a title must show (the profile pop-up).
- Keep the app near-idle: no continuous or per-update animations (a spinning icon redraws the glass window every frame: ~50% CPU). With no window on screen the app updates every 5 s and reads only what the menu bar label needs.
- Never call the SMC on the main thread: a full sensor read is ~60 ms. `AppModel.refreshLocal` reads on `readQueue`; the Sensors page sets `needsAllSensors`, otherwise only summary groups and profile sensor keys are read.
- Re-registration is keyed on the bundled helper's cdhash, so app-only builds don't disturb the approved helper. Check with `codesign -dvvv … | grep CDHash` before installing if you want to avoid a re-approval.
- Inactive windows dim glass tints (macOS 27). Judge colours with the window in front.
- The app is `LSUIElement`. `DockPresence` switches it to a regular app (Dock icon, menu bar) while a window is open and back when the last one closes.
- Built-in profiles keep stable UUIDs (`Presets`); `Profile.color` is display-only and the helper ignores it.

## Docs map
- `README.md`: what it is, install, usage, how it works, credits
- `CHANGELOG.md`: what changed per release; `CONTRIBUTING.md`, `SECURITY.md`
- `Resources/com.antonarnaudov.fanpilot.helper.plist`: the helper launchd definition embedded in the app; `Sources/FanPilotApp/HelperService.swift`: registration
