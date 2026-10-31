# DiskUnbloat contributor guidance

Read `Documentation/ARCHITECTURE.md` before implementing or reorganizing a feature. It defines the MVVM ownership map, directory tree, dependency direction, concurrency boundaries, and safety rules. Keep that document current when these boundaries change.

## Required structure

- App entry point, lifecycle and entitlements: `DiskUnbloat/App`.
- Product features: `DiskUnbloat/Features/<Feature>/Views` and `ViewModels`.
- App-only OS adapters: `DiskUnbloat/Services/<Capability>`.
- Actually shared presentation utilities: `DiskUnbloat/Shared/<Purpose>`.
- Assets/privacy manifest: `DiskUnbloat/Resources`; previews/generated samples: `DiskUnbloat/PreviewContent`.
- Domain models and filesystem/indexing/cleanup/layout logic: the matching subsystem under `Packages/DiskCore/Sources/DiskCore`.
- Core behavior tests: `Packages/DiskCore/Tests/DiskCoreTests`; app presentation tests: `DiskUnbloatTests`; UI scenarios: `DiskUnbloatUITests`.

## MVVM boundaries

Use `@MainActor @Observable` classes named `…ViewModel` for presentation state. Views render state and invoke intent methods; local confirmation/hover/layout state can remain in the view. Inject services rather than constructing them inside views. Keep core independent of SwiftUI/AppKit and the app target.

`WorkspaceViewModel` composes feature view models and coordinates cross-feature workflows and shutdown. Keep chooser/quick-target/drop state in `LocationSelectionViewModel`, scan state in `ScanViewModel`, query/navigation/selection state in `ExplorerViewModel`, review/operation state in `CleanupViewModel`, and preference state in `SettingsViewModel`. Pass focused models or values and action closures to child views. Do not grow the workspace into another all-purpose model or add redundant forwarding state.

Keep blocking enumeration on its dedicated queue, indexing inside its actor, and expensive layout off the main actor. Preserve Sendable contracts, task ownership, cancellation, query-session invalidation, and balanced security-scope lifetimes. Do not add unchecked concurrency annotations without a documented invariant and migration follow-up.

Preserve cleanup protections, identity/fingerprint/ancestry validation, explicit review and irreversible-action confirmation. Never fall back from Trash to permanent deletion. Do not equate age or size with safe deletion or promise unrestricted disk access/exact reclaimed space.

## Project maintenance and verification

After adding or moving app Swift files, update matching Xcode groups and build membership. `python3 Tools/generate-project.py` recursively regenerates the checked-in project (`DiskUnbloat.xcodeproj/project.xcproj`, the Xcode 27 JSON format, which requires Xcode 27 or later and is canonicalized with Apple's `xcprojformatter`); preserve any owner-configured signing/team/bundle settings when editing or running the generator. The file uses JSON5-style trailing commas, so scripts that read it must use a JSON5-tolerant parser, not plain `json.loads` or `jq`. Resource and entitlement paths must remain correct. SwiftPM discovers nested core files automatically.

Run `swift test --package-path Packages/DiskCore`, a generic macOS Release build, and relevant app/UI test compilation after structural changes. Add tests for changed behavior, especially asynchronous session replacement and cleanup. Never perform destructive tests on user-selected files; use unique generated fixtures. Record unrun or environment-blocked validation honestly in `Documentation/VALIDATION.md`.

## Map-first product invariants

- Route screens using `WorkspacePhase`: choosing → scanning → preparing results → exploring. Launch and scanning must not mount the explorer's toolbar, panels, or file table. Cancelled/failed scans use dedicated outcomes; viewing a cancelled map requires opt-in and keeps cleanup disabled.
- Keep secondary panels optional. The map owns the results canvas; the file browser is a paginated, resizable drawer and the inspector opens on demand. Preserve the explorer's 960 × 640 minimum layout and accessibility shortcuts. The window follows the phase: chooser and scan screens are compact, and entering results restores the remembered full size; fullscreen frames are never resized programmatically.
- Build maps from bounded `MapScene` queries, never from a browser page. Account for all known bytes with atomic folders/aggregate tiles when depth, pixel, or entry budgets are reached. Do not collapse partial folders to zero. Keep legend highlighting independent of layout/filtering.
- Publish real stages/counters. The overall percentage is an approximation of the scanned volume's used data already read (discovered bytes versus the volume's used space measured once at scan start) and must stay labeled as approximate; never fabricate finer precision. Keep decorative animation independent of scanner updates, paused in inactive scenes, and compatible with Reduce Motion/Transparency. Do not delay short scans to show an animation.
- Quick targets must use the real user home and system-granted access, never container search paths as a substitute for the user's folders. Missing/revoked locations require picker authorization or a useful error, never additional entitlements or an implicit all-files grant.
- Grouped quick actions ("All caches", "Dev tools") scan several known home locations in one pass behind a synthetic group root (`ScanGroup.path`). They authorize through the home grant so every listed location is covered; missing members are skipped and listed as scan issues, and the scan fails only when no listed location is readable. The combined scope persists for post-cleanup rescans; refresh reruns the whole group for the wrapper and works inside any listed root otherwise. Cleanup keeps the full scope list, so boundaries still apply around every root.

## Refresh, analysis, and localization invariants

- Refresh branches through staging plus `ScanIndex.replaceBranch`; never remove live rows before a scan succeeds. Preserve raw sizes, identity groups, stable IDs/high-water allocation, revision invalidation, and overlapping-basket review invalidation.
- Statistics and ranking query the complete scoped index; never derive totals from a map scene or browser page. Drawer modes must not alter geometry.
- Curated rule matching is core SQL/domain behavior. Application activity and translated explanations are injected app adapters; unknown activity never means safe deletion. Recheck activity before each operation. Only the exact curated cache locations (and their contents) are exempt from managed-data protection; their parents and every other managed tree stay blocked, and the exemption travels on the cleanup plan. Items queued for deletion disappear from the map, browser, and statistics until they are removed from the queue or deleted.
- Native open-file events and drops share validation/authorization. Buffer cold-launch events; reject busy/multiple-location requests explicitly.
- Add every shipping string to English/Russian catalogs, including plural forms and accessibility. Translate labels only, never paths, IDs, or bookmarks. Run the localization audit and keep project resources/regions in sync.
