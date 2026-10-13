# Releasing MacMaster

## Versions, changelog and updates

- Version lives in `Resources/Info.plist` (`CFBundleShortVersionString` = semver, `CFBundleVersion` = build number).
- `CHANGELOG.md` gets a `## [x.y.z] - YYYY-MM-DD` section per release (`### Added/Changed/Fixed`, `- ` bullets).
  It is copied into the app bundle and shown in the What's New window (app menu › What's New, and once after each update).
- The app checks `https://api.github.com/repos/swaraj792725/macmaster/releases/latest` once a day (Settings › General › Updates,
  or app menu › Check for Updates…). A release is "newer" when its tag (`v0.3.0`) beats the installed version. The Download
  button opens the release's `.dmg` asset, or the release page. Nothing is installed automatically.

One-step release:

```sh
scripts/release.sh 0.3.0            # bump Info.plist, commit, tag v0.3.0, build the DMG, print publish commands
scripts/release.sh 0.3.0 --publish  # also push and create the GitHub Release with the DMG and changelog notes
```

## Build a DMG (local test, not notarized)

```sh
scripts/make-dmg.sh
```

Builds the release app (`scripts/build-app.sh release`, no install) and writes `build/MacMaster-<version>.dmg`.
The version comes from `CFBundleShortVersionString` in `Resources/Info.plist`; bump it (and `CFBundleVersion`) first.
The DMG holds `MacMaster.app` and an `/Applications` shortcut, volume name "MacMaster".

Options:

- `--layout` (or `MM_DMG_LAYOUT=1`): arrange the icons with Finder via AppleScript. Needs a GUI session and Automation permission for Finder. Optional; falls back to the default layout if it fails.
- `--no-build`, or `MM_DMG_APP=/path/MacMaster.app`: package an existing app without building.
- `MM_DMG_FORMAT=ULFO`: smaller image (macOS 10.15+). Default is UDZO.
- `MM_SIGN_IDENTITY="..."`: signing identity used by `build-app.sh` (default: local "MacMaster Local Signing").

A DMG built this way is signed with a local certificate. Other Macs will show an "unidentified developer" warning.
Testers can right-click the app and choose Open once, or run `xattr -dr com.apple.quarantine /Applications/MacMaster.app`.

## Public distribution (signed and notarized)

Needs:

1. An Apple Developer Program membership (US$99 per year).
2. A "Developer ID Application" certificate (Xcode > Settings > Accounts > Manage Certificates, or developer.apple.com). Check it with `security find-identity -v -p codesigning`.
3. A notarytool keychain profile (one time):
   ```sh
   xcrun notarytool store-credentials "macmaster-notary" \
     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
   ```
   Create the app-specific password at appleid.apple.com.

Then:

```sh
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=macmaster-notary \
scripts/make-dmg.sh
```

The script re-signs the app with the hardened runtime and a secure timestamp, signs the DMG, submits it with
`notarytool --wait`, then staples the ticket. The result opens on any Mac without warnings, offline too.
If only `DEVELOPER_ID` is set, it signs but skips notarization.

## Hardened runtime and entitlements

MacMaster is not sandboxed (it needs Accessibility, event taps, IOKit and `/Library` access), so no sandbox entitlements apply.
The script signs with these entitlements (generated inline):

| Entitlement | Why |
|---|---|
| `com.apple.security.automation.apple-events` | `NSAppleScript` / `osascript` calls to System Events and Finder |
| `com.apple.security.device.bluetooth` | Bluetooth power toggle in the menu bar panel |
| `com.apple.security.personal-information.location` | Wi-Fi network name (macOS gates SSID behind location) |

Not needed: `com.apple.security.cs.disable-library-validation` (the app loads only Apple system libraries via `dlopen`, and bundles no third-party dylibs), JIT, or unsigned executable memory.
Add `com.apple.security.cs.disable-library-validation` only if you later bundle a third-party framework signed with a different team.

Privacy permissions (Accessibility, Screen Recording, Full Disk Access) are TCC grants, not entitlements. They are tied to the code signature,
so each user grants them once per signing identity. Changing identity (local certificate to Developer ID) means a one-time re-grant.

## Pre-release checklist

- Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
- Run `scripts/make-dmg.sh`, mount the DMG, drag the app to `/Applications`, launch it. The onboarding window appears on first run (`MM_ONBOARDING=1` forces it).
- On a clean user account or second Mac: confirm Gatekeeper accepts the notarized DMG (`spctl --assess --type open --context context:primary-signature -v build/MacMaster-<version>.dmg`).
- Upload the DMG (GitHub Releases or your site) and publish its SHA-256: `shasum -a 256 build/MacMaster-<version>.dmg`.
