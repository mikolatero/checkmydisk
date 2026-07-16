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
- Automatic `-d sat` retry for USB enclosures that need SAT pass-through
- Per-volume capacity/free-space display mapped to the physical disk (APFS-aware)
- History charts (Swift Charts): temperature, health, performance, and wear over time, backed by SQLite snapshots with configurable retention
- Short and full self-test launch and cancel, with correct ETA per test type
- Text and JSON report export with optional serial-number/WWN anonymization
- Robust process handling: concurrent pipe draining, per-command timeout, child-process cleanup on cancellation, parallel per-drive reads with per-device error reporting
- USB/SAT compatibility detection for `SATSMARTDriver.kext` and `SATSMARTLib.plugin`
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

macOS does not expose SMART data for many USB/SAT enclosures by default. CheckMyDisk reads any external drive that `smartctl` can see, detects common SATSMARTDriver installation paths, and shows guidance when external SMART support is unavailable. It does not install kernel extensions.

## Licensing Note

The bundled `smartctl` binary is from smartmontools and is GPL software. Release packages must include the matching smartmontools license/source-offer materials.
