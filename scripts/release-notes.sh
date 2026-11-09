#!/bin/sh
# Prints the GitHub release notes for a version: its CHANGELOG.md section plus
# install and verification steps. Used by .github/workflows/release.yml.
#
#   scripts/release-notes.sh [version] [--notarized]
#
# The version defaults to the VERSION file. Fails when CHANGELOG.md has no
# section "## <version> — <date>" for it.
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
NOTARIZED=0
if [ "${2:-}" = "--notarized" ]; then NOTARIZED=1; fi
REPO="antonarnaudov/FanPilot"

# The lines between "## <version> …" and the next "## " heading, without
# leading blank lines ($(…) drops the trailing ones).
CHANGES="$(awk -v v="$VERSION" '
    /^## / {
        if (found) exit
        if ($0 == "## " v || index($0, "## " v " ") == 1) { found = 1; next }
    }
    found { print }
' CHANGELOG.md | awk 'NF { started = 1 } started')"

if [ -z "$CHANGES" ]; then
    echo "CHANGELOG.md has no section for $VERSION (expected \"## $VERSION — YYYY-MM-DD\")" >&2
    exit 1
fi

cat <<EOF
**Fine-grained fan control for Apple Silicon Macs.** You decide when the fans come on, how hard they run and when macOS gets them back.

## What's new in $VERSION

$CHANGES

## Install

Requires an Apple Silicon Mac with **macOS 26 or later**.

1. Download **FanPilot-$VERSION.dmg** below, open it and drag **FanPilot** onto **Applications**.
EOF

if [ "$NOTARIZED" = 1 ]; then
    echo "2. Open FanPilot."
else
    cat <<'EOF'
2. Open FanPilot. It isn't notarized by Apple yet, so macOS says it can't check it: click **Done**, then **System Settings → Privacy & Security → Open Anyway**. Or in Terminal: `xattr -dr com.apple.quarantine /Applications/FanPilot.app`
EOF
fi

cat <<EOF
3. Allow the fan helper (built into the app): click **Open Login Items…** in FanPilot and turn FanPilot on under *Allow in the Background*.

Then pick a profile from the fan icon in the menu bar. Updating? Drag the new version over the old one; your profiles and settings are kept.

## Verify the download

These files were built from this tag by [GitHub Actions](https://github.com/$REPO/actions/workflows/release.yml). Check the checksum against \`SHA256SUMS.txt\`, and the build provenance with the [GitHub CLI](https://cli.github.com):

\`\`\`sh
shasum -a 256 FanPilot-$VERSION.dmg
gh attestation verify FanPilot-$VERSION.dmg --repo $REPO
\`\`\`
EOF

if [ "$NOTARIZED" = 0 ]; then
    cat <<EOF

## Known limits

- Not notarized yet (no Apple Developer ID): the first open needs **Open Anyway**, and an update that changes the helper may ask you to allow it again in Login Items.
- Untested Macs: reports from Macs other than Apple M4 Pro are welcome, see [CONTRIBUTING](https://github.com/$REPO/blob/main/CONTRIBUTING.md).
EOF
fi

cat <<EOF

Full history in the [changelog](https://github.com/$REPO/blob/main/CHANGELOG.md).
EOF
