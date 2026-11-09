.PHONY: build app test run install uninstall dev-helper dev-helper-remove icon screenshots release clean

build:
	swift build

app:
	scripts/build-app.sh

test:
	swift test

# Builds the app and opens it from build/.
run: app
	open build/FanPilot.app

# Copies the app to /Applications and opens it. On first launch FanPilot registers
# its built-in helper; macOS asks once to allow it in Login Items.
install: app
	pkill -x FanPilot || true
	rm -rf /Applications/FanPilot.app
	cp -R build/FanPilot.app /Applications/FanPilot.app
	open /Applications/FanPilot.app

# Removes the app. Turn the helper off first (FanPilot > Helper > Turn Off) so macOS forgets it.
uninstall:
	rm -rf /Applications/FanPilot.app

# Development: run the helper as your user in dry-run mode (no SMC writes).
# Point the app at it with: defaults write com.antonarnaudov.fanpilot devHelper -bool true
dev-helper: build
	/bin/sh scripts/dev-helper.sh install-dev "$(CURDIR)/.build/debug/fanpilotd"

dev-helper-remove:
	/bin/sh scripts/dev-helper.sh uninstall-dev

icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build

# Renders every screen offscreen to build/snapshots for layout checks (no Liquid Glass offscreen).
screenshots: app
	FANPILOT_SNAPSHOT="$(CURDIR)/build/snapshots" build/FanPilot.app/Contents/MacOS/FanPilot

# Builds the downloadable DMG, zip and checksums into build/release (see scripts/release.sh).
release:
	scripts/release.sh
