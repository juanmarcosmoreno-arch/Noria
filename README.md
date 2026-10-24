# noria

**Make space. Run better.**

Noria is a native macOS cleaner and optimizer written in Swift and SwiftUI. It
finds space you can recover, explains why each item is listed, and never
removes anything without your review and confirmation. Everything runs locally.

> Status: **Phase 1 (MVP)** — see [PROJECT_STATUS.md](PROJECT_STATUS.md) for
> exactly what is implemented, what is pending and known limitations.

## What works today

| Module | What it does |
|---|---|
| **Dashboard** | Real storage, CPU and memory; *Analyze My Mac*; recommendations and live insights |
| **Smart Clean** | Caches, logs, temporary files, app leftovers, Mail, developer caches, old downloads, Trash size — each item with risk (SAFE / REVIEW / PROTECTED) and an explanation |
| **Space Map** | Treemap of any folder, zoom and breadcrumbs |
| **Large Files** | Files over 100 MB / 500 MB / 1 GB / custom, sortable |
| **Duplicates** | Byte-identical files (SHA-256); one copy always kept |
| **App Remover** | Apps and every file they created, exclusive vs shared |
| **Mail** | Where Mail's space goes; safe cleaning of downloadable attachment copies |
| **Startup Manager** | Background items, orphaned launchers of removed apps |
| **Performance** | CPU, memory pressure, swap, disk activity, top processes |
| **Developer Clean** | Xcode, simulators, package managers, inactive projects' dependencies |
| **Mac Health** | Battery capacity, cycles and condition; storage device |
| **History** | Quarantine (restore / delete) and activity with charts |
| **Noria Watch** | Optional menu bar extra and notifications |

Safety: nothing is removed without review and confirmation; every item is re-checked
right before acting; by default items go to Noria's **quarantine** and can be restored.

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
open Noria.xcodeproj        # select a scheme, then Run (⌘R)
```

| Scheme | Edition | Bundle ID |
|---|---|---|
| **Noria** (default) | Mac App Store / TestFlight, App Sandbox | `com.juanmarcos.noria` |
| **Noria Direct** | Direct distribution (Developer ID), not sandboxed | `com.juanmarcos.noria.direct` |

Uploading to TestFlight: see [docs/TESTFLIGHT.md](docs/TESTFLIGHT.md).

Team `62395T6WLG` (automatic signing). Identifiers, versions and both targets
live in `project.yml`; run `xcodegen generate` after changing them.

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
Design/                 brand artwork (icon source, brand board)
Tools/                  app-icon builder, string-catalog builder + Spanish translations
docs/                   architecture and distribution notes
```

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)

## Localization

Strings live in `App/Resources/Localizable.xcstrings` (English source, Spanish
translation). After changing UI text, add the Spanish entry to
`Tools/translations_es.py` and run `python3 Tools/build_strings.py` — it fails if
any user-facing string lacks a translation. CI checks the catalog is up to date.

## Brand: logo, icon and colors

Noria's identity is carpentry: a circular saw blade cutting a wood shaving.

- **App icon** — built from the brand artwork in `Design/noria-icon-source.webp`
  by `Tools/make_app_icon.py` (crops the tile, applies the macOS icon grid and a
  transparent background, writes every size). To update it, replace the source
  image and run the script.
- **In-app mark** — the saw is drawn in code (`App/DesignSystem/SawView.swift`) so
  the blade can spin during analysis while the shaving stays still; it winds
  down when the scan ends and is static with Reduce Motion.
- **Palette** (`App/DesignSystem/Theme.swift`) — wood `#D67B2D`, light orange
  `#F5A462`, beige `#F7F4EE`, graphite `#1F2328`, steel `#C0C4C9`/`#6B6F76`,
  dark background `#1A1A1A`. The brand board is in `Design/noria-brand-board.webp`.

## Privacy

Noria works entirely on the Mac. It sends no paths, file names, content or usage
data anywhere and contains no telemetry. It does not ask for administrator
privileges, does not require disabling SIP, and never tries to bypass TCC.
