# Automated two-tier selection — implementation plan

Status: implemented (2026-11-02; see `Documentation/VALIDATION.md` for results). Scope: the cleanup-queue panel gains two quick-select buttons that
select curated items automatically, split into two safety tiers, plus a scan parameter defining
"long-unused". No map, scanner, or cleanup-execution semantics change.

## 1. Product shape

After a scan reaches results, the right-hand "Select items to delete" panel shows a quick-select
row with two buttons:

| Button | Category | Meaning |
| --- | --- | --- |
| **Select safe items** | 1 | Junk and caches that are safe to delete (old build data, old simulator/device-support versions, long-unused local models). |
| **Select rebuildable items** | 2 | Content that might be useful but can be regenerated or restored (everything from tier 1 in full, plus live caches, current simulator/device data, and rebuildable folders like `node_modules`). Clicking it first shows a warning. |

A new scan parameter, **"Consider items unused after N days"**, defines when an item counts as
"long-unused" (default 90, clamped 1…3650).

Both buttons feed the existing deletion queue. The existing deletion flow is untouched:
`Delete Selected` → Trash confirmation → optional permanent-deletion confirmation → execution with
the existing per-item safety checks. The tier-2 warning is an additional gate before *selection*,
never a replacement for the deletion confirmations.

## 2. Terminology

- `AutoSelectionTier` (core): `.safe` (category 1) and `.regenerable` (category 2).
- **"Long-unused"**: the item's subtree has no recorded *content modification* within N days
  (`latestContentModification < now − N`), and dates/sizes are known. Unknown data never
  establishes eligibility — the same rule the existing age gates follow. This is deliberately a
  modification-based definition: access dates are not indexed, macOS atimes are lazy, and the
  architecture forbids access-date claims of "unused". UI wording must say "not modified in N
  days" where precision matters.
- **"Most recent" child**: the child with the newest `latestContentModification` (max descendant
  mtime), name as tie-break — identical to the existing `childrenKeepingNewest` SQL semantics.
  Deliberately *not* semantic version ordering of names ("most recent version" by usage/recency,
  which is what the index can honestly know).

## 3. Selection rules

### 3.1 Rule table

All rules are path-based against the real user home and apply **within whatever the current scan
covers**. Nothing outside this table is ever auto-selected.

| # | Location (home-relative) | Tier 1 (safe) | Tier 2 (rebuildable) |
| --- | --- | --- | --- |
| 1 | `Library/Developer/Xcode/DerivedData` | all contents | all contents |
| 2 | `Library/Developer/Xcode/iOS DeviceSupport` | all children except the **1** most recent | all children |
| 3 | `Library/Developer/CoreSimulator/Devices` | all children except the **2** most recent | all children |
| 4 | `Library/Android/sdk/system-images` | all children except the **1** most recent | all children |
| 5 | `Library/Android/sdk/ndk` | all children except the **1** most recent | all children |
| 6 | `.android/avd` | children that are **long-unused**, always excluding the single most recent child | all children |
| 7 | `.cache/lm-studio` | children that are **long-unused** | all children |
| 8 | `Library/Caches` | *nothing* | all children |
| 9 | every remaining `CleanupRule.userCaches` root (`~/.npm/_cacache`, `~/.gradle/caches`, `~/.cache/uv`, the Unreal Tournament cache, Chrome's `OptGuideOnDeviceModel`, the three Code – Insiders caches, the Telegram group-container cache) | in full | in full |
| 10 | name-matched regenerable folders anywhere in scope (`CleanupRule.regenerableNames`/`regenerableNamePrefixes`: `node_modules`, `Pods`, `DerivedData`, `.cache`, `.artifacts`, `.build`, `.build-cache`, `.derivedData*`) | *nothing* | the folder itself |

Notes on the table:

- **Keep-newest guards with a long-unused fallback** (rows 2–5, refined during implementation):
  the spec says "older versions (excluding the most recent one/two)". If previous versions exist
  (children beyond the newest N) they are selected; if the location has no previous versions (at
  most N children), the long-unused ones qualify instead of being kept as "the most recent". The
  threshold otherwise applies exactly where the spec says "long-unused" (rows 6–7). Row 6
  combines both: long-unused *and* never the single newest child (even if that one is
  long-unused, it stays).
- **AVD pairing** (row 6): an emulator is a `<name>.avd` directory plus its `<name>.ini` sidecar.
  Selecting an AVD selects both; the recency ranking uses the `.avd` directory. Other loose files
  in the folder are left alone.
- **LM Studio models** (row 7): direct children (model folders) are the candidates; loose files at
  the root are left alone.
- Row 10 goes to tier 2 because such folders "might be useful but can be rebuilt" — matching the
  existing *Regenerable folders* description verbatim. Tier 2 in a Home scan will therefore also
  pick things like `~/.cache` and every `node_modules`; that is intended and lands behind the
  warning, mirroring what the *Regenerable folders* suggestion already surfaces for manual review.
- Row 9 is **not age-gated** ("everything except one item"), even though the *suggestions* list
  age-gates cache candidates. The buttons are broader than the suggestions by design.
- **Explicitly never auto-selected** (manual selection only): Docker data, Parallels/UTM/other
  virtual machines, `.ollama`, `.cache/huggingface`, the rest of `~/Library/Android/sdk`
  (`platforms`, `build-tools`, `emulator`, …), and anything not in this table.

### 3.2 Why this reproduces the requested per-group behavior (conformance)

The rules are not branched on the scan group; the requested behavior falls out of the scope
intersection, and tests enforce it:

- **Dev tools scan** scope = `iOS DeviceSupport`, `CoreSimulator/Devices`, `DerivedData`,
  `~/Library/Android/sdk`, `.android/avd`, Docker, Parallels, Virtual Machines, UTM, `.ollama`,
  `.cache/huggingface`, `.cache/lm-studio`. Rule ∩ scope → tier 1: rows 1–7 exactly as requested
  (DerivedData full; DeviceSupport keep 1; simulators keep 2; system-images keep 1; ndk keep 1;
  long-unused AVDs minus the newest; long-unused LM Studio models) and tier 2: the same seven
  locations in full. `system-images` and `ndk` are grandchildren of the scanned
  `~/Library/Android/sdk` root and are still proposed — rules are path-based. Docker/VMs/ollama/
  huggingface are untouched in both tiers, as listed.
- **All caches scan** scope = `~/Library/Caches`, `~/.npm/_cacache`, `~/.gradle/caches`,
  `~/.cache/uv`, `DerivedData`, the Unreal/Chrome/Code caches. Tier 1 = rows 1/9 in full = every
  listed location **except** `~/Library/Caches` ("everything except one item"); tier 2 adds all of
  `~/Library/Caches` ("absolutely everything").
- In the single-location **User caches** scan (`~/Library/Caches` only) tier 1 legitimately
  selects nothing; the empty-result notice covers that case.

### 3.3 Queue entry shapes

- A fully covered location that is an **exact scan root** is queued as one `.emptyContents` entry
  (contents removed, folder stays) — the existing `CleanupViewModel.add` mapping. This keeps
  grouped scans cheap: "all of DerivedData" is one row.
- Partially covered locations (keep-newest, thresholds) queue per-child `.remove` entries.
- Non-root containers (e.g. `system-images` in a Home scan) queue per-child `.remove` entries;
  the container folder stays, matching the existing `.children` candidate semantics.
- `rootItself` caches (row 9) follow the existing candidates: outside grouped scans the folder
  itself is the `.remove` entry.

## 4. The "long-unused" scan parameter

- `ScanOptions.longUnusedDays: Int` (Codable-compatible addition, default 90), edited in
  `ScanOptionsView` ("Scan your way" popover) as a labeled stepper/field with a caption such as
  "Defines which simulator and model data counts as long-unused for automatic selection."
- Persisted in `UserDefaults` (like `SettingsViewModel`'s thresholds) so the definition survives
  launches; note in code that this one scan option persists while the others reset per launch.
- Consumed **at selection time** from the current options — changing it and clicking a button
  again re-applies with the new threshold; no rescan is needed because enumeration does not depend
  on it. It also rides along in `sessionOptions` for refresh/rescan coherence.

## 5. Interaction model

- Quick-select row directly under the panel header (visible without scrolling): the two buttons
  with one-line captions ("Caches, old build data and other junk that is safe to delete." /
  "Includes caches, simulators and other content you can rebuild or restore.").
- Enabled only when `canClean` (completed, non-cancelled scan; cleanup idle) — the same gate as
  checkboxes and `Delete Selected`. Disabled while a proposal is being computed (small spinner in
  the row).
- **Tier 1 click** → compute proposal → apply immediately (no warning, per requirement). Empty
  proposal → non-blocking notice: "Nothing recommended in this scan."
- **Tier 2 click** → compute proposal → **warning dialog** with an honest estimate computed from
  the proposal ("Selects ~N items · ≈X GB"), e.g.:
  - Title: "Select everything rebuildable?"
  - Message: "This selects an extensive cleanup: live caches, simulator and device-support data,
    local models, and rebuildable folders. Removing them can interrupt running apps and developer
    tools, force re-downloads and rebuilds, and some content can only be restored by re-downloading
    it. Review the selection before deleting."
  - Actions: "Select anyway" / "Cancel" (cancel role). Only confirmation applies the selection.
- **Apply semantics (confirmed):** clicking a tier button replaces what previous tier clicks
  selected and keeps manually selected items. Re-clicking re-applies cleanly — manually unchecked
  recommendation items come back, which is what "select recommended items" means.
- Skipped items (blocked by safety rules or running-app caches) are never force-added; the result
  notice reports the count, e.g. "3 items were skipped by safety checks."

## 6. Architecture and ownership

### DiskCore (domain + SQL)

- `Suggestions/AutoSelection.swift` (new):
  - `public enum AutoSelectionTier: Sendable { case safe, regenerable }`
  - `public struct AutoSelectionRule: Sendable` — home-relative path plus a tier-1 coverage mode:
    `.none`, `.all`, `.keepNewest(Int)`, `.keepNewestUnused(Int)`, `.unusedOnly`; tier 2 is always
    full coverage; a separate flag marks the AVD sidecar pairing.
  - `public enum AutoSelectionSpec { public static func rules(home: String) -> [AutoSelectionRule] }`.
    Row 9 derives from `CleanupRule.userCaches.roots(relativeTo:)` so quick scans, cleanup
    candidates, and auto-selection cannot drift apart; rows 2–8 and 10 are explicit.
- `Indexing/ScanIndex+Query.swift`:
  - `autoSelectionCandidates(home:tier:unusedDays:inspectPackages:)` →
    `AutoSelectionResult { nodes: [FileNode], itemCount: Int, knownBytes: Int64, unknownCount: Int }`
    in one actor turn. Exact totals come from SQL aggregates; nodes are materialized for the
    queue. Reuses the existing exclusion semantics (`symlink=0 AND insidePackage=0 AND incomplete=0`,
    system-tree exclusions) and `regenerableNameSQL` for row 10.
  - Keep-N generalization of today's hardcoded keep-1 range trick:
    `id NOT IN (SELECT id FROM nodes WHERE parent = <root> ORDER BY COALESCE(latestModified,0) DESC, name DESC LIMIT N)`,
    plus the threshold clause `unknownModified=0 AND unknownAllocated=0 AND latestModified < cutoff`
    for rows 6–7.
  - `coalescedHiddenRanges(for paths: [String]) -> [String]` — collapses queued paths that cover
    every child of a container into one descendant range (map-hiding scale; see §8).
- Tests in `Packages/DiskCore/Tests/DiskCoreTests` with unique generated fixtures.

### DiskUnbloat (app)

- `Cleanup/ViewModels/CleanupViewModel.swift`: bulk `applyAutoSelection(nodes:roots:)` — one
  safety pass per node (exactly the `CleanupSafety` + `ApplicationActivityProviding` checks `add`
  performs, refusals collected), then **one** `CleanupPlan` normalization and one basket
  assignment. Tracks `autoSelectedPaths` (last applied recommendation) so re-apply replaces the
  previous auto selection and keeps manual entries; cleared in `reset()`. Returns an outcome with
  applied/skipped counts. (Calling `add` per node is unusable at this scale — it renormalizes the
  whole basket on every call.)
- `Workspace/ViewModels/WorkspaceViewModel.swift`: `selectItems(tier:)` intent — guards `canClean`,
  runs the proposal against `scan.index` in a task, checks the index/session identity after the
  await, calls `cleanup.applyAutoSelection`, and surfaces empty/skipped notices via `message`.
  Cross-feature orchestration lives here, per the ownership map.
- `Cleanup/Views/CleanupQueueView.swift`: quick-select row, `@State private var confirmRegenerable`
  warning dialog, notices; new closures (`selectTier: (AutoSelectionTier) -> Void`) passed from the
  workspace, same pattern as `performCleanup`.
- `Cleanup/Models/CleanupQueueModels.swift` + `CleanupQueueModel.swift`:
  - prefix-sum selected-bytes per refresh (today `render` reduces over all entries per row);
  - a container whose children are all entries renders as one atomic checked row
    ("Keeps folder" caption when applicable; expandable to its entries) instead of N nested rows.
- `Scanning`: `ScanOptionsView` field bound to `ScanViewModel`, persistence in `UserDefaults`.
- Optional polish: `KnownLocation` entry for `~/Library/Android/sdk` so the hover card explains
  `system-images`/`ndk` (other locations already have curated hover explanations).

## 7. Safety invariants (must not regress)

1. Proposal items pass exactly the checks manual selection uses. Scan roots become
   `.emptyContents` (folder stays) and are never removed; `/`, volume roots, system trees, package
   internals and managed application data stay blocked; the curated-cache exemption
   (`CleanupPlan.knownCacheRoots`) is unchanged. Refusals are skipped and counted, never forced.
2. The running-application preflight is rechecked before every mutation at execution time
   (unchanged); the queue-time activity check runs per applied node.
3. No Trash→permanent fallback; both deletion confirmations remain; the tier-2 warning is an
   extra gate before selection only.
4. Cancelled/failed results keep cleanup disabled — the buttons follow `canClean`.
5. Queue totals derive only from normalized `CleanupEntry` values, stay labeled as estimates, and
   unknown sizes keep their warning. Queued items disappear from the map and return on
   deselect/delete (existing `hiddenPaths` mechanism).
6. "Long-unused" claims stay modification-based and honestly worded; no access-date claims.
7. Irreversible action still requires explicit review: the buttons select, they never delete.

## 8. Scale and performance

Realistic worst case is a Home-folder tier-2 selection of thousands of entries
(`~/Library/Caches` children, `node_modules` trees). Required work:

- Bulk apply is O(n log n) (single normalization), not per-entry.
- Queue tree selected-bytes via one prefix-sum pass (fixes today's O(rows × entries) reduce).
- Fully-covered containers collapse to one atomic row (so "all of ~/Library/Caches" is one row,
  not 1 000+).
- Map hiding: each hidden path currently adds three SQL terms/binds to every map query. Coalesce
  complete-sibling sets into ancestor descendant-ranges (`coalescedHiddenRanges`), and measure
  scene queries with ~10 000 hidden paths; if still slow, load ranges into a temp table instead of
  a `NOT (…)` clause list. A measured budget is part of the phase-2 acceptance.
- The proposal query returns exact totals via SQL aggregates even before nodes materialize, so the
  tier-2 dialog is cheap and honest.

## 9. Localization

All new strings go to `Resources/Localizable.xcstrings` (English + Russian, explicit Russian
plural categories, accessibility labels). Planned keys: button labels and captions, tier-2 warning
title/message/actions, scan-option label and caption, empty-proposal notice, "%lld items skipped"
plural, tooltips. Run `Tools/audit-localization.py`, keep `localizedStandardCompare` key order and
byte-identical formatting, and update `LocalizationTests`. Paths, IDs, and rule names are never
translated. Proposed English wording is listed in §1/§4/§5 and is open for review before the
localization pass.

## 10. Testing plan

Core (`DiskCoreTests`, unique generated fixtures over a fake home):

- Selection matrix per row of §3.1: keep-1, keep-2, threshold-only, threshold + keep-1 (AVD,
  including the `.ini` sidecar), full coverage, and row 8/row 10 exclusions from tier 1.
- Unknown-modification/unknown-size nodes never become threshold candidates; incomplete nodes
  skipped; ties in "most recent" broken by name.
- Tier 1 ⊆ tier 2 within any scope; name-matched regenerable appears only in tier 2.
- Closed list: Docker/Parallels/ollama/huggingface and non-listed Android SDK parts are never
  proposed.
- Conformance corollaries for the Dev tools and All caches scopes (asserting the exact requested
  sets), plus the empty User-caches tier-1 case.
- `coalescedHiddenRanges` correctness (complete coverage collapses; partial coverage does not).

App (`DiskUnbloatTests`):

- Bulk apply replaces the previous auto selection and keeps manual picks; re-click re-applies;
  skipped refusals are reported and never queued.
- Tier 2 applies only after the warning confirmation; cancel leaves the queue untouched.
- Empty-proposal notice; disabled states while cleaning and on cancelled scans.
- Queue totals remain normalized-entry totals after a bulk apply; large-basket smoke test
  (e.g. 1 500 synthetic entries) with a coarse time budget as a regression guard.
- `longUnusedDays` persistence and clamping.

UI (`DiskUnbloatUITests`): one optional smoke scenario (buttons visible after a scan, warning
appears for tier 2). Record the established desktop-automation limitation honestly in
`Documentation/VALIDATION.md` if the suite cannot run.

## 11. Implementation phases

1. **Core rules + query**: `AutoSelection` spec, `autoSelectionCandidates`, keep-N SQL, hidden-range
   coalescing + core tests.
2. **Perf prerequisites**: queue-tree prefix sums, atomic fully-covered rows, measured hiding cost.
3. **Bulk apply**: `CleanupViewModel.applyAutoSelection` + replace/keep semantics + tests.
4. **Panel UI**: quick-select row, tier-2 warning dialog, notices + localization pass.
5. **Scan parameter**: `ScanOptions.longUnusedDays`, `ScanOptionsView` field, persistence.
6. **Docs/verification**: ARCHITECTURE.md (auto-selection ownership, rule table reference,
   "long-unused" semantics), `python3 Tools/generate-project.py` for new app files,
   `swift test --package-path Packages/DiskCore`, universal Release build,
   `build-for-testing`, localization audit, VALIDATION.md entry.

## 12. Decisions and open points

- "Most recent" is modification/recency based (name tie-break), not semantic version order —
  version strings mis-sort across locations (`ndk/9…` vs `10…`) and the index only knows dates
  honestly. Revisit if version-aware ordering is wanted per location.
- Threshold gating applies only where the spec says "long-unused" (AVD, LM Studio). If preferred,
  the keep-newest rows can also require the threshold — a one-line rule change.
- Row 10 (regenerable names) intentionally reaches into tier 2 only and includes folders like
  `~/.cache` in Home scans; the warning text must make the breadth clear.
- In grouped scans, tier-2 "everything" cleans listed roots in place (folder stays) — the existing
  scan-root rule; in single-root scans the same curated folders are removed outright where the
  candidates say `.rootItself`.
- Optional follow-ups: per-row badge showing which tier selected an item; "why selected" note in
  the hover card; a third tier for name-matched folders in arbitrary scans.
