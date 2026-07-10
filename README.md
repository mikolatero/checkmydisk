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

## USB / FireWire / SAT

macOS does not expose SMART data for many USB/SAT enclosures by default. CheckMyDisk reads any external drive that `smartctl` can see, detects common SATSMARTDriver installation paths, and shows guidance when external SMART support is unavailable. It does not install kernel extensions.

## Licensing Note

The bundled `smartctl` binary is from smartmontools and is GPL software. Release packages must include the matching smartmontools license/source-offer materials.
