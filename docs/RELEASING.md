# Releasing FanPilot

Releases are built and published by GitHub Actions ([`release.yml`](../.github/workflows/release.yml)) when a version tag is pushed. Nobody uploads files by hand.

## Versions

- `VERSION` is the app's version (`0.3.0`, or `0.3.0-beta.1` for a pre-release). Tags are `v` + `VERSION`.
- `FanPilot.version` in `Sources/FanPilotCore/Constants.swift` is the helper's own version. Bump it only when the helper or the XPC protocol changes: a changed helper binary may make users approve it again in Login Items (until releases are signed with a Developer ID).
- `CHANGELOG.md` collects changes under `## Unreleased` as they land.

## Cutting a release

1. On `main`, rename `## Unreleased` in `CHANGELOG.md` to `## <version> — <YYYY-MM-DD>` and set `VERSION` to the same version. Commit: `FanPilot <version>`.
2. Dry run (optional, recommended for big changes): **Actions → Release → Run workflow** on `main`, or `gh workflow run release.yml --ref main`. It runs the tests and builds the DMG, zip, checksums and release notes as an artifact of the run, and publishes nothing. The notes are shown on the run's summary page.
3. Tag and push:
   ```sh
   git tag v<version>
   git push origin main v<version>
   ```
4. The workflow checks that the tag matches `VERSION` and that `CHANGELOG.md` has the section, runs the tests, builds the files, attests their build provenance and creates the GitHub release with notes generated from the changelog (`scripts/release-notes.sh`). A version with a `-` is published as a pre-release.

If a run fails before the release is created, fix the problem, move the tag (`git tag -f v<version> && git push -f origin v<version>`) or re-run the failed job. Once a release is public, don't move its tag: publish a new version.

## Signing and notarization

Without signing secrets, releases are ad-hoc signed and not notarized: users need **Open Anyway** on first launch. With a Developer ID, add these repository secrets (**Settings → Secrets and variables → Actions**) and the next release is signed, notarized and stapled automatically:

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE` | The *Developer ID Application* certificate and its private key, exported from Keychain Access as `.p12`, base64-encoded: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password chosen when exporting the `.p12` |
| `NOTARY_APPLE_ID` | Apple ID of the developer account |
| `NOTARY_TEAM_ID` | Team ID (developer.apple.com → Membership) |
| `NOTARY_PASSWORD` | An app-specific password for that Apple ID (account.apple.com → Sign-In and Security) |

Signing alone (certificate, no notary secrets) also works; the release is then signed but not notarized.

## Building locally

`make release` builds the same files into `build/release/` with whatever identity is in your keychain (ad-hoc otherwise); `NOTARY_PROFILE=<profile> make release` also notarizes. `scripts/release-notes.sh <version>` prints the notes.

## Checking a release

```sh
shasum -a 256 FanPilot-<version>.dmg       # compare with SHA256SUMS.txt
gh attestation verify FanPilot-<version>.dmg --repo antonarnaudov/FanPilot
```
