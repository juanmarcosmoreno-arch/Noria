# Distribution: Developer ID (direct) vs Mac App Store

Noria is built so both editions share NoriaCore and all of the SwiftUI code.
Both targets exist in `project.yml`: **Noria** (default scheme; sandboxed,
`com.juanmarcos.noria`, compiled with `NORIA_APP_STORE`) and **Noria Direct**
(`com.juanmarcos.noria.direct`). TestFlight steps: [TESTFLIGHT.md](TESTFLIGHT.md).

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
* Release: `Tools/release_direct.sh` archives the **Noria Direct** scheme,
  exports it with Developer ID (`Tools/ExportOptions-DeveloperID.plist`),
  checks the signature and hardened runtime, notarizes and staples the app,
  builds `build/release/Noria-<version>.dmg` (app + Applications link), signs,
  notarizes and staples the DMG, runs Gatekeeper (`spctl`) and writes its SHA-256.

  One-time setup on the Mac that publishes:
  1. Xcode › Settings › Accounts › Manage Certificates › **+** ›
     *Developer ID Application* (team 62395T6WLG).
  2. Create an app-specific password at appleid.apple.com, then:
     `xcrun notarytool store-credentials noria-notary --apple-id <Apple ID> --team-id 62395T6WLG --password <app-specific password>`
  3. Run `Tools/release_direct.sh` from the repository root.
* Updates: not implemented yet. Noria sends nothing over the network today; an
  update check (e.g. Sparkle with an EdDSA-signed appcast) will be opt-in.

## Mac App Store

* App Sandbox is mandatory (`App/Resources/Noria-AppStore.entitlements`).
* `SystemLocations.current` uses the real home folder (`getpwuid`), not the
  container returned by `NSHomeDirectory()`.
* Implemented: the first scan opens the system open panel on the home folder;
  the user clicks *Allow Access* (`files.user-selected.read-write`) and Noria
  stores a security-scoped bookmark (`files.bookmarks.app-scope`) so the grant
  survives relaunches (`App/App/FolderAccess.swift`). Settings → Folder Access
  shows, re-grants or revokes it. Large Files can also scan any folder picked in
  the panel during the session.
* Temporary Files is disabled in this edition (the sandbox redirects the
  temporary folder to the container).

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

* Everything is shared. Edition differences live in `AppEdition` and
  `FolderAccess` (`App/App/FolderAccess.swift`), selected by the
  `NORIA_APP_STORE` compilation condition and the runtime sandbox check.
