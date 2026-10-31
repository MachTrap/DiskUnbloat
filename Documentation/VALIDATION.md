# Validation — November 1, 2026

Toolchain: Xcode 27.2 (27B52), Apple Swift 6.4.2, macOS 26 deployment target, Apple Silicon execution host.

## Xcode JSON project format migration — 2026-11-01

Converted `DiskUnbloat.xcodeproj/project.pbxproj` to the Xcode 27.2 JSON project format (`project.xcproj`) and rewrote `Tools/generate-project.py` to emit that format directly. The project model is unchanged: only the on-disk representation moved from the NeXTSTEP property list to a hierarchical, diff-friendly JSON document. Requires Xcode 27 or later (Xcode 26 cannot open it). The shared scheme, `Package.resolved`, and resource/entitlement paths are unchanged.

- `xcodebuild -project DiskUnbloat.xcodeproj -convert-project "Xcode Project"` and `python3 Tools/generate-project.py` produce byte-identical `project.xcproj`; the generator is idempotent across runs. Output is canonicalized with Apple's `xcprojformatter`.
- `swift test --package-path Packages/DiskCore`: 34 tests pass.
- Universal macOS Release build (`-destination 'generic/platform=macOS'`, `CODE_SIGNING_ALLOWED=NO`): succeeds.
- App/UI test-bundle compilation (`build-for-testing`): succeeds; both hosted unit tests and the UI test target build against the converted project.
- Owner signing/team/bundle overrides are preserved by the generator. No `DEVELOPMENT_TEAM` was set at migration time, so none carried over; the preservation path remains and reads overrides back from the existing `project.xcproj`.
- The automated UI suite was not re-run; the desktop-automation limitation recorded below still applies.

## Performance optimization pass — 2026-11-01

Hot-path optimizations to scanning, indexing, queries, layout, and cleanup normalization.

- **Insert path:** `ScanIndex.insert` now writes `category`, `rawLogical`, `rawAllocated`, `latestModified`, and `unknownModified` in the single INSERT statement, removing a per-node classification `UPDATE` loop and a per-batch `UPDATE … WHERE <nullable column> IS NULL` that forced a full table scan every batch (an O(n²) hotspot). Synthetic 1M-entry benchmark insert dropped **12.87 s → 9.68 s (~25%)**; aggregate and category queries were unchanged within noise.
- **Enumeration:** the scan no longer requests `totalFileAllocatedSize` or `fileSize`; sizes come from `lstat` (`st_size`, `st_blocks * 512`). "On disk" therefore reflects POSIX block allocation (what `du` reports) instead of `totalFileAllocatedSize`, which also accounted for inode/xattr/fork overhead. This removes the most expensive per-file metadata read; it is not exercised by the synthetic benchmark, so the speedup is only visible on real enumeration.
- **Batch size** raised 512 → 2048 (fewer transactions per scan).
- **Search folding** now uses a fixed `en_US_POSIX` locale (deterministic, cheaper) for both insert and query.
- **Category stats are lazy:** the full `categorySummaries` aggregation only runs in the Types tab; the always-visible legend uses a new lighter `ScanIndex.categoryList` (`SELECT DISTINCT category`).
- **Cleanup plan normalization** is now O(n log n) instead of O(n²).
- **Treemap layout** runs off the main actor and precomputes entry sizes.

All 36 core tests pass (including two new ones: plan dedup keeps topmost entries, and `categoryList` returns distinct file categories). Universal Release build and app/UI test compilation pass. The automated UI suite remains subject to the desktop-automation limitation below.

## Explorer performance, navigation caching, and DerivedData cleanup — 2026-11-01

- `ScanIndex.explorerSnapshot` computes the browser summary, page rows, legend categories, optional full category statistics, and optional map scene in **one actor call** (previously ~6), guaranteeing every shown result reflects one index revision. Browsing/map rows use a lighter column-projected reader that skips `searchName` and the raw accounting columns (identity/fingerprint are kept so cleanup validation still works).
- `ExplorerViewModel` caches summary/rows/legend/statistics (keyed by revision + query state) alongside the scene cache, so navigating back to a previously visited folder — e.g. the root of a large scan — reuses results instead of re-scanning. Candidate/suggestion results are never cached because they depend on the dynamic set of running applications. Full category statistics run only on the Types tab.
- **DerivedData:** removed the running-Xcode blocklist entry that hid and refused `~/Library/Developer/Xcode/DerivedData` cleanup. It is regenerable build output (a curated target), so old entries are now removable while Xcode runs (worst case Xcode rebuilds); other running-app caches remain protected. The rule explanation was updated in English and Russian.
- `drawerRankingDoesNotChangeMapAndStatisticsUseAllRows` now checks the "statistics use all rows" invariant on the Types tab (where statistics materialize); the map-unchanged and largest-ranking assertions are unchanged.
- All 36 core tests and 31 hosted tests pass. Universal Release build and test compilation pass. `Tools/audit-localization.py` validates 323 entries.

## Phase 1–2 refactoring: shared path helpers and ScanIndex decomposition — 2026-11-01

Behavior-preserving refactors; all validation re-run and green.

- **Shared path helpers (`FileSystem/PathScope.swift`):** introduced `String.isWithin(_:)` (descendant-or-self, `/` matches every absolute path), `.overlaps(_:)`, and `.pathRange` (BINARY `[self/, self0)` bounds). Replaced ~15 ad-hoc `path == other || path.hasPrefix(other + "/")` (and two-way overlap) call sites across `CleanupSafety`, `CleanupPlan`, `ScanCoordinator`, `CleanupViewModel`, `ExplorerViewModel`, `AuthorizationStore`, `WorkspaceViewModel`, `KnownLocation`, and `ScanViewModel`, plus the duplicated `/`-rooted SQL range constructions in `ScanIndex`.
- **Decomposed `ScanIndex.predicate`** (~110 lines) into an `SQLPredicate` clause accumulator with focused builders: `applyScope`, `applyFilters`, `applySuggestion`, `applyCleanupRule`, `applySystemExclusions`, `applyPathExclusion`. Clause order (and therefore positional `?` binding) is preserved exactly.
- **Split `ScanIndex` into focused files:** `ScanIndex` (connection/schema/readers), `+Write`, `+Query`, `+Refresh`. Shared plumbing (`db`, `exec`, `bind`, `read`, `readRows`, …) became module-internal and `revision` became `internal(set)` so the split files compile; the actor boundary and public API are unchanged.

Validation: 36 core tests, 31 hosted tests, universal Release build, and test compilation all pass after Phases 1–2.

## Phases 3–4 refactoring: single-source cache locations, workspace flows, ExplorerQueries — 2026-11-01

Behavior-preserving refactors; all validation re-run and green.

- **Single source of truth for known cache locations:** `LocationCatalog.cacheRoots` and `devToolRoots` now derive from `CleanupRule.userCaches` (plus `derivedData`/scan-only additions) instead of a parallel hardcoded list, so quick scans and the curated cleanup set cannot drift apart. `ApplicationActivityService`'s VS Code/Chrome blocklist paths also derive from `CleanupRule.userCaches`.
- **Deduplication:** `CleanupViewModel` uses the shared `CleanupRule.knownCacheRoots(home:)` (removed the local re-implementation) and a single static `activityMessage(_:activity:home:)` used by both `activityReason` and the `execute` preflight.
- **Workspace authorize flows:** added `beginScan(with:)` (replaces ~6 `scan.pendingRoot = url; startScan()` sites) and `runRestoring(_:)` (centralizes the `restoringLocation` flag + restore-task scaffolding across the three restore flows) in `WorkspaceViewModel`.
- **ExplorerQueries:** extracted `makeQuery`, `subtreeScope`, the stats/map derivation, and the `ResultsKey`/`CachedResults` cache types into `Features/Explorer/ViewModels/ExplorerQueries.swift`. The view model now builds a value-type snapshot via `makeQueries()` and delegates query construction, keeping orchestration separate from query building. The Xcode project was regenerated so the new file joins the target.

Validation: 36 core tests, 31 hosted tests, universal Release build, test compilation, and `Tools/audit-localization.py` (323 entries) all pass.

## Phase 5 refactoring: readability polish and test split — 2026-11-01

Final low-risk polish; all validation re-run and green.

- **`CleanupSafety.isManagedData`** rewritten from a nine-term one-liner into grouped early returns (exact roots → tree-directory suffixes → managed-tree contents with the scoped container-Caches exception), preserving the exact short-circuit semantics.
- **`ApplicationActivityService`** VS Code/Chrome blocklist is now a data table of `(owner bundle ID, path marker)` instead of an if-chain.
- **`ScanIndex.insert`** per-row column binding extracted into `bindRow(_:to:)`.
- **`ScanIndex.replaceBranch`** pre-commit validation extracted into `validateForRefresh(_:)` (returns the validated root, synchronous — no suspension), so the commit path reads as validation → attach → transaction. The transaction body itself was deliberately left intact (correctness-critical).
- **Test split:** `PresentationTests.swift` (697 lines) split into one file per suite plus `PresentationTestSupport.swift` for the shared test doubles (`RecordingCleanupService`, `ControlledScanner`, …) now visible across suite files. `generate-project.py` discovers test sources recursively (backward-compatible: a single test file yields identical output).

Validation: 36 core tests, 31 hosted tests across 10 suites, universal Release build, test compilation, `Tools/audit-localization.py` (323 entries), and generator idempotency all pass.

## Current map-first build

The app now routes through explicit location, scanning, preparing-results, and explorer screens, with dedicated cancelled/failed outcomes. The map fills the results workspace; browser and details start closed. Source ownership and product invariants are documented in ARCHITECTURE.md and AGENTS.md.

### Automated checks

- 18 core tests pass. New coverage includes byte/count conservation for 3,001 entries beyond the browser limit, bounded aggregate scenes, partial known-size propagation, nested containment/deepest hit testing, current-subtree filtering, explicit real-user cache roots, and category classification.
- 13 hosted app tests pass. New coverage includes map-only initial results, scan/cancel/retry/failure transitions, opting into cancelled results with cleanup disabled, completed partial scans, real-home quick-target paths, invalid drops, overlap-safe selection totals, unchanged geometry when highlighting, and selections retained across browser pages.
- Universal Release build and app/UI test-bundle compilation pass. The updated UI scenarios cover chooser/options, map-only defaults, drawer commands, scoped search, and cleanup confirmations. The existing Xcode UI automation timeout below still prevents recording the automated UI suite as passed.

### Native sandboxed checks

An isolated normally sandboxed app (`com.diskunbloat.mapreview`) was inspected through desktop controls. Launch had no explorer panels or explorer toolbar. A sample scan opened a full-window nested map, with both side panels and the browser absent. Command-2 toggled the drawer; folder focus/up navigation and type highlighting worked without changing geometry.

The same app selected `.artifacts/MapStressFixture` through NSOpenPanel and immediately showed only the scan screen. The generated fixture contains 30 folders and 30,000 100-byte files. Live inspection showed file/folder counters, discovered bytes, elapsed time, current folder, stages, animation and Cancel. It completed with approximately 122.9 MB allocated, then exposed nested folder maps and four browser pages for each 1,000-file folder. No user data was deleted.

The minimum window is 960 × 640 with a compact scan presentation below 720 points high; the inspector/popover breakpoint uses outer workspace width so opening an inspector does not feed back into its breakpoint. Exact smaller-display layout, VoiceOver interaction, and accessibility settings still need a complete manual matrix. Previews include compact scanning and a light nested map.

### New million-entry benchmark

The Release benchmark measures the current schema and complete map-scene path. The flat generated dataset intentionally contains one million direct children; rendering it at 1200 × 650 combines them into one pixel-level aggregate, so the layout time is **not** representative of a detailed 10,000-tile scene.

| Measurement | Result |
| --- | ---: |
| Index insertion | 8.841 s |
| Aggregation | 0.554 s |
| Browser query | 0.127 s |
| Full-scope scene construction | 0.233 s |
| Scene entries before pixel aggregation | 257 |
| Items represented | 1,000,000 |
| Known bytes represented | 20,482,048,000,000 |
| 100 aggregate-heavy layouts | 0.00888 s |
| Peak benchmark resident memory | 19,972,096 bytes |
| Database size | 175,857,664 bytes |

Raw output: `.artifacts/map-benchmark.txt`. The benchmark still deletes its generated database after running; figures exclude full-app memory and real enumeration.

### Actual rendering instrumentation

An Animation Hitches recording of the running sample map captured drawer changes, folder navigation, and highlighting. It saved at `.artifacts/MapInteraction.trace`; exported events are `.artifacts/map-hitches.xml`. The recording contained 92 hitch rows, seven over 16.7 ms, with a maximum of approximately 41.67 ms. This was a Debug app under Instruments and desktop capture on a high-refresh display. These observations do not establish a constant 60 fps result. Additional Release profiling on target hardware remains appropriate.

A separate `.artifacts/Map-TimeProfiler.trace` was saved, but its exported CPU table contained no samples for that short interval, so no CPU hot-path conclusion is drawn from it. The Animation Hitches recording required an interrupt after its time limit to finish saving; its exported event table was successfully verified afterward. All profiling artifacts are ignored by version control.

Earlier implementation history follows; the current checks above supersede earlier test counts and flat-map benchmark figures.

## Initial implementation checks

- Universal Release app build succeeded. `lipo -archs` confirmed x86_64 and arm64 slices.
- Debug app and UI test bundle compiled with local ad-hoc signing. App Sandbox entitlements were present in the running sample app. Local ad-hoc signing disables hardened runtime for that development run.
- Thirteen Swift Testing tests passed: logical/allocated aggregation, hidden-file options, exclusions, hard-link deduplication, symlink traversal and deletion behavior, package accounting, unknown and incomplete totals, suggestion rules, Unicode-insensitive search, treemap area/overlap bounds, cancellation, selection normalization, changed-file fingerprints even with restored modification dates, replaced ancestors, protected paths, and partial cleanup outcomes.
- Native desktop inspection: sample scan completed; treemap and file table appeared; folder drill-down updated breadcrumbs; file selection updated the inspector; basket count and paths updated; both Trash and permanent-delete confirmations appeared and were cancelled. No user files were removed during desktop inspection.
- Project, entitlement, and privacy plist validation passed. The app includes all required macOS icon sizes.

## MVVM/source-structure refactor

The app source now uses feature folders with focused workspace, scan, explorer, cleanup, and settings view models. Xcode navigator groups mirror the filesystem. The core package is grouped by subsystem without changing its module name or existing public contracts. Repository-wide implementation guidance is in `AGENTS.md` and `ARCHITECTURE.md`.

- All 13 existing core tests passed after the moves.
- Three new hosted Swift Testing presentation tests passed: replacing an explorer session invalidates its pending query and clears navigation/selection; preferences persist across settings models; cleanup normalizes the basket and delegates a reviewed plan with ancestor identities to an injected recording service.
- The universal Release app built successfully with the new source groups, resource paths, and entitlement location.
- App/UI test targets compile after the refactor. Hosted presentation tests require no UI automation permission; the existing separate UI automation limitation below remains unresolved.

## Folder-picker access fix

The original picker path made optional bookmark creation a throwing prerequisite for accepting a folder. The scan request also reconstructed the authorized URL from its canonical path. The fix preserves the original security-scoped URL, keeps canonical paths inside enumeration/indexing, and performs bookmark creation/restoration off the main actor. Bookmark save/refresh failure no longer rejects valid current-session access. Actual folder-access failures and invalid saved grants still fail with contextual error diagnostics.

- All 14 core tests passed, including a regression for retaining the original request URL.
- All 6 hosted app tests passed, including bookmark-creation failure, stale-bookmark refresh failure, revoked scope rejection, and balanced start/stop counts.
- A separate normally sandboxed, locally signed verification app (`com.diskunbloat.pickercheck`) selected the generated external `.artifacts/PickerFixture` through NSOpenPanel and completed a scan: five indexed items including the root, a nested folder/file, a visible file, and a hidden file. Its signature had no XCTest all-files exception.
- Universal Release build verified after the fix. No filesystem permissions or sandbox restrictions were weakened.
- A live quit/relaunch bookmark-restoration check could not be completed because desktop-control calls timed out during restart. The injected restoration regressions pass, but cross-launch OS bookmark restoration remains unverified. Existing hardware/provider checks below still apply.

## Million-entry core benchmark

The release benchmark generates one million metadata records into a temporary SQLite index in batches of 512. It aggregates the root, queries the largest 2,000 rows, then computes the same treemap 100 times. It deletes its generated database afterward.

Final measured run (concurrent with an Xcode build, so timings are indicative):

| Measurement | Result |
| --- | ---: |
| Index insertion | 7.70 s |
| Root aggregation | 0.227 s |
| 2,000-row query | 0.125 s |
| 100 layouts | 0.182 s |
| Mean layout | 1.82 ms |
| Database size | 126,054,400 bytes |
| Peak resident memory | 21,463,040 bytes |

Earlier optimized runs were approximately 5.9–6.1 seconds for insertion and 1.6–1.8 ms per layout. Replacing repeated row-array reductions in the squarification algorithm reduced layout time from approximately 29 ms per layout.

An optimized million-entry Time Profiler recording was saved at `.artifacts/MillionEntry-TimeProfiler.trace`; raw benchmark output is `.artifacts/benchmark.txt`. These artifacts are ignored by version control. The trace predates the final folded-name search column, while the table above measures the final schema.

This benchmark measures the core's generated metadata, SQLite, and geometry workloads. It does not measure real filesystem enumeration, package-heavy trees, network latency, the full SwiftUI process, or rendered frame rate. A 60 fps interaction claim has not been established.

## Blocked or not yet exercised

The Xcode UI runner launched but timed out with: “Failed to initialize for UI testing … Timed out while enabling automation mode.” The UI tests compile, but their automated execution is **not** recorded as passed. Native desktop checks above were performed separately.

Before release, run these checks on available hardware in an authorized desktop session:

- Choose an external fixture folder through the system picker, quit/relaunch, restore its bookmark, and test stale/revoked bookmarks. The app-container sample does not establish external bookmark persistence.
- Denied directories and protected privacy locations in a signed sandbox build; verify partial scan labels and unknown totals. The incomplete-index unit test exercises propagation, not macOS TCC enforcement.
- iCloud and third-party File Provider placeholders; confirm no file contents download during metadata scanning.
- Read-only volumes, external SSDs, mounted images, and Trash support/failure behavior.
- NAS scans, mounted-volume boundaries, disconnect during enumeration, and cancellation after the blocking filesystem call returns.
- Finder reveal and Quick Look with real supported documents. Sample media extensions contain generated fixture bytes, not valid media payloads.
- Both appearances, VoiceOver, keyboard-only workflows, Reduce Transparency, Reduce Motion, and window resizing on smaller displays.
- Instruments SwiftUI/animation hitch profiling while navigating a real million-file scan; energy and memory checks on slower storage and Intel hardware.

Permanent-delete tests operate only on unique generated temporary fixture directories. No test empties Trash or mutates user-selected storage.

## Focused refresh and analysis — 2026-10-31

Implemented transactional branch replacement, raw/count size accounting, non-reused IDs, revision-aware queries, full-scope category statistics, Largest/Types/Candidates drawer tabs, curated rules, native input, buffered Dock-open routing, and English/Russian resources.

- Core Swift Testing: **27 tests passed**. New cases cover branch replacement, global hard-link ownership, preserved/replaced IDs and high-water allocation, rejected changed roots, partial refresh unknowns, package-interior protection, category accounting beyond map budgets, descendant cache ages/exclusions, per-item cleanup preflight, and selected symlink-root rejection.
- Hosted presentation Swift Testing: **24 tests passed**. Added refresh context/basket restoration, fast cancellation rollback, preservation of cancelled whole-scan safety, root-volume child requests, stable map geometry across drawer modes, ownership exclusions, cold/busy/multiple native open events, localization resources/path stability, and horizontal input recognition/deduplication. Existing session, pagination, bookmark, settings, and reviewed cleanup tests still pass.
- UI scenarios added for analysis tabs, folder refresh, and Russian launch. UI target compilation passes. An execution attempt was bounded at 100 seconds and timed out before any test completed; this is **not** an automated UI pass.
- Native desktop inspection of a normally sandboxed ad-hoc review build confirmed the Russian chooser, sample scan, map-only default, optional drawer, largest-file ordering, category breakdown, candidate explanations, folder focus, and refresh returning to the same folder with the drawer open. Inspection caught translated quick-target paths and English category labels; both were fixed and the path invariants/catalog coverage are now checked automatically.
- `Tools/audit-localization.py` validates **261 English/Russian catalog entries**, Russian plural categories, interpolation compatibility, compiler-extracted UI keys, and untranslated path construction. Plist/project/entitlement/privacy validation passes.
- Universal Release build verified for **arm64 and x86_64**, with owner signing configuration preserved.

### Updated million-entry benchmark

Release `DiskBenchmark 1000000` generates temporary metadata in batches, measures bounded queries/layout, and removes its database. This run includes the expanded accounting schema and indexes:

| Measurement | Observed |
| --- | ---: |
| Insert 1,000,000 entries | 14.797 s |
| Full aggregation | 2.675 s |
| 2,000-row browser query | 0.152 s |
| Largest 250-row query | 0.224 s |
| Full category query, 1,000,000 accounted entries | 0.566 s |
| Map scene | 0.280 s |
| Database size | 245,235,712 bytes |
| Peak resident memory, benchmark process | 30,752,768 bytes |

The scene contained 257 entries; pixel aggregation reduced this flat dataset to **one drawable aggregate tile**. Its 100 layouts took 0.011 seconds, which is not a measurement of a dense nested SwiftUI map or rendered frame rate. The additional raw sizes, identity/category indexes, and modification evidence increase storage/write work relative to historical measurements above. Folder refresh recalculates only affected identity groups and ancestor directories; it does not enumerate unaffected filesystem branches.

### SwiftUI interaction recording and remaining checks

A 40-second SwiftUI Instruments recording captured the sandboxed debug review app during drawer changes and folder navigation. Exported hitch data contains **151 rows**, **2 over 16.7 ms**, and a maximum of **54.167 ms**. This small sample/remote desktop run does not establish 60 fps or million-entry UI performance. Raw artifacts: `.artifacts/FocusedFeatures-SwiftUI.trace`, `focused-swiftui-hitches.xml`, and `focused-benchmark.txt`.

Direct Dock drag verification was blocked by a desktop-control timeout accessing Dock. Cold-launch buffering, validation, busy rejection, and document-type registration are tested/checked independently, but real OS grant delivery on a Dock drop remains unverified. Physical pinch/extra mouse buttons, rapid gestures, sustained hover and resize performance on dense maps, exact minimum-window behavior, English visual review, VoiceOver, and system Reduce Motion/Transparency still need a manual hardware/session pass. Native Russian layout was inspected at the review window size. The external-drive, cloud-provider, denied-location, read-only, disconnected-NAS, and cross-launch bookmark checks listed above remain required before distribution. No user files were removed during this work.

## 2026-10-31 — deletion queue, curated cache coverage, scan progress

Feature batch: compact chooser card; live listing of unreachable scan locations; approximate overall scan percentage; "add to deletion queue" wording with badges; queued items hidden from map/browser/statistics; hover card placement in the corner opposite the hovered tile; extended curated cache rules and a name-based regenerable rule with per-item candidate exclusions.

### Automated checks

- `swift test --package-path Packages/DiskCore`: 31 tests pass. New coverage: curated application-cache roots are suggested from a home scan, managed parents are excluded, device-support `childrenKeepingNewest` modes keep the newest version subtree, `CleanupSafety.blockedReasonCode` exempts only the exact curated locations (parents remain `.managedData`), a real clean up of a managed cache location through `CleanupService` with plan-borne exemptions, regenerable name matching via rule and suggestion queries, and `hiddenPaths` excluding subtrees from rows, summaries, and map scenes. Previous candidates/suggestions and exclusion tests still pass unchanged.
- Hosted app tests: 27 tests pass, including four new ones — the queue accepts a curated managed cache location and refuses its managed parent with the plan carrying `knownCacheRoots`; queued items disappear from rows, scene, and selection and return when unqueued; candidate exclusions hide and restore items; existing basket/session tests unchanged.
- Universal Release build passed. The localization audit validates 275 English/Russian entries including the new plural locations key, and the catalog kept Xcode's byte-identical formatting with only added/removed blocks in the diff (Foundation `localizedStandardCompare` reproduced the file's key ordering exactly).
- UI test bundle compiles as part of the test build; identifiers (`chooseLocation`, `recentLocations`, `scanOptions`, `loadSample`, `target-*`, `reviewCleanup`, `addToReview`, `scanIssues`) are preserved. The automated UI suite was not executed — same environment limitation recorded above ('desktop automation timeout'); not re-run.

### Honest defaults and remaining checks

- The overall percentage is discovered bytes over the volume's used space from one `statfs` call at scan start, labeled "≈" and "Approximate share of this volume's used data read so far". Subfolder scans can legitimately finish below high percentages; the bar jumps to 100% only on completion. Real-disk behavior across volumes, network mounts, and APFS container shares of `f_blocks` still needs a manual pass.
- Live issues during scans were verified in hosted tests at the model level only; grant-denied folders were not exercised against real TCC prompts in this session.
- Curated-cache deletions were verified against fixtures, never against real user data. The Telegram group container, editor, and browser cache locations require a hands-on review pass before relying on their suggestions (they are review-only, Trash-first).
- The hover card swaps corners relative to the hovered tile quadrant; it was code-reviewed and exercised in previews, but not verified with VoiceOver or on dense 10k-tile scenes.

### Phase-aware window sizing

The window now follows the scene: a 660 × 640 frame (content minimum 600 × 560) for chooser, scan, and preparing screens, and the remembered last full size (960 × 640 at minimum) for exploration, cancelled, and failed outcomes. The old fixed 960 × 640 SwiftUI minimum frame was replaced by per-phase `contentMinSize`; the issues sheet became size-adaptive. Build, core/app tests, and the localization audit pass. Animated resizing honors Reduce Motion and re-centers the change on the window's current center, clamped to the visible frame. Not yet exercised on real hardware: fullscreen transitions, multi-display clamping, state-restored oversized frames, dense-window interplay during rescan, and the automated UI suite (same desktop-automation limitation as above).

## 2026-10-31 — grouped quick actions

Feature: "All caches" and "Dev tools" quick actions scan several known home locations in one pass. `ScanRequest` gained `extraRoots`/`groupTitle`, the enumeration worker chains roots under a synthetic `ScanGroup.path` wrapper node (fresh parent stack, enumerator, and device check per root), `CleanupPlan.roots` authorizes multi-scope plans, refresh validates branches across the synthetic wrapper, and the app keeps the combined scope across post-cleanup rescans.

### Automated checks

- `swift test --package-path Packages/DiskCore`: 34 tests pass, including three new ones — a grouped scan stacks each real location under the wrapper with a missing root recorded as an issue (wrapper stays incomplete, children keep known sizes), a secondary-root branch refresh succeeds through the wrapper, and `CleanupSafety` multi-root scopes accept candidates inside any listed root while rejecting roots themselves, outside paths, and the synthetic wrapper. An intermediate worker regression that kept the root flag active after exhaustion (preventing batch termination) was caught by the fixture tests and fixed before any hosted or manual run relied on it.
- Hosted app tests: 32 tests pass, including three new grouped tests — the catalog shape (grouped targets list their locations; home stays single), `ScanViewModel` prepares stacked requests, allows refresh inside any listed root, refuses outside-scope and wrapper targets, and reuses the whole grouped scope on rescan while a new single selection clears it, and the explorer searches the union of all listed roots while focused on the wrapper and scopes to one subtree inside any root. All prior presentation tests still pass (the authorization retention test now exercises `retainOnly([URL])`).
- Release build and the full test-build (including the UI test bundle) compile. The Release binary smoke-launched for 7 seconds without crashing; no visual or UI automation was performed (same desktop-automation limitation as above).
- The localization audit validates 282 English/Russian entries; the new keys ("All caches", "Dev tools", their details, the grouped authorization message, the all-unreadable failure message, and the "%lld locations" plural with Russian one/few/many/other forms) were inserted by a script that reproduced Xcode's `localizedStandardCompare` ordering (verified equal before and after) and byte-identical formatting.

### Honest defaults and remaining checks

- Grouped authorization was verified at the model level only: the home-grant derivation, saved-location restore, and home-folder picker suggestion paths are unit and logic tested, but real picker/TCC flows for grouped targets were not exercised manually this session.
- Missing locations are skipped with a per-root issue, and a grouped scan of locations that produce no children fails with the new message; this was verified with fixtures (nonexistent paths), not against real TCC-denied homes.
- Docker/Android/VM/model-store root names follow common macOS defaults; unused defaults simply do not appear in the map. The actual set needs a hands-on pass on machines that use those tools.
- The dock/pill hover text uses the new "%lld locations" plural; VoiceOver and Russian visual review remain part of the manual pass above. No user files were removed during this work.
