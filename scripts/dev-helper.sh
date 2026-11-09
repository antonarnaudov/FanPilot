#!/bin/sh
# Development only: run the helper as your user, in dry-run mode (it never
# writes to the SMC), as a LaunchAgent. The real helper ships inside
# FanPilot.app and the app registers it with SMAppService.
#
#   install-dev <fanpilotd>   start the dry-run agent
#   uninstall-dev             stop and remove it
#
# Point the app at it: defaults write com.antonarnaudov.fanpilot devHelper -bool true
set -eu

LABEL="com.antonarnaudov.fanpilot.helper"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

case "${1:-}" in
install-dev)
    src="${2:?path to fanpilotd}"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/FanPilot"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$src</string><string>--dry-run</string></array>
    <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/FanPilot/helper-dev.log</string>
</dict>
</plist>
PLIST
    i=0
    until launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -ge 5 ] && launchctl bootstrap "gui/$(id -u)" "$AGENT"; sleep 1
    done
    echo "dev helper running (dry run)"
    ;;
uninstall-dev)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    echo "dev helper removed"
    ;;
*)
    echo "usage: $0 install-dev <fanpilotd> | uninstall-dev" >&2
    exit 2
    ;;
esac
