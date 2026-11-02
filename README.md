# DiskUnbloat

A native macOS 26+ storage explorer built with Swift 6.3, SwiftUI, Observation, and a local SQLite index. No third-party runtime dependencies, accounts, analytics, or uploads.

Open **DiskUnbloat.xcodeproj**, select the **DiskUnbloat** scheme, choose your signing team, and Run. The app has three focused stages:

1. **Choose:** a compact window shows a single card to pick or drop one folder/disk, use a recent or mounted location, or choose Home, Downloads, user caches, **All caches** (one scan across every known cache location: user and application caches, Xcode build data, developer tool caches, editor caches, game-engine stores, messenger media, and browser model files), or **Dev tools** (one scan covering simulators, device support, Gradle distributions, automation-browser builds, Android SDK, container runtimes, package stores, local AI models, CI runners, and virtual machines). Expand **Scan options** before selecting a location to change hidden-file inclusion, package inspection, exclusions, and volume traversal. Scanning starts immediately after authorization.
2. **Scan:** the window stays compact while the animated mosaic tracks actual stages, file/folder counts, known bytes, elapsed time, current folder, and an approximate percentage of the volume's used data already read. Unreachable locations are listed right during the scan. Cancelled scans offer an explicit partial-map option with cleanup disabled.
3. **Explore:** the window grows to its remembered full size (960 × 640 at minimum) as the nested treemap fills it. Folder frames contain file tiles, colors identify file types, and the legend highlights a type without rearranging the map. Small/unloaded entries become clickable aggregate tiles, so browser pagination never truncates the map's byte accounting. Unknown sizes stay explicitly incomplete.

The file browser and details are closed by default. **Command-2** toggles the resizable browser drawer (250 items per page); **Command-I** opens details for the selection. Click a tile to select, Command-click for multiple selections, double-click a folder to focus it, and use **Command-Up** or breadcrumbs to go up. **Command-F** focuses search. Search defaults to the current subtree; the Filter menu can switch to Entire Scan. **Command-1** returns to map-only layout. Quick Look, Finder reveal, Copy Path, and adding to the deletion queue are available from map context menus. Queued items disappear from the map and wait in the queue; the toolbar tray shows a small red circle with the item count. Multiselection totals count overlapping parent/child paths once.

The Candidates drawer lists curated deletion candidates after any scan: user and application caches (including Xcode build data, old device-support and simulator versions with the newest kept, simulator-side throwaway trees, Cargo, bun, and Gradle package caches, the editors' and ComfyUI Desktop's Chromium caches, Adobe's shared media cache, Steam's shader/depot/download caches, Unreal's shared DDC store, Godot export templates and project caches, and game, browser, editor, and messenger caches), plus regenerable folders such as node_modules, Pods, DerivedData, .next, .vite, __pycache__, .godot, .build, or local build output. Any listed item can be excluded from the candidates for the rest of the scan and restored later.

Use **Explore a sample** to try the interface without granting access to personal files. Common/developer targets are scans, never automatic cleanup. Their grants still come from the system picker or a valid bookmark; grouped targets ask for the home folder so every listed location is covered, and unavailable members are skipped and reported during the scan. A bookmark-save failure does not prevent the current scan.

The deletion queue's two quick-select buttons can do the first pass for you: **Select safe items** checks junk and caches that are safe to delete (old build data; old simulator, device-support, Gradle-distribution, browser-build, and Godot-export-template versions; long-unused local AI stores — LM Studio, Hugging Face, PyTorch, MLX, Whisper — with auth tokens and chats never touched; Unreal's shared DDC store, ComfyUI Desktop's web caches, and act's action cache), and **Select rebuildable items** — behind a warning about an extensive cleanup — additionally checks live caches, simulator and device data, extracted Go modules, tier-2 package stores, project `.godot` and Unreal `Intermediate`/`DerivedDataCache` folders, CI runner caches, and folders tools can rebuild. Container runtimes (OrbStack, Colima, Lima, Podman) and Maven's repository stay scan-only and are never auto-selected. A scan-options threshold defines how long without modification counts as long-unused. The panel's rows offer the map's context menu (Quick Look, Reveal in Finder, Copy Path, Select/Deselect), and a small header button clears the whole selection at once. Review deletion-queue paths before choosing Trash or permanent deletion. After successful cleanup the app reruns the scan of the same scope on the spot and lands back on the updated map (the deletion report stays available); failed items remain untouched and are reported. System-managed locations and package internals are protected; only the exact curated cache locations listed above pass through that protection. A file's age or size never establishes that it is disposable.

## Architecture and source structure

The app uses **MVVM with a separate service/core layer**, organized by feature. Read [the architecture and contribution rules](Documentation/ARCHITECTURE.md) before implementing a feature.

- `DiskUnbloat/App`: application entry point, lifecycle, and entitlements.
- `DiskUnbloat/Features/<Feature>/{Views,ViewModels}`: SwiftUI screens and their focused observable presentation models.
- `DiskUnbloat/Services`: macOS integrations and app-container storage adapters.
- `DiskUnbloat/Shared`, `Resources`, and `PreviewContent`: shared presentation helpers, assets/privacy declarations, and previews/sample data.
- `Packages/DiskCore`: domain models, scanning, indexing, cleanup, suggestions, filesystem helpers, and pure visualization layout, grouped by subsystem.

`WorkspaceViewModel` coordinates the location-selection feature, `ScanViewModel`, `ExplorerViewModel`, `CleanupViewModel`, and `SettingsViewModel`. New feature logic belongs to its owning feature or core service rather than expanding the workspace. The Xcode navigator mirrors the folders on disk. Repository-wide guidance is in [AGENTS.md](AGENTS.md).

## Build and test

```sh
xcodebuild -project DiskUnbloat.xcodeproj -scheme DiskUnbloat \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build
swift test --package-path Packages/DiskCore
xcodebuild -project DiskUnbloat.xcodeproj -scheme DiskUnbloat \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData \
  CODE_SIGN_IDENTITY=- test -only-testing:DiskUnbloatTests
xcodebuild -project DiskUnbloat.xcodeproj -scheme DiskUnbloat \
  -destination 'platform=macOS,arch=arm64' ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- test
swift run -c release --package-path Packages/DiskCore DiskBenchmark 1000000
```

UI automation requires a logged-in desktop session with Xcode authorized for automation. Use the native architecture for local tests; generic Release builds produce both arm64 and x86_64 slices.

The project is checked in and opens directly without generators; it uses the Xcode 27 JSON project format (`project.xcproj`) and therefore requires Xcode 27 or later. `Tools/generate-project.py` can reproduce its structure using Python's standard library. Icon generation uses AppKit via `Tools/generate-icon.swift`; the master and all required macOS icon sizes are included. SwiftUI previews live in `DiskUnbloat/PreviewContent/Previews.swift`.

See [architecture](Documentation/ARCHITECTURE.md) and [validation results](Documentation/VALIDATION.md).

### Focused analysis

Rescan the current folder from Scan → Rescan Folder or a map folder's context menu. Refresh uses a staging index and restores the previous map on cancellation/failure. Successful refresh retains surviving selections/navigation and removes overlapping cleanup-review entries for another review.

Command-2 opens the resizable analysis drawer: Files, Largest, Types, and Candidates. Largest and Types support Current Folder/Entire Scan scope; statistics cover all indexed entries, including those represented by aggregate tiles. Candidate rules explain their criteria and consequences; age and size never establish safe deletion.

Pinch outward to focus a folder and inward to go up; horizontal trackpad swipes and extra mouse buttons navigate history. Drop one folder onto the Dock icon to scan it. English/Russian follows macOS application language preferences. Run `python3 Tools/audit-localization.py` when adding UI text.
