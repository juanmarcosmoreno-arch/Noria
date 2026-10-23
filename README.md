# noria

**Make space. Run better.**

Noria is a native macOS cleaner and optimizer written in Swift and SwiftUI. It
finds space you can recover, explains why each item is listed, and never
removes anything without your review and confirmation. Everything runs locally.

> Status: **Phase 1 (MVP)** — see [PROJECT_STATUS.md](PROJECT_STATUS.md) for
> exactly what is implemented, what is pending and known limitations.

## What works today (Phase 1)

- **Dashboard** — real storage metrics for the startup volume (capacity, used,
  available incl. purgeable), basic device info, and the *Analyze My Mac* Smart Scan
  with live counters (current category, files examined, size found, elapsed time)
  and category-level progress. No invented percentages.
- **Smart Clean** — analyzes User Cache, Logs, Temporary Files, Developer Cache
  (Xcode DerivedData/Archives/Device Support, npm, pip, Homebrew, Yarn, CocoaPods,
  Go), Downloads (old installers/archives) and Trash (size only). Each item shows
  name, path, size, date, category, associated app, risk (SAFE / REVIEW /
  PROTECTED) and an explanation. Selection, filters, inspector, confirmation sheet,
  cleanup with progress/stop, and a result summary that separates *moved to Trash*
  from *freed*.
- **Large Files** — scan any folder with 100 MB / 500 MB / 1 GB / custom
  thresholds, sortable table (size, date, type, location), type filter, Finder
  reveal/open, details inspector, move to Trash with confirmation.
- **History** — local operation log (scans, cleanups, removed paths, failures).
- **Settings** — language (System/English/Español), removal method, age
  thresholds, categories, exclusions, permissions guidance, clear history.
- **Safety** — every removal is re-validated right before acting (allowed roots,
  protected locations, exclusions, symlink swaps, file changed since scan).
  Default removal is *Move to Trash* (recoverable with Finder's Put Back).

## Requirements

| | |
|---|---|
| macOS (to run) | 14.0 Sonoma or later — Apple Silicon and Intel |
| Xcode (to build) | 16 or later (Swift 6 toolchain; app target compiles in Swift 5 language mode) |

The deployment target is macOS 14 because Noria uses the Observation framework
(`@Observable`), `ContentUnavailableView`, `.inspector` and modern `Table`
APIs, all introduced or stabilized in macOS 14.

## Build and run

```sh
open Noria.xcodeproj        # select the "Noria" scheme, then Run (⌘R)
```

Before distributing, set your own `PRODUCT_BUNDLE_IDENTIFIER` and
`DEVELOPMENT_TEAM` in `project.yml` and regenerate the project.

Command line:

```sh
swift test --package-path NoriaCore                         # engine tests (also run on Linux)
xcodebuild -project Noria.xcodeproj -scheme Noria build      # app
```

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`) and is
committed so it opens without extra tools.

## Repository layout

```
App/                    SwiftUI app target (macOS only)
  App/                  @main app, AppModel and feature models
  DesignSystem/         colors, typography, turbine, components, localized presentation
  Features/             Dashboard, SmartClean, LargeFiles, History, Settings, RootView
  Resources/            Assets (provisional icon), Localizable.xcstrings, entitlements
NoriaCore/              Swift package with all non-UI logic (Foundation only)
  Sources/NoriaCore/
    Core/               POSIX file-system access, errors, well-known locations
    Models/             scan items, categories, risk levels, events
    Scanners/           walker, rules, Smart Scan engine, Large Files scanner
    Safety/             SafetyPolicy (what may be removed, re-validated before acting)
    Cleaning/           CleaningEngine, removers (Trash / permanent)
    Storage/            settings, operation log (JSONL), volume info
    Monitoring/         device info
    Intelligence/       rule-based recommendations
  Tests/NoriaCoreTests/ Swift Testing suites (run on throwaway directories)
Tools/                  icon generator, string-catalog builder + Spanish translations
Distribution/           prepared App Store entitlements (not used yet)
docs/                   architecture and distribution notes
```

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)

## Localization

Strings live in `App/Resources/Localizable.xcstrings` (English source, Spanish
translation). After changing UI text, add the Spanish entry to
`Tools/translations_es.py` and run `python3 Tools/build_strings.py` — it fails if
any user-facing string lacks a translation. CI checks the catalog is up to date.

## Logo and icon

The turbine is drawn in code (`App/DesignSystem/TurbineView.swift`). The app icon
in `AppIcon.appiconset` is a **provisional** render produced by
`Tools/generate_icon.py` from the same geometry. To use the final artwork,
replace the PNGs keeping the same file names — no code changes are required.

## Privacy

Noria works entirely on the Mac. It sends no paths, file names, content or usage
data anywhere and contains no telemetry. It does not ask for administrator
privileges, does not require disabling SIP, and never tries to bypass TCC.
