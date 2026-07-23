# CheckMyDisk

CheckMyDisk is a free native macOS drive health diagnostics app inspired by the functional shape of DriveDX.

It uses a dual `smartctl` backend:

- bundled `smartctl` first by default
- Homebrew/system `smartctl` fallback
- optional custom path in Settings

## Features

- Drive sidebar with Dashboard, Health Indicators, Errors Log, Device Statistics, Self-tests, and History views
- Drive health, performance, and SSD lifetime ratings shown as circular gauges
- DriveDX-like `OK`, `WARNING`, `FAILING`, and `FAILED` states using documented open heuristics
- Full `smartctl -x` data collection: NVMe and ATA/SATA SMART attributes, ATA Device Statistics, SATA Phy event counters, SCT firmware temperature history, NVMe error log and temperature sensors
- Extended device identity: rotation rate (HDD/SSD), form factor, WWN, interface speed, ATA/SATA/NVMe standard version, TRIM support, lifetime min/max temperature
- Interpretation of the `smartctl` exit-status bitmask (disk failing, pre-fail attributes below threshold, ...) and surfacing of `smartctl` messages in the UI
- Access-method ladder for USB enclosures (`-d sat` plus the `sntrealtek`/`sntjmicron`/`sntasmedia` NVMe-bridge pass-throughs), accepting only trustworthy SMART and flagging NVMe-over-USB drives that macOS cannot read instead of showing corrupt ATA values
- Per-volume capacity/free-space display mapped to the physical disk (APFS-aware)
- History charts (Swift Charts): temperature, health, performance, and wear over time, backed by SQLite snapshots with configurable retention
- Short and full self-test launch and cancel, with correct ETA per test type
- Text and JSON report export with optional serial-number/WWN anonymization
- Robust process handling: concurrent pipe draining, per-command timeout, child-process cleanup on cancellation, parallel per-drive reads with per-device error reporting
- USB/SAT compatibility detection for `SATSMARTDriver.kext` and `SATSMARTLib.plugin`
- Optional privileged helper (a `launchd` daemon registered via `SMAppService`) that runs `smartctl` as root for SATA/USB bridges that refuse SMART without elevated access; the app runs `smartctl` directly when it is not installed
- While-open periodic refresh and local notifications for worsening health states
- Localized UI (English and Spanish), follows the system light/dark appearance

## Build And Test

```sh
swift test
swift build
swift run CheckMyDisk
xcodebuild test -project CheckMyDisk.xcodeproj -scheme CheckMyDisk -destination 'platform=macOS' -testLanguage en -testRegion US
```

## Build As A macOS `.app` With Xcode

Open `CheckMyDisk.xcodeproj` in Xcode, select the `CheckMyDisk` scheme, then use:

- `Product > Run` to build and launch the app
- `Product > Build` to compile it
- `Product > Archive` to create a distributable archive

Command line equivalent:

```sh
xcodebuild -project CheckMyDisk.xcodeproj -scheme CheckMyDisk -destination platform=macOS build
```

The debug `.app` is produced under Xcode Derived Data. When using the repo-local build command above with `-derivedDataPath .build/XcodeDerivedData`, it appears at:

```text
.build/XcodeDerivedData/Build/Products/Debug/CheckMyDisk.app
```

## Automatic Updates

CheckMyDisk uses Sparkle 2 to check for updates once per day and also provides a manual **Check for Updates…** button in Settings. Sparkle always asks the user before installing an update; unattended download and installation are disabled.

Updates use two separate kinds of signing:

- Sparkle EdDSA authenticates each update ZIP and prevents a modified archive from being installed.
- The app bundle uses an ad-hoc macOS code signature (`codesign -s -`). It does not use an Apple Developer certificate and is not notarized by Apple.

Because the app is not notarized, Gatekeeper may warn on the first installation. Use **right-click (or Control-click) > Open** in Finder to confirm that you want to open it.

### Optional: Developer ID signing and notarization

Ad-hoc signing is the default and requires no setup. To instead ship a Developer
ID–signed, notarized build (no Gatekeeper warning), set these environment
variables before running the release; when they are unset the scripts behave
exactly as the ad-hoc flow above:

```sh
export DEVELOPER_ID_APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export DEVELOPMENT_TEAM="TEAMID"
export NOTARY_PROFILE="checkmydisk-notary"   # xcrun notarytool store-credentials profile
```

Requires a paid Apple Developer account, a Developer ID Application certificate in
the login keychain, and notary credentials stored with
`xcrun notarytool store-credentials`. With these set, `prepare_update.sh` builds
with the hardened runtime, re-signs the bundled `smartctl` with the runtime,
submits to `notarytool --wait`, staples the ticket, and `publish_release.sh`
verifies the Developer ID signature, stapling and Gatekeeper acceptance instead of
the ad-hoc checks. Sparkle EdDSA signing is independent and unchanged.

Note: the app target hard-codes `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"`; if a
Developer ID build still reports `Signature=adhoc`, that conditioned setting is
winning over the command-line override — move Release signing to an `.xcconfig`
or remove that line. `publish_release.sh` fails loudly in that case.

### Bundled smartctl architecture

The bundled `smartctl` is arm64-only, so on Intel Macs CheckMyDisk falls back to a
Homebrew/system `smartctl`. To ship a universal backend, build both slices and
combine them:

```sh
Scripts/make_universal_smartctl.sh /opt/homebrew/bin/smartctl /usr/local/bin/smartctl
```

### GPL compliance

The bundled `smartctl` is GPL-2.0-or-later software from smartmontools. The app
ships `ThirdPartyNotices.txt` with the license notice and a written source offer,
and `prepare_update.sh` refuses to package a build whose bundle is missing it.

The update feed and release assets are published at:

- Appcast: `https://mikolatero.github.io/checkmydisk/appcast.xml`
- ZIP assets: GitHub Release `v<MARKETING_VERSION>`
- ZIP format: `dist/CheckMyDisk-<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>.zip`

### One-time Sparkle key setup

Resolve the package and generate a key dedicated to this application:

```sh
xcodebuild -resolvePackageDependencies -project CheckMyDisk.xcodeproj -scheme CheckMyDisk -derivedDataPath build/DerivedData
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account com.checkmydisk.CheckMyDisk
```

The private EdDSA key remains in the macOS login keychain under the account `com.checkmydisk.CheckMyDisk`. Only the public key belongs in `Config/CheckMyDisk-Info.plist` as `SUPublicEDKey`. Never export or commit the private key.

### GitHub Pages

GitHub Pages must use **Deploy from a branch**, branch `main`, folder `/docs`. The repository includes `docs/.nojekyll`; `Scripts/prepare_update.sh` generates the signed `docs/appcast.xml`. No GitHub Actions workflow is required for this deployment mode.

### Publish a release

Install `gh` and `jq`, then authenticate GitHub CLI if needed:

```sh
gh auth login -h github.com
gh auth setup-git
```

Publish from `main` with a non-empty release description:

```sh
Scripts/publish_release.sh "Descripción del cambio"
```

The script increments the patch version and build number only in the application target, runs `xcodebuild test`, builds a universal ad-hoc-signed Release app, creates the ZIP and EdDSA-signed appcast, validates the bundle, commits the intended changes, creates and pushes the annotated tag, and creates or updates the GitHub Release asset. It refuses to publish if tests, packaging, signing, architecture, secret-safety, or appcast validation fails.

## USB / FireWire / SAT

macOS does not expose SMART data for many USB/SAT enclosures by default. CheckMyDisk reads any external drive that `smartctl` can see, detects common SATSMARTDriver installation paths, and shows guidance when external SMART support is unavailable. It does not install kernel extensions. For enclosures that expose SMART only with root privileges, an optional privileged helper can run `smartctl` as root — see [Privileged Helper](#privileged-helper-root-smart-access).

When a direct read does not return usable SMART, CheckMyDisk walks a ladder of access methods — `auto → -d sat → -d sntrealtek / -d sntjmicron / -d sntasmedia` — and accepts a result **only** when it carries trustworthy data. The bridge pass-throughs are attempted only after the direct reads fail, so healthy drives never pay for the extra probes.

### NVMe SSDs in USB enclosures

An NVMe SSD in a USB enclosure is a special case on macOS. The enclosure's bridge chip (Realtek, JMicron, ASMedia, …) is reached by `smartctl` as an ATA/SAT device, but sending ATA SMART commands to an NVMe drive returns a **corrupt structure** — invalid SMART checksum, every row named `Unknown_Attribute`, nonsensical raw values, and a misleading `PASSED`. Those numbers are not real health data and must be ignored.

The correct NVMe pass-through types (`-d sntrealtek`, `-d sntjmicron`, `-d sntasmedia`) require raw SCSI access that **macOS does not grant to `smartctl`** for USB mass storage: they fail with `Not a device of type 'scsi'`. That error is raised before privileges are checked, so neither `sudo` nor the privileged helper changes the outcome. On Linux the same `snt*` pass-throughs work, so the ladder surfaces real NVMe SMART there.

Because of this, CheckMyDisk does not present the corrupt ATA values as health. When no access method returns trustworthy SMART — the typical result for NVMe-over-USB on macOS — the drive is still identified (model, serial) but marked `UNKNOWN` with a clear note instead of a fabricated health score. **For full NVMe SMART on macOS, connect the drive through a Thunderbolt/USB4 NVMe enclosure (native NVMe, read with `-d nvme`) or an internal M.2 slot.**

## Privileged Helper (root SMART access)

Some SATA and USB bridges refuse SMART pass-through unless `smartctl` runs as
root. For those drives CheckMyDisk can install a small privileged helper
(`CheckMyDiskHelper`) — a `launchd` daemon embedded in the app bundle
(`Contents/MacOS/CheckMyDiskHelper` plus a launch daemon property list in
`Contents/Library/LaunchDaemons/`) and registered through `SMAppService`. The
helper exposes a single XPC method and **only ever runs the bundled `smartctl`**
— never an arbitrary command — with a per-call timeout.

The helper is **optional**. When it is not installed, CheckMyDisk runs
`smartctl` directly as the current user; this is the default behavior and reads
Apple internal NVMe and most enclosures fine. You only need the helper for
bridges that return permission errors without root.

### Install / remove

Settings → **Privileged Helper**:

- **Install Helper…** registers the daemon; macOS then lists it in
  **System Settings → General → Login Items & Extensions** ("Allow in the
  background"). Approve it there — until then the status reads *Needs approval in
  System Settings*.
- **Remove Helper** unregisters it.

### Requirements

Registering a privileged daemon through `SMAppService` is strict. All three must
hold, or `register()` fails and the app stays on the direct-`smartctl` fallback:

1. **A stable code-signing identity** — a Developer ID Application certificate
   (or an Apple Development certificate with a stable Team ID). An **ad-hoc**
   signature (`codesign -s -`, the default build) is rejected.
2. **A stable install location** — move the app to `/Applications`. A copy run
   from Derived Data, the Desktop, or a quarantined/translocated download is
   rejected.
3. **User approval** in System Settings (above).

Because of requirement 1, the default **ad-hoc distribution embeds the helper
but leaves it dormant** — the same signing dependency as notarization. The
privileged path is compile-verified and embedded, but it does not register until
you produce a Developer ID–signed build.

### Activating it (Developer ID build)

Set the signing environment variables (see
[Developer ID signing and notarization](#optional-developer-id-signing-and-notarization)),
build, then install:

```sh
export DEVELOPER_ID_APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export DEVELOPMENT_TEAM="TEAMID"
export NOTARY_PROFILE="checkmydisk-notary"
Scripts/prepare_update.sh "helper test build"
# copy the built .app to /Applications, launch it,
# Settings > Privileged Helper > Install Helper…, then approve in System Settings
```

Requires a paid Apple Developer account. Without one the app is still fully
functional through the direct `smartctl` fallback; the helper only adds coverage
for SATA/USB bridges that need root.

## Licensing Note

The bundled `smartctl` binary is from smartmontools and is GPL software. Release packages must include the matching smartmontools license/source-offer materials.
