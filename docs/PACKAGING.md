# Packaging the C++ / Qt app

| Platform | Artefact | Made by | Signed |
|---|---|---|---|
| macOS arm64 | `PlaneWorld-<ver>-macos-arm64.dmg` (drag to Applications; `pwcli` inside `Contents/MacOS`) | `packaging/macos/make_dmg.sh` | ad-hoc (`codesign -s -`) by default |
| Windows x64 | `PlaneWorld-<ver>-windows-x64.msi` (per-machine, Program Files, Start menu shortcut, major-upgrade aware) | `packaging/windows/make_msi.sh` + `PlaneWorld.wxs` (WiX v5) | unsigned |

The version comes from `project(PlaneWorld VERSION ...)` in `CMakeLists.txt`.

## CI

`.github/workflows/ci.yml`: every push to `main` builds both installers and smoke-tests them: the .dmg is mounted, the app copied out and
launched (screenshot `installed-macos-arm64.png`); the .msi is installed silently with `msiexec /qn`, the installed
`pwcli --info` and app launch are run (screenshot), then it is uninstalled and the removal checked. Pushing a tag
`v*` runs the same jobs plus `release`, which drafts a GitHub release with the installers attached. Publishing the
draft is a manual step.

## macOS: Developer ID signing + notarization (needs your Apple ID)

Ad-hoc signed apps open on the build Mac, but on other Macs Gatekeeper blocks a downloaded copy (right-click > Open, or
`xattr -dr com.apple.quarantine "/Applications/Plane World.app"`). To ship to others:

1. Join the Apple Developer Program; in Xcode or developer.apple.com create a **Developer ID Application** certificate
   and install it in your login keychain (`security find-identity -v -p codesigning` shows it).
2. Create an app-specific password at appleid.apple.com and store notary credentials once:
   `xcrun notarytool store-credentials planeworld --apple-id you@example.com --team-id TEAMID --password <app-specific>`
3. Build signed with the hardened runtime (entitlements: `packaging/macos/entitlements.plist`, JIT for JavaScriptCore):
   `PW_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" packaging/macos/make_dmg.sh build`
4. Notarize and staple:
   `xcrun notarytool submit build/dist/PlaneWorld-*.dmg --keychain-profile planeworld --wait`
   `xcrun stapler staple build/dist/PlaneWorld-*.dmg`
5. Check: `spctl -a -t open --context context:primary-signature -v build/dist/PlaneWorld-*.dmg`.

To do this in CI, export the certificate as .p12 into repository secrets, import it into a temporary keychain in the
macOS job, and pass the notarytool credentials as secrets (not set up: it needs your account).

## Windows: code signing

The MSI is unsigned, so SmartScreen warns on first run. Sign `Plane World.exe`, `pwcli.exe` and the .msi with
`signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 ...` using an OV/EV certificate or Azure Trusted
Signing. MSIX was not chosen: it needs a trusted signature even to install locally.

## Not done yet

Auto-update and crash reporting are not implemented.
