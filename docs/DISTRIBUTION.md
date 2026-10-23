# Distribution: Developer ID (direct) vs Mac App Store

Noria is built so both editions share NoriaCore and almost all of the SwiftUI
code. Phase 1 ships only the **direct (Developer ID)** configuration.

## Direct distribution (signed + notarized DMG) — primary edition

* Not sandboxed, Hardened Runtime on, no entitlement exceptions
  (`App/Resources/Noria.entitlements`).
* Reads the real `~/Library/Caches`, `~/Library/Logs`, `~/Downloads`,
  DerivedData, etc.
* **Still subject to TCC and SIP.** Downloads/Desktop/Documents trigger the
  standard macOS consent prompts (usage strings are in `project.yml`). The Trash
  and some app data require *Full Disk Access*, which the user may grant in
  System Settings; Noria only links there and otherwise reports those locations
  as unreadable. Apps' containers trigger "access data from other apps" prompts,
  so Large Files skips `~/Library/Containers` by default.
* Steps for phase 5: Developer ID Application certificate → `xcodebuild archive`
  → `notarytool submit --wait` → `stapler staple` → DMG (e.g. `hdiutil` or
  `create-dmg`) → notarize the DMG too. Sparkle (or similar) for updates.

## Mac App Store

* App Sandbox is mandatory. `NSHomeDirectory()` becomes the app container, so
  `SystemLocations.current` would point inside it and a scan would find nothing
  meaningful.
* Required design (prepared, not implemented): the user grants folders through
  `NSOpenPanel` (`com.apple.security.files.user-selected.read-write`) and Noria
  stores security-scoped bookmarks (`com.apple.security.files.bookmarks.app-scope`)
  — see `Distribution/Noria-AppStore.entitlements`. `SystemLocations` would be
  built from the granted URLs.

### Feature matrix

| Feature | Direct | App Store |
|---|---|---|
| Storage metrics, Large Files in user-chosen folders | ✅ | ✅ (user-granted folders) |
| User caches / logs / DerivedData | ✅ | ⚠️ only if the user grants `~/Library/...` folders; App Review may reject cleaning other apps' data |
| Downloads cleanup | ✅ (TCC prompt) | ✅ with user grant |
| Trash size | ✅ with Full Disk Access | ⚠️ limited |
| Move to Trash | ✅ | ✅ for granted items |
| App Remover (phase 2) | ✅ (TCC "App Management" for /Applications) | ❌ largely not allowed |
| Startup Manager (phase 3) | ✅ read + link to Login Items settings; `SMAppService` only for own items | ⚠️ own items only |
| Performance / Mac Health (phase 3) | ✅ public APIs | ✅ mostly |
| Menu bar (phase 3) | ✅ | ✅ |
| Developer tools via official CLIs (phase 4) | ✅ | ❌ cannot run external tools |

Neither edition requests administrator privileges, disables SIP, or bypasses TCC.

## Sharing code

* Everything in NoriaCore is shared. The difference is concentrated in how
  `SystemLocations` is built (real home vs granted bookmarks) and in which
  sidebar modules are enabled — a build flag (`NORIA_APP_STORE`) and a second
  target in `project.yml` will express it in phase 5.
