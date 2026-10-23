# Noria architecture

## Layers

```
┌────────────────────────────── App (SwiftUI, macOS 14, MainActor) ─────────────────────────────┐
│ Features (views)  ──>  Feature models (@Observable: AppModel, SmartScanModel, LargeFilesModel, │
│                         CleanupController)  ──>  DesignSystem (tokens, turbine, presentation) │
└───────────────────────────────────────────────┬───────────────────────────────────────────────┘
                                                │ async streams, value types (Sendable)
┌───────────────────────────────────── NoriaCore (Foundation only) ─────────────────────────────┐
│ Scanners: FileWalker, DirectorySizer, CleaningRule×6, SmartScanEngine, LargeFileScanner       │
│ Safety:   SafetyPolicy (classification + re-validation)                                       │
│ Cleaning: CleaningEngine + FileRemoving (TrashRemover / PermanentRemover / MoveToDirectory)   │
│ Storage:  NoriaSettings + SettingsStore, OperationLog (actor, JSONL), VolumeInfoProvider       │
│ Intelligence: RecommendationEngine (pure rules)    Monitoring: DeviceInfo                     │
│ Core:     FileSystem (lstat/opendir/realpath), SystemLocations, NoriaError                    │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
```

* **UI ↔ logic separation.** NoriaCore has no UI imports and returns structured
  data (`ItemReason`, `Recommendation.Kind`, …). All user-facing sentences are
  produced in `App/DesignSystem/Presentation.swift` and localized via the String
  Catalog.
* **Protocols where there is a real second implementation:** `CleaningRule`,
  `FileRemoving`, `SettingsStore`, `VolumeInfoProviding`. Tests inject a
  `MoveToDirectoryRemover` and a fixed volume provider. No speculative abstractions.

## Concurrency

* Scans run in `Task.detached(priority: .utility)` and report through
  `AsyncThrowingStream`. Breaking out of the `for await` loop (or cancelling the
  consuming task) cancels the scan through `onTermination`.
* The walker is synchronous and iterative (explicit stack, no recursion) and checks
  `Task.isCancelled` every 256 nodes.
* Progress events are throttled (every 500 files in the sizer, ~150 ms in Large
  Files) so the MainActor is never flooded.
* Cleanup runs one item at a time and can be stopped via `CleanupCancellation`
  between items; the final report is always delivered.
* `OperationLog` is an actor. Feature models are `@MainActor @Observable`.
* NoriaCore compiles in Swift 6 language mode (strict concurrency). The app target
  uses Swift 5 mode for now (see PROJECT_STATUS → technical decisions).

## File-system access

* `lstat` everywhere: symbolic links are **never followed**; a symlink counts as
  its own (tiny) size.
* Sizes are **allocated** bytes (`st_blocks × 512`): what is actually freed.
* Hard links are counted once per scan (`InodeTracker` stores only nodes with
  `st_nlink > 1`, so memory stays small).
* Walks stay on the root's device (no crossing into other volumes).
* Bundles (`.app`, `.photoslibrary`, …) are measured as a unit in Large Files.
* Unreadable directories are counted and reported, not fatal.
* Large Files keeps only results above the threshold in memory.

## Safety model

1. **Scan-time classification** — rules assign `RiskLevel` (`safe` only for the
   verified catalog, `review` for user files and unknown caches, `protected` for
   Apple caches and protected locations) and `ItemAction` (`informational` for Trash).
2. **Overlap removal** — no item is reported twice or nested in another one.
3. **Selection** — only `isSelectable` items can be selected; SAFE items are
   pre-selected, REVIEW items need an explicit choice.
4. **Confirmation** — sheet lists every item, the removal method, REVIEW count and
   running apps related to the items.
5. **Re-validation right before each removal** (`SafetyPolicy.validateForRemoval`):
   not protected/informational; canonical absolute path; not excluded; not in a
   system root or protected home location or managed library; strictly inside one
   of the category's allowed roots (never the root itself); parent path still
   resolves to itself (no symlink swapped in); same device/inode/type as scanned;
   for files, same size and modification date.
6. **Removal** — default `FileManager.trashItem` (Finder-compatible, Put Back
   works). Permanent deletion only when chosen in Settings and acknowledged in the
   confirmation sheet.
7. **Logging** — every scan and cleanup (removed paths, failures, method) is
   appended to `~/Library/Application Support/Noria/operations.jsonl`.

## Extension points for later phases

* **Quarantine (phase 2):** a `FileRemoving` implementation that moves into a
  Noria-managed directory and records origin/date in the log (the
  `MoveToDirectoryRemover` used by tests is the starting point).
* **Space Map / Duplicates:** reuse `FileWalker` + `InodeTracker`.
* **App Remover:** new `CleaningRule`s plus allowed roots in `SafetyPolicy`.
* **Local AI:** `RecommendationEngine` returns plain values; a model can add or
  re-rank recommendations behind the same type.
* **Persistence:** `OperationLog` sits behind a small API; moving to SQLite or
  SwiftData for charts (phase 4) does not affect callers.
