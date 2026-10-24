# Noria — Project status

_Last updated: 2026-10-24 · Current phase: **2** (version 0.2.0, build 2)_

## Verification

| Check | Where | Result |
|---|---|---|
| NoriaCore build + 65 tests (Swift 6.2.1, Linux) | dev container | ✅ passing |
| NoriaCore tests on macOS (Xcode toolchain) | GitHub Actions `macos-15` | ✅ 66/66 (incl. live CPU/memory test) |
| `Noria.app` direct (Debug) + App Store edition (Release, sandboxed), unsigned | GitHub Actions `macos-15` | ✅ both BUILD SUCCEEDED, no Swift warnings |
| String catalog complete (en + es) and in sync | `Tools/build_strings.py` + CI | ✅ |
| Xcode project in sync with `project.yml` (XcodeGen 2.46.0) | CI | ✅ |
| NoriaCore tests on Linux (Swift 6.1) | GitHub Actions | ✅ 65/65 |

**Not yet verified by a human on a real Mac:** interactive behaviour of the UI
(layout, animation smoothness, TCC prompts, Trash/Put Back round-trip). The
development container is Linux, so the SwiftUI target is compiled in CI
(macOS runner) but has never been launched. No cleanup was run on real user files. Please run it once and report anything off.

## Implemented (Phase 1)

- [x] Xcode project (XcodeGen spec + committed project), macOS 14 deployment target
- [x] Modular architecture: `NoriaCore` package (engine) + SwiftUI app target
- [x] Design system: color tokens (light/dark), spacing, radii, typography, components
- [x] Carpentry identity: wood/beige/steel palette; app icon from the brand artwork
      (`Tools/make_app_icon.py`); saw mark drawn in code — blade spins up during
      analysis and winds down after, Reduce Motion support, timeline paused when idle;
      determinate ring (category progress) / indeterminate arc
- [x] Main window: `NavigationSplitView`, 13 sidebar sections in the specified order;
      unbuilt modules show an honest "planned for phase N" screen
- [x] Dashboard (layout from the brand board): real volume capacity/used/available/
      purgeable, recoverable space only after a scan, live CPU % and memory used
      (Mach `host_statistics`, sampled every 2 s only while the Dashboard is visible),
      memory pressure and swap (`sysctl`), device info, Smart Scan with live counters,
      elapsed time, category checklist, recommendations
- [x] Smart Scan engine: User Cache, Logs, Temporary Files, Developer Cache,
      Downloads, Trash (informational) — read-only, cancellable, hard-link aware,
      no double counting across categories
- [x] Risk classification SAFE / REVIEW / PROTECTED with per-item explanations
- [x] Smart Clean: grouped list, risk filter, per-category select/deselect, inspector,
      exclusions from context menu, Reveal in Finder
- [x] Confirmation sheet (items, method, REVIEW warning, related running apps,
      explicit acknowledgement for permanent deletion)
- [x] Cleaning engine with re-validation before every item, stop between items,
      report distinguishing *moved to Trash* vs *deleted* vs *measured freed space*
- [x] Large Files: any folder, 100 MB / 500 MB / 1 GB / custom, sortable table,
      type filter, bundles measured as a unit, inspector, Finder actions, move to Trash
- [x] Operation log (JSON Lines) + History screen; clear history
- [x] Settings persisted in `UserDefaults`: language, removal method, age thresholds,
      categories, exclusions, Large Files container skipping
- [x] Localization: String Catalog, English + Spanish (379 strings)
- [x] Rule-based recommendations ranked by safety-weighted size
- [x] Tests: file system, walker, safety policy, every rule, engines, cleaning,
      cancellation, persistence, recommendations
- [x] Two editions from the same code: **Noria** (default scheme, App Sandbox,
      `com.juanmarcos.noria`) and **Noria Direct** (`com.juanmarcos.noria.direct`) with one-time home
      folder grant + security-scoped bookmark, Settings → Folder Access, export
      compliance key; TestFlight guide in `docs/TESTFLIGHT.md`
- [x] CI: both editions build on macOS; core tests on macOS and Linux

## Pending

### Phase 2 (in progress)
- [x] Noria-managed quarantine (default method): original path, date, size; restore
      without overwriting; delete; automatic deletion after N days (Settings);
      History › Quarantine; results separate quarantined / trashed / deleted space
- [x] App Remover: installed apps (icon, version, size, App Store badge); app bundle +
      related files in ~/Library by exact bundle identifier (reliable) or app name
      (REVIEW); shared group containers never preselected; keep the app to reset it;
      blocks while the app runs; /Applications grant in the App Store edition
- [x] App Leftovers (Smart Scan): data of uninstalled apps, REVIEW only, skipped when
      another app of the same developer is installed or Launch Services finds the app
- [x] Mail: space per account (messages vs attachments); Mail Downloads (SAFE) and
      attachment copies of server accounts (REVIEW) cleanable; POP / On My Mac /
      unknown accounts PROTECTED; messages never touched; Mail must be quit;
      Full Disk Access guidance and Mail's own options to reduce its size
- [ ] Space Map (treemap, zoom, breadcrumbs)
- [ ] Duplicates (size → partial hash → SHA-256)

### Phase 3
- [ ] Performance monitor (history graphs, disk activity, top processes; CPU/memory/
      pressure/swap readings already exist in NoriaCore `SystemMetrics`)
- [ ] Startup Manager (`SMAppService` status for own items, Login Items settings link)
- [ ] Mac Health (battery via IOKit `AppleSmartBattery`, storage info where exposed)
- [ ] Noria Watch menu bar extra + configurable notifications
- [ ] Privacy module (scope to be defined; only public mechanisms)

### Phase 4
- [ ] Developer Clean screen (simulators via `xcrun simctl`, official CLI cleanups)
- [ ] Richer intelligence rules; optional local model hook
- [ ] History charts (Swift Charts) and statistics; SQLite/SwiftData store
- [ ] Plural-aware strings and full localization review

### Phase 5
- [ ] Performance profiling on large homes (≥1M files), memory benchmarks
- [ ] Security review, signing, notarization, DMG, update mechanism
- [ ] App Store listing (screenshots, description, privacy labels) and review

## Known issues / limitations

- **Moving to Trash does not free space** until the Trash is emptied; the UI says
  so. Emptying the Trash is left to Finder (Phase 1).
- **Trash size needs Full Disk Access**; without it the category shows a lock.
- **Quarantine does not free space** until items are deleted from it (manually or after
  the retention period). It lives in Noria's Application Support folder (inside the
  container in the App Store edition), on the same volume as the user's files.
- **Mail account types** come from the macOS accounts database (read-only, needs Full
  Disk Access). If an account folder cannot be matched to a known server account type,
  its attachments stay PROTECTED. Matching of `~/Library/Mail/V*/<id>` folders to
  account identifiers has been tested only with synthetic data so far.
- **Removing apps from /Applications** may require macOS *App Management* permission
  (Privacy & Security) or an administrator password for apps installed by an installer
  package; Noria reports the failure and the item stays in place.
- Reading other apps' containers can trigger the macOS "access data from other apps"
  prompt during the App Leftovers scan and in App Remover.
- App Store edition: Temporary Files is unavailable (sandbox); scanning requires the
  one-time home folder grant. Not yet uploaded to App Store Connect.
- **Inode reuse:** if a scanned *folder* is deleted and a new folder is created at
  the same path reusing the same inode before cleanup, the identity check cannot
  tell them apart (files are additionally checked by size and date). The item
  must still pass every other policy check.
- **APFS clones/snapshots:** allocated size counts cloned blocks per file, so the
  real space freed can be lower; local Time Machine snapshots can keep space
  allocated. The measured free-space change is shown for permanent deletion.
- **Category progress** is per category (6 steps); within a category progress is
  indeterminate by design (total work is unknown).
- Count strings use a formatted number (`"1 items"` in English); plural variants
  are planned for Phase 4.
- Language change requires relaunching Noria (macOS reads `AppleLanguages` at launch).
- Associated-app names are resolved only for reverse-DNS cache folder names.
- Spanish copy uses neutral Spanish (tú). Can be switched to rioplatense if preferred.
- The in-app saw is a vector re-drawing of the brand artwork, not the raster
  artwork itself; small differences in shading are expected.

## Technical decisions

| Decision | Reason |
|---|---|
| macOS 14 deployment target | `@Observable`, `ContentUnavailableView`, `.inspector`, `onChange(initial:)`; Sonoma+ covers the vast majority of active Macs |
| Engine as a Foundation-only Swift package | testable headlessly (incl. Linux CI), clean UI/logic separation, shared by future App Store target |
| POSIX `lstat`/`opendir` instead of `FileManager.enumerator` | exact control: no symlink following, inode identity, allocated size, cheap per-entry cost, explicit error accounting |
| Swift 6 mode for NoriaCore, Swift 5 mode for the app | core verified under strict concurrency; app UI was written without a local macOS compiler, so it uses the more permissive mode until it is validated on a Mac — to be tightened in Phase 5 |
| Move to Trash by default | recoverable with Finder; quarantine comes in Phase 2 |
| JSON Lines operation log | append-only, crash tolerant, no dependencies; SQLite/SwiftData when charts arrive (Phase 4) |
| Trash informational only | permanent deletion of the user's Trash is better left to Finder in the MVP |
| Only catalogued caches are SAFE | unknown third-party caches are REVIEW; Apple caches are PROTECTED |
| XcodeGen + committed project | reproducible project file, reviewable diffs, opens without tools |
| Swift Testing | modern test API shipped with Xcode 16+ and the Linux toolchain |

## Next steps

1. Run Noria on a Mac, check the UI and a real Smart Scan (no cleanup needed) and report feedback.
2. Start Phase 2 with the quarantine (it changes the cleaning flow), then Space Map,
   Duplicates and App Remover.
