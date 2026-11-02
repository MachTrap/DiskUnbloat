# Validation — November 1, 2026

Toolchain: Xcode 27.2 (27B52), Apple Swift 6.4.2, macOS 26 deployment target, Apple Silicon execution host.

## Post-cleanup map continuity — stay on the updated map — 2026-11-02

- **Behavior change:** a successful cleanup no longer bounces the app back to the location chooser (dropping the index and forcing the user to re-pick and re-wait for a scan of the same directory). `performCleanup` now reruns the scan of the same scope on the spot through `startScan(preservingCleanupReport: true)` — the exact rerun path the group-wrapper refresh already used, so the combined grouped scope also persists — and lands back on the updated map with the deletion report kept visible. The fresh scan rebuilds hard-link and aggregate accounting as before, and `ScanViewModel.run` discards the stale index itself, so no manual `discardIndex` was needed. Failed cleanup runs leave the map and queue untouched awaiting review, exactly as before.
- The scanning phase is still shown during the automatic rerun (real progress, no fabricated map), and `prepare()`'s designed "same scope again after a cleanup rescan" path drives both single-folder and grouped scans.
- Test rewrite: `performCleanupReturnsToStartScreenInsteadOfRescanning` became `successfulCleanupRescansTheScopeAndReturnsToTheUpdatedMap` — it asserts the app lands on `.exploring` (never the chooser), a fresh index replaces the old one, the deleted branch disappears from the map, the basket empties, the deletion report stays, and cleanup remains possible. Core tests are unaffected (no DiskCore change). Hosted app tests 64 pass; universal Release build passes.

## Phase G — Game launcher caches: Steam curated stores and Roblox — 2026-11-02

- **Steam** (verified against Steam's documented macOS layout and a bundle-ID catalog): six curated tier-1 `rootItself` stores — `Application Support/Steam/appcache`, `htmlcache`, `depotcache`, `steamapps/shadercache` (per-game folders keyed by app ID, recompiled on the next launch), `steamapps/downloading`, and `steamapps/temp` — all grouped under All caches, with removal refused while Steam runs through the verified `com.valvesoftware.steam` ID. Protective hover entries cover `steamapps/common` (games: use Steam's own uninstall; no purchases lost, only re-downloads) and `userdata` (Steam Cloud saves — never auto-selected). `steamapps/common`, `userdata`, and `workshop` are pinned as never-selected in `gameStoreCachesMatchTheTierSets`, which also inherits tier coverage for the Phase F stores that lacked it (Unity UPM cache, Resolve Fusion/DiskCache, Figma Chromium cache, Adobe Peak Files children — identical sets in both tiers).
- **Roblox** (verified against Roblox's support articles): the Player and Studio caches already sit inside the blanket `~/Library/Caches` scan and now carry hover explanations (`com.Roblox.Roblox`, the case-variant `com.roblox.RobloxPlayer`, and `com.Roblox.RobloxStudio`); `RobloxStudio/AutoSaves` is hover-explained as a recovery store that is never auto-selected. No `Versions` folder exists in the macOS Application Support tree (Windows-only layout per Roblox's own docs), so no rule was invented for it.
- **Out of scope with verified reasons:** Battle.net/WoW (agent data lives in `/Users/Shared/Battle.net`, outside the home folder that grouped scans authorize — the same reach boundary as the Caskroom Conda variant), Minecraft (world saves mixed beside its regenerable `versions`/`assets`/`libraries` trees — needs a dedicated verified pass with per-child protection), and other launcher layouts awaiting verification (Heroic, League). Epic's launcher cache was already covered.
- Tests: core 66 pass; hosted app tests 64 pass with the new Steam root assertions (and the "never lists games/saves" negative guards). Universal Release build passes; localization audit validates 473 entries.

## Phase F — Telegram media fix, Ollama rule, Unity/Resolve/Figma/Conda/leftover stores, guardrail hovers — 2026-11-02

The planned remaining catalog work shipped as Phase F:

- **Telegram media-preserve (P5 fix):** a new `CleanupRoot` wildcard shape (`Library/Group Containers/…/Telegram/stable` + `account-*/postbox/media`) resolves each match against the real filesystem inside `roots(relativeTo:)` — only existing accounts' media folders are curated `rootItself` candidates in both tiers, and the whole-container delete (which could log the user out of Telegram Desktop) is gone. The running-app guard now keys on `ru.keepcoder.Telegram`, and the managed-data exemption covers only the resolved media paths (the container and the `account-*` data beside it stay `.managedData`). Two tests pin the behavior: a filesystem-resolution unit test (accounts matched by prefix, lookalikes/skip-file/empty layouts rejected) and an end-to-end suggestion + safety test with a materialized tree.
- **Ollama:** `~/.ollama` rule with `eligibleChildNames: ["models"]`, tier-2-only — the rebuildable tier can clear model blobs; `id_ed25519` and every other child stay structurally unreachable.
- **Game engines and image generators:** Unity's UPM cache and DaVinci Resolve's Fusion/DiskCache (`rootItself`, tier 1), `CacheClip` in the rebuildable names (tier 2), Figma's `DesktopProfile` Chromium caches, plus Zotero-independent Adobe `Common/Peak Files`/`PTX` children and `~/Library/Caches/Adobe/…` hover entries. **Unity/Resolve/Figma ship without running-app guards** — no bundle ID could be verified from primary sources after three targeted searches (Unity's editor IDs are version-qualified; Figma/Resolve didn't surface); documented in code, ARCHITECTURE, and this document.
- **Leftover stores:** Deno, Ivy2, Terraform plugin cache, sccache, Composer (all tier-1 `rootItself`), Conda's four `pkgs` layouts (tier-2-only children rules + Dev-tools roots), the editors' `Code Cache` + `Service Worker/CacheStorage` (tier-1 `rootItself`), `~/.cache/clip` and `~/.keras` (tier-1 `unusedOnly`, closed eligible children for Keras, tier-2 full).
- **Guardrail visibility:** Xcode Archives joins Dev tools + a hover explanation (never a rule); agent roots `.claude`/`.codex`/`.cursor` earned protective hover entries; the blanket-caches hover list gained go-build, Coursier, pypoetry, pdm, pipenv, CocoaPods, Carthage, and the Deno default store.
- **Final Cut hover:** a name-suffix KnownLocation mechanism explains `.fcpbundle` bundles wherever they live (hover-only; the bundle interior stays package-protected).
- **Deliberately out:** Selenium and Weights & Biases (layouts unverified), Blender (unverified), the Homebrew-Caskroom Conda variant (outside the home scan's reach), `~/.ccache` (mixes user config — the blanket caches already cover the default dir). All documented in the plan.
- Tests: core 65 pass — `wildcardRootsResolveRealDirectoriesOnly`, `phaseFRulesMatchTheTierSets` (per-account Telegram, Ollama models, Unity Asset Store tier 2, Conda tier 2, CLIP/Keras contracts, `CacheClip`, with `id_ed25519`/`user-notes` exclusions), and the rewritten `curatedAppCachesSuggestManagedLocationsAndKeepNewestDeviceSupport` (media-dir candidates + the container staying blocked). Hosted app tests 64 pass, including a hermetic rewrite of `cleanupQueueAcceptsCuratedManagedCacheLocationsOnly` (media joins the queue, parent/account refused) and `nameSuffixLocationsHoverLibraries`. Universal Release build passes; localization audit validates 457 entries.

## Phase E — Godot, Unreal Engine, ComfyUI, and CI caches — 2026-11-02

All four stores researched against official/primary sources and shipped:

- **Godot:** `~/Library/Caches/Godot` (the documented "safe to remove when closed" editor cache, already under the blanket caches root) gains a hover explanation; `Application Support/Godot/export_templates` (one ~1 GB install per engine version) becomes a keep-newest curated root in Dev tools — tier 1 preserves the newest template, tier 2 removes every version; Godot 4's project-local `.godot` import/build cache joins `regenerableNames` (tier-2-only, no evidence needed — the name is engine-exclusive). `app_userdata` (the documented `user://` game-save space) is never a candidate in any tier; the running-editor guard is keyed on the `org.godotengine` bundle prefix.
- **Unreal Engine:** the shared Zen store `Application Support/Epic/UnrealEngine/Common/Zen/Data` (Epic's documented UE 5.4+ local DDC + cooked-output location; everything derives from project assets and DDC data) joins as children candidates in tier 1 in full, blocked while any `com.epicgames.*` app runs (anchored by the code-signing-verified launcher ID). Project-local `Intermediate`/`DerivedDataCache` now match the manifest rules through the new suffix-evidence mechanism — a sibling ending in `.uproject` `.uplugin` (a name merely containing the suffix, or no descriptor at all, never matches). `Saved` stays excluded (user settings, crash data, autosaves).
- **ComfyUI:** both desktop generations' Electron caches are curated tier-1 `rootItself` caches — `Application Support/Comfy Desktop/{Cache,Code Cache,GPUCache}` (guarded while Comfy Desktop's ToDesktop-verified ID `com.todesktop.241012ess7yxs0e` runs) and `Application Support/ComfyUI/{Cache,Code Cache,GPUCache}` (1.x home; no verified app ID, so no guard — documented honestly). `~/ComfyUI-Installs` and `~/ComfyUI-Shared` (shared models **and generated outputs**) are hover-explained mixed stores, never auto-selected; user workfiles under a chosen base path are entirely out of scope.
- **CI/CD:** `~/.cache/act` (nektos/act's downloaded Actions and workflow cache artifacts, verified via act's documented XDG paths and real runner logs) joins as a tier-1 `rootItself` cache; the default self-hosted Actions runner layout is covered by a scan-and-explain `actions-runner/_work` Dev-tools root plus tier-2-only children rules for `_work/_tool` (SDK stack cache) and `_work/_actions` (cached action checkouts) — runner binaries above stay untouched. GitLab Runner and CircleCI's CLI ship nothing (no stable verified home caches).
- The manifest rule performance note: evidence subqueries are indexed (`nodes(parent)`) and only run for rows whose name matched the closed manifest list.
- Tests: core 63 pass — `engineComfyAndCiLocationsMatchTheTierSets` pins both tiers for the Godot/Zen/Comfy/act/runner sets with the `app_userdata` and `config.json` exclusion guardrails, and `unrealBuildFoldersVerifyByUProjectSuffix` pins `.uproject`/`.uplugin` evidence, lookalike-suffix rejection, no-evidence rejection, and the `.godot` flow. Hosted app tests 63 pass with the extended catalog assertions. Universal Release build passes; localization audit validates 396 entries.

## Phase D — sibling-verified rebuildable names, Minikube — 2026-11-02

- **Sibling-evidence matching (`CleanupRule.regenerableManifests`):** the context-dependent names that Phase C deliberately deferred now join the rebuildable tier only when the parent's real indexed children prove the tool context — `target` beside `Cargo.toml`/`pom.xml`, `.venv`/`venv` beside one of five Python manifests (`pyproject.toml`, `requirements.txt`, `Pipfile`, `uv.lock`, `poetry.lock`), and Unity's `Library` beside both `Assets` and `ProjectSettings` (so `~/Library` and ordinary data folders can never be shadowed). Implemented as correlated `EXISTS(SELECT 1 FROM nodes sib WHERE sib.parent=nodes.parent AND sib.name=?)` checks in the shared regenerable predicate (`ScanIndex+Query.regenerableNameSQL`), so the Rebuildable filter, the suggestions, and the tier-2 name-matched auto-selection all pick the manifest flow up with no rule plumbing; evidence subqueries are indexed via `nodes(parent)` and only run for rows whose name matched. Names whose ambiguity cannot be bounded even by evidence (Carthage `Build`, Unreal `Intermediate`/`DerivedDataCache`, generic `.output`) stay deferred in the plan.
- **Minikube:** `~/.minikube` joins the Dev tools scope and hover explanations as scan-explain-only like the other VM runtimes; its pure download tree `~/.minikube/cache` is a tier-2-only children rule, while the cluster VM disk itself is never auto-selected.
- The Rebuildable filter's explanation now states the matching shapes honestly ("matched by name, or verified by the sibling project files that produced them") in English and Russian; one new hover entry ships in both catalogs (369 entries).
- Tests: core 61 pass — new `regenerableManifestsRequireTheirSiblingEvidence` (query + suggestion level: marker evidence required per rule, missing sibling disqualifies, a no-marker `venv` stays out) and `manifestVerifiedFoldersJoinTier2Only` (tier 1 empty, tier 2 selects only verified cases — a bare `target` folder without `Cargo.toml` never matches). Hosted app tests 63 pass; universal Release build passes; localization audit validates 369 entries.

## Phase C coverage expansion — project-local rebuildable names — 2026-11-02

The final roadmap phase of `Documentation/PLANS/CacheAndRebuildableExpansion.md` shipped:

- **`CleanupRule.regenerableNames` grew from 7 to 31 unambiguous names**, all tier-2-only: front-end framework build/cache folders (`.next`, `.nuxt`, `.svelte-kit`, `.astro`, `.angular`, `.docusaurus`, `.turbo`, `.parcel-cache`, `.vite`), Python tooling caches and ephemeral environments (`__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `.nox`, `.dart_tool`), and distinctive build-system folders (`.gradle`, `.zig-cache`, `zig-cache`, `zig-out`, `cmake-build-debug`, `cmake-build-release`, `.serverless`, `.terragrunt-cache`). Every new name is exclusively generated by a compiler, bundler, linter, or runner and never holds hand-written sources.
- **Context-dependent names deliberately stay out:** `target` (Cargo/Maven), `build`, `.venv`/`venv`, Unity's `Library`, Unreal's `Intermediate`, and generic `.output` can shadow hand-written or versioned content; they now require sibling-manifest verification (a future name + adjacent-marker rule shape), documented as deferred in the plan.
- The Rebuildable filter's explanation now names broadened exemplars (`.next`, `__pycache__`) in English and Russian (the key text changed with both translations replaced); the rule stays tier-2-only behind the rebuildable warning and deletion confirmations.
- Tests: core 59 pass — `expandedRebuildableNamesMatchTier2AcrossKinds` pins tier 2 selections across frameworks, Python, infra, Zig, and CMake projects while asserting lookalikes (`build`, `.venv`, `.output`, `Library`) and tier 1 never match. Hosted app tests 63 pass unchanged; universal Release build passes; localization audit validates 367 entries.

## Phase B coverage expansion — AI/ML stores, language stores, container runtimes — 2026-11-02

The second roadmap phase of `Documentation/PLANS/CacheAndRebuildableExpansion.md` shipped:

- **LM Studio modern store:** `~/.lmstudio` joins the Dev tools scope with the legacy-store precedent mirrored — tier 1 selects long-unused regenerable children only via the closed list `["models", "hub", ".internal"]`; chats and presets are never selectable in either tier; the `.cache/lm-studio` rule stays for older installs.
- **Local AI model stores:** Hugging Face (`~/.cache/huggingface`) is now tier-selectable — `hub`/`datasets` children long-unused in tier 1, full in tier 2, auth token files never eligible; the `xet` transfer cache is tier 1 in full. PyTorch (`hub`, TorchInductor via the closed `["hub", "inductor"]` list), MLX, and Whisper join tier 1 as `unusedOnly`; Triton's compiled-kernel cache (`~/.triton/cache`) is tier 1 in full.
- **Go & polyglot package stores:** tier 1 clears `~/go/pkg/mod/cache` (the module download cache); tier 2 additionally takes every extracted module tree under `~/go/pkg/mod` (read-only files remove to Trash via their writable parent). pnpm's three store layouts, NuGet's global packages, and the Dart pub cache are tier-2-only. Maven's `~/.m2/repository` stays scan-only with no rule — its local contains user-built artifacts.
- **Container runtimes:** OrbStack, Colima, Lima, and Podman (`~/.local/share/containers`) join the Dev tools scope and known-location explanations as scan-explain-only, matching the Docker/Parallels/UTM precedent — VM disks are real container data, never auto-selected in either tier.
- Known-location hover cards gained 14 explanation entries for the new stores; 29 new strings exist in both catalogs (367 entries).
- Tests: core 58 pass — `phaseBStoreRulesMatchTheTierSets` pins both tiers for every new rule, including the token/chat/preset/preserved-user-export exclusion guardrails and Maven's never-selected assertion. Hosted app tests 63 pass with the extended Dev-tools root assertions. Universal Release build passes; localization audit validates 367 entries.

## Phase A coverage expansion — Cargo/Bun/Gradle, browser builds, editors, Adobe media cache — 2026-11-02

The first phase of the `Documentation/PLANS/CacheAndRebuildableExpansion.md` roadmap shipped, widening the curated cache catalog:

- **Xcode simulator-side throwaways:** `CoreSimulator/Caches` (runtime caches), `Xcode/UserData/Previews/Simulator Devices`, and `XCTestDevices` are now curated children candidates (tier 1 selects them in full); `watchOS`/`tvOS`/`visionOS DeviceSupport` join iOS device support with `childrenKeepingNewest` (one version kept) and group under Dev tools.
- **Package caches:** Rust's four Cargo sub-caches (`registry/cache`, `registry/src`, `git/checkouts`, `git/db`) and bun's global package cache are `rootItself` tier-1 candidates; `~/.cargo/bin` and `~/.bun/bin` (user executables) are never listed. Gradle wrapper distributions (`~/.gradle/wrapper/dists`) keep the newest.
- **Automation-browser builds:** `ms-playwright` uses a new `Tier1Coverage.previousVersionsPerFamily(keep: 1)` — the newest build of each browser family (`chromium-1148` → family `chromium`) is preserved and every old build per family is selected, instead of a flat keep-newest that would delete whole browser families; Cypress uses plain `previousVersions(keep: 1)`. Both group under Dev tools, never auto-selected from a map scene. **Puppeteer is deliberately deferred** (two-level `\<browser>/\<platform-version>` layout does not fit the one-level rule model) and documented in the plan.
- **Editor caches:** `Cache`, `CachedData`, `CachedExtensionVSIXs`, and `GPUCache` inside `~/Library/Application Support/{Code, Code - Insiders, Cursor, Windsurf}` are curated `rootItself` caches; user settings/workspace trees stay protected by managed-data rules, and running editors (VS Code, Insiders (`com.microsoft.VSCodeInsiders`), Cursor (`com.todesktop.230313mzl4w4u92`), Windsurf (`com.exafunction.windsurf`)) have their cache paths blocked through segmented bundle-ID ownership matching.
- **Adobe media cache:** `Application Support/Adobe/Common/Media Cache Files` and `.../Media Cache` became the exact managed-data exemptions for Premiere Pro, After Effects, Media Encoder, and Audition's shared cache — removal is refused by the app-activity guard while any of those apps runs (Media Encoder also runs as a background export queue, caught via `com.adobe.mediaencoder` prefix ownership).
- Known-location hover cards gained explanations for every new location family (Cargo, bun, Gradle distributions, Playwright/Cypress, simulator caches/preview/test devices, editor caches, Adobe media caches); all 50 new strings exist in English and Russian (catalog at 339 entries).
- Tests: core 57 pass — new `versionedFamiliesGroupPerBuildLine`, `browserFamiliesKeepOneVersionEachAndSoleBuildsStay`, and an index-level `phaseALocationsMatchTheTierSets` pinning tier 1/tier 2 sets for every new location plus the never-selected `Code/User` guardrail. Hosted app tests 63 pass with extended quick-target root assertions and two new guard tests (`ownershipMatchesStructureNotPrefixText` boundary matching, `appOwnedMarkersResolveInsideTheCuratedRule` marker/rule drift guard). Universal Release build passes; localization audit validates 339 entries.

## Chooser quick actions: map-like mosaic, no collapsible developer section — 2026-11-02

The chooser's Quick actions area no longer uses mixed-size pill rows. It now renders a deliberate mosaic built on two full-height columns — sizes follow each action's weight, echoing the treemap the app produces after a scan: "Home folder" is the hero tile with the teal accent wash and its detail text inline, "All caches" and "Dev tools" (the two grouped "everything" scans) are equal-height wide tiles showing their location count, and "Downloads"/"User caches" fill a short bottom row whose column edges align exactly with the top's (Home == Downloads width, User caches == All caches width). Every tile uses the same sizes — an 18 pt symbol and a uniform `.title3` semibold label (larger than the previous callout labels), the longest localized titles falling back to a gentle scale factor instead of wrapping — and heights scale along one `ScaledMetric` with container-proportional widths.

The collapsible "Developer caches" section is removed entirely: "Dev tools" moved into the main quick-action list, and the four individual developer-cache targets (Xcode Derived Data, SwiftPM, npm, pip) are dropped because "All caches" already covers exactly those locations. `ScanTarget` lost its unused `developer` flag and `LocationSelectionViewModel` lost `commonTargets`/`developerTargets`/`showDeveloper`.

- Test changes: `MapFirstFlowTests.quickTargetsUseSuppliedRealHomeAndDropsRejectFiles` now asserts the exact quick-action catalog order `["home", "downloads", "caches", "allCaches", "devTools"]` instead of the removed `xcode` target. The four dev-location titles stay in the localization catalog — they still feed cleanup-rule presentations and known-location descriptions ("Developer caches" is the one removed key; the audit validates 291 entries).
- Hosted app tests, core tests, the universal Release build (`generic/platform=macOS`), and the localization audit pass.

## Auto-selection corrections — keep-newest preserved, LM Studio user data protected — 2026-11-02

- **Keep-newest correction (reported bug):** "Select safe items" selected even the **sole remaining** version in `~/Library/Android/sdk/system-images`, `~/Library/Android/sdk/ndk`, and — by the same mechanism — `~/Library/Developer/CoreSimulator/Devices` and `~/Library/Developer/Xcode/iOS DeviceSupport`. The `previousVersions` long-unused fallback selected every long-unused child including the newest one; the fallback now drops the single most recent version first, so a sole remaining version always survives tier 1 (tier 2 selecting all versions is unchanged and correct). Empirically pinned against the reported one-version-each layout: the AVD rule (`unusedKeepingNewest`) already preserved its sole version — it never appeared in the tier-1 candidates; a regression test now guards all five locations.
- **LM Studio store review:** `~/.cache/lm-studio` holds user-authored content beside caches — `chats`, `conversations` (chat history), `config-presets` (including user presets), `downloads.json`, and the `lms` CLI — none of which can be regenerated or restored. They are therefore **not** safe junk and **not** rebuildable: a closed `AutoSelectionRule.eligibleChildNames` list restricts both tiers to the known regenerable children (`models`, `extensions`, `.internal`, `.session_cache`), so user content is never selected and unknown future children stay out until added deliberately.
- Regression coverage: pure-tier tests pin the preserved sole version for both keep-newest shapes and `unusedKeepingNewest`; two new index-level tests reproduce the reported one-version machine (tier 1 selects nothing, tier 2 all) and the LM Studio split (tier 1: long-unused regenerable children; tier 2: all regenerable children; user content absent from both). The old core fixture's sole-long-unused-version expectation that encoded the bug was corrected.
- Core tests: 54 pass (two new, one corrected). Hosted app tests: 60 pass unchanged. Universal Release build (`generic/platform=macOS`) passes; no localization changes (292 catalog entries).

## Selection-panel context menu and clear-selection button — 2026-11-02

The selection panel's rows gained the map's context menu (Focus folder, Rescan folder, Quick Look, Reveal in Finder, Copy path, and Select/Deselect mirroring the row's checkbox), and a small header button clears the whole selection at once — manual and recommended picks alike — while the last operation's report stays (`CleanupViewModel.clearSelection` also forgets the recommendation memory, so the next quick-select starts fresh).

- Regression coverage: one hosted test covers `clearSelection` semantics (empties everything, forgets the recommendation, keeps the report).
- Hosted app tests: 61 pass (one new). Universal Release build and `build-for-testing` pass. No new localization keys (context-menu labels and "Clear selection" already exist); the audit validates 292 entries against the build's extracted stringsdata. Environment note: one hosted test run used a stale test bundle because the incremental build considered a modified test file up to date; clearing the test target's intermediates rebuilt it and the suite was re-verified from the fresh bundle.

## Cleanup-queue duplication fix — 2026-11-02

Fixed duplicated rows in the cleanup-queue panel: checking a nested item's checkbox could make a copy of its container appear at the bottom of the list. Mechanism: the panel renders the open folder's listing plus a selected-items tree "elsewhere", and the second section's filter used lexical containment (`node.path.isWithin(current.path)`) to skip everything the listing already shows. After a grouped quick action ("All caches"/"Dev tools") the open folder is the synthetic `diskunbloat:scan-group` wrapper, and real paths are never lexically "within" that synthetic path — so every container with a nested selection passed the filter and was rendered again at the bottom (each row duplicated, with colliding `ForEach` identities keyed by node id, which is the "data duplication" seen in the UI). The filter now treats the wrapper as the ancestor of the whole scan, so a row is rendered exactly once.

- **Same class, two more fixes:** the map-selection mirror (`CleanupQueueModel.revealForSelection`) used the same lexical guard and silently did nothing at the wrapper view; it now admits every node under a group-root folder. Covered containers (all children queued) had no chevron at all, so mirrored selections could never reach their entries — covered rows are now collapsed-by-default but expandable (`CleanupQueueModel.coveredExpanded`), and the mirror's chain reveal opens collapsed folders and covered containers on the way to the target row.
- Regression coverage (three new hosted tests): the wrapper-view nested-selection fixture asserts the exact line list and that no identity renders twice (it reproduces `[…, "item-1", "item-2", "item-3", "more-2", "item-5", "item-1", "item-2", "item-3", "more-2"]` without the fix — verified red before the fix, green after); covered-container expansion renders its entries only when expanded; and the model-level mirror test reaches a covered entry through the wrapper view.
- Hosted app tests: 60 pass. Core tests: 52 pass. Universal Release build (`generic/platform=macOS`) and `build-for-testing` pass. Localization unchanged (no new strings); the audit validates 292 entries.

## Two-tier automatic selection — 2026-11-02

The cleanup-queue panel gained two quick-select buttons. **Select safe items** (tier 1: junk and caches that are safe to delete) selects Xcode Derived Data and known regenerable caches in full, previous iOS device-support versions (keeping the newest), previous simulators (keeping the two newest), previous Android system-images/NDK (keeping the newest), long-unused Android virtual devices (never the newest; each `.avd` folder carries its `.ini` sidecar), and long-unused LM Studio models — never the live `~/Library/Caches` tree. **Select rebuildable items** (tier 2) covers those locations in full, adds all of `~/Library/Caches`, and adds the name-matched rebuildable folders (node_modules, Pods, .build, …); clicking it first shows a warning with an honest item/size estimate ("Select anyway"/"Cancel"). Per the requested "older versions" semantics, the keep-newest locations select their previous versions when any exist and fall back to the long-unused ones when they do not. The rules are one closed path-based list (`Suggestions/AutoSelection.swift`, cache side derived from `CleanupRule.userCaches`) applied within the scanned scope, so the "Dev tools"/"All caches" behavior is a scope intersection, not a per-group branch; a Home scan gets the union, and scans without curated locations report "Nothing recommended in this scan."

- **Core:** `ScanIndex+AutoSelection` materializes tier candidates per curated location (children eligible only when complete and outside package internals; unknown dates/sizes never establish long-unused eligibility) and collapses fully queued containers to one descendants-only hidden range (`coalescedHiddenRanges` + `FileQuery.hiddenSubtrees`, so a bulk selection costs a handful of map-query terms and the kept folder stays visible). Tier decisions are pure (`AutoSelection.select`): recency is the subtree's latest recorded content modification with a name tie-break, never access dates. `ScanOptions.longUnusedDays` (default 90) defines "long-unused".
- **App:** `CleanupViewModel.applyAutoSelection` runs the same `CleanupSafety`/running-application checks as manual selection in one bulk pass (refusals counted, never forced), normalizes once, collapses a fully covered scan root to one "clean contents, keep folder" entry, and replaces the previous recommendation while keeping manual picks (re-clicking re-applies cleanly). `WorkspaceViewModel.previewSelection`/`selectItems` orchestrate; `CleanupQueueView` hosts the buttons and the tier-2 warning; `CleanupQueueTree` gained atomic kept-folder rows for fully queued containers and prefix-sum selected-bytes (the per-row scan over all entries is gone). The threshold stepper lives in `ScanOptionsView`, persists in UserDefaults, and is consumed at selection time — changing it never forces a rescan.
- **Localization:** 13 new English/Russian keys (including two plurals with full Russian one/few/many/other forms: "%lld items were skipped by safety checks." and "Not modified in %lld days"); `Tools/audit-localization.py` validates 292 entries. The keys were inserted in Xcode's `localizedStandardCompare` order — verified by sorting the previous 279 keys with Foundation's own comparator and matching the file order exactly — and all pre-existing entries are byte-identical (diff is insertion-only).
- Core tests: 52 pass — nine new (keep-newest tiers with the long-unused fallback, keep-two simulators, unused-only/keeping-newest guards, unknown-data exclusion, AVD sidecar pairing, user-caches tier split, Dev tools and All caches scope conformance, name-matched tier placement, hidden-range collapse). Hosted app tests: 57 pass — seven new (recommendation replaces previous and keeps manual picks with clean re-apply, counted refusals, covered scan root → one emptied entry, 2 000-item bulk normalization, atomic covered rows, empty-recommendation notice, threshold persistence).
- Pre-existing failure fixed outside the feature's scope: `AuthorizationTests.bookmarkFailureDoesNotRejectPickerSelection` failed on unmodified HEAD in this environment because `AuthorizationStore.retainOnly` compared realpath-canonicalized scan roots against un-canonicalized grants (`/var` vs `/private/var` aliases), releasing the picker grant immediately — in real use that would strip a scan's only access. Both sides now canonicalize; the test passes. The `NSAnimationContext` completion-handler Sendable warning in `WorkspaceView.setWindowContentSize` predates this batch and was left unchanged.
- Universal Release build (`generic/platform=macOS`) and `build-for-testing` (UI bundle included) pass. The automated UI suite was not executed (desktop-automation limitation below); no new UI tests were added — the warning flow is covered at the model level.

## Selection sync and larger expansion targets — 2026-11-02

Two selection-panel refinements: the expand/collapse chevron grew from a 12 × 12 to a 20 × 20 hit target (glyph 10 pt), and map selection and panel rows now mirror each other. Tapping a panel row highlights the same tile on the map (`ExplorerViewModel.select`); a map selection highlights the matching panel row with an accent tint and scrolls it into view, lazily expanding the folder chain first — folders page until the target child is visible (`CleanupQueueModel.revealForSelection`), and the chain stops at packages/symlinks, which stay atomic. The highlight is the explorer's selection and stays independent of the queue checkboxes. No new localization keys; no project-file changes.

- Hosted app tests: 50 pass — one new: revealing a selection pages a folder until the fifth-largest child is visible, marks it peeked, and ignores items outside the open folder.
- Core tests: 43 pass; universal Release build and `build-for-testing` (UI bundle included) pass; localization audit unchanged at 279 entries. The automated UI suite was not executed (desktop-automation limitation below).

## Container peek expansion — 2026-11-01

Follow-up to the selection panel: unselected containers previously had no expansion control. Plain folders (not packages, not symbolic links) now show a chevron; expanding one lazily fetches its **three largest direct children** (known size descending) and, when more exist, a `Show more items` row that pages the rest. Peek state is local to `CleanupQueueModel`, keyed per folder, invalidated on session/branch refresh, and reused recursively for nested folders. No new localization keys; no project-file changes.

- Hosted app tests: 49 pass — three new: unselected containers expose the chevron without nested rows, a pure-tree peek shows the three largest then paging, and the model-level flow (expand → three largest → Show more pages the rest → collapse).
- Core tests: 43 pass; universal Release build and `build-for-testing` (UI bundle included) pass; the localization audit validates 279 entries unchanged. The automated UI suite was not executed (desktop-automation limitation below).

## Selection-panel refinements — 2026-11-01

Follow-up to the cleanup-queue panel: the panel title and command became "Select items to delete" ("Выберите объекты для удаления"), and the panel now always lists the currently open folder's direct children ordered by known size descending — even with an empty queue — so items can be selected directly from the panel. The listing pages with an honest total (`Show more items`); a selected direct child shows checked in the listing, and an entry selected below the listing nests under its folder's row instead of appearing twice. The selected-items tree for entries elsewhere in the scan keeps its behavior and now sorts each level by known size descending.

- **Core:** `ScanIndex.children(of:…sortByName:)` orders by name or by known allocated size descending.
- **Model:** `CleanupQueueProviding.children` carries the sort; `CleanupQueueModel.refresh(current:)` owns the open-folder cache, invalidates it on navigation and branch refresh, and the pure `CleanupQueueTree` gained a `directoryHeader` line type plus the current-folder section.
- **Localization:** two keys added ("Select items to delete" and its toolbar-help variant), the three retired "Cleanup queue" keys removed; audit validates 279 entries in canonical `localizedStandardCompare` order. The refresh-message source key now matches its catalog entry ("…from the cleanup queue…").
- Hosted app tests: 46 pass — four new (size-descending listing with an empty queue, checked state inside the listing, deep selections nesting under their folder's row, pagination with an honest count) plus the model-level listing/pagination/reveal flow. Core tests: 43 pass. Universal Release build, `build-for-testing` (UI bundle included), and the localization audit pass; the automated UI suite was not executed (desktop-automation limitation below).

## Map-only explorer and cleanup-queue panel — 2026-11-01

Redesign batch: the right details panel and the bottom file browser (with its Files/Largest/Types/Candidates tabs) were removed; the deletion queue became a right-hand panel of selected items that opens automatically after a completed scan; curated object descriptions moved into the map hover card; the context-menu action "Add to deletion queue" became "Select".

- **Queue panel:** `CleanupQueueModel` derives a compact tree from normalized `CleanupEntry` values only — fully selected folders are atomic checkbox rows ("Keeps folder" for `.emptyContents` scan roots), partially selected folders expand with selected children first and unselected siblings behind a `… N more items` control that lazily fetches direct children in name-ordered pages (`ScanIndex.children(of:)`/`childCount(of:)`, injected through `CleanupQueueProviding`). Tri-state checkboxes: checked unchecks, partial selects the whole folder, unchecked selects; `CleanupViewModel.deselect` removes every overlapping entry. Totals use `knownSize(for: .allocated)` on normalized entries — the same accounting the map subtracts — labeled estimated, with an explicit unknown-sizes note. `Delete Selected` opens the revised confirmation (Trash first; permanent deletion behind the separate strong confirmation); a successful run returns to the chooser and presents `CleanupReportView`. The queue auto-opens only for completed scans (never for cancelled/failed ones), survives focused refresh with its open/closed state, and is cleared and re-attached per scan session. The synthetic group wrapper never becomes a row.
- **Explorer:** `ExplorerViewModel`/`ExplorerQueries` shrank to map-scene + legend work (`mapSnapshot` replaces `explorerSnapshot`; browser paging, drawer tabs, candidate exclusions, and sort state are gone). The map context menu shows "Select"/"Deselect"; curated `KnownLocation` explanations appear only in the hover card via `description(for:)`.
- **Localization:** 26 new English/Russian keys (including the "%lld items processed" plural with full Russian forms) and 73 keys orphaned by the retired surfaces removed; `Tools/audit-localization.py` validates 280 entries and the file keeps Xcode's `localizedStandardCompare` key order (verified by script) and byte-identical formatting. The refresh message key mismatch ("cleanup review" source vs "deletion queue" catalog entry) was fixed while renaming the terminology.
- `swift test --package-path Packages/DiskCore`: 43 tests pass — one new for the paged `children(of:)`/`childCount(of:)` queue helpers.
- Hosted app tests: 42 pass — ten new in `CleanupQueueTests` (atomic folder row, selected-first partial expansion with hidden siblings, revealed-sibling paging, collapsed folders, synthetic-wrapper skipping, normalized totals, membership classification, model gather/lazy reveal, deselect overlap removal) plus selection persistence and hover-description coverage; browser-pagination and candidate-exclusion tests were retired with their features; queue auto-open and cancelled-scan behavior are asserted in `MapFirstFlowTests`. Universal Release build (`generic/platform=macOS`, `CODE_SIGNING_ALLOWED=NO`) and `build-for-testing` (including the UI test bundle, with a new no-queue-at-launch assertion) pass. The automated UI suite was not executed (desktop-automation limitation below). The `NSAnimationContext` completion-handler Sendable warning in `WorkspaceView.setWindowContentSize` predates this batch and was left unchanged.

## Scan-root clean-contents queueing — 2026-11-01

Scan-root folders — every listed location of the grouped "All caches"/"Dev tools" targets and the root of any single-root scan — can now join the deletion queue as a "clean contents, keep folder" entry instead of being refused. At execution the folder's current direct children are removed with the chosen mode (Trash or permanent, never mixed) while the folder itself stays.

- **Core:** `CleanupOperation` (`.remove`/`.emptyContents`) and `CleanupEntry` give each basket entry its own operation; `CleanupPlan` normalization subsumes anything queued inside a kept entry and prefers removal for duplicate paths. `CleanupSafety.emptyContentsBlockedReasonCode` qualifies only exact scan-root directories — `/`, volume roots, non-folders, outside-scope paths, and managed/system/package trees stay refused (curated cache roots remain exempt via `knownCacheRoots`). `CleanupService` validates the folder (safety, ancestor identities, identity/fingerprint, write access), then removes children one at a time on the cleanup queue; mounted-volume children are never swept, failures leave the child in place, and the folder is never deleted. The plan preflight is now path-based and rechecked before every child removal.
- **App:** `CleanupViewModel.add` upgrades an exact scan root to `.emptyContents` (reporting the specific protection — managed data, system tree, volume root — when emptying is also blocked); the review sheet labels such rows "Cleans contents · keeps folder"; the inspector offers "Clean contents (keep folder)" instead of the lock label for emptyable roots. Running-application caches among a root's contents no longer block queueing the root (each child is rechecked at execution time), while a root that is itself an active cache stays refused. Queued roots hide their subtree from map/browser/statistics like any other entry.
- **Localization:** six new English/Russian keys; `Tools/audit-localization.py` validates 327 entries and the file keeps Xcode's `localizedStandardCompare` key order (verified by script).
- `swift test --package-path Packages/DiskCore`: 42 tests pass — five new: mixed-operation plan normalization, the empty-contents safety matrix (grouped roots, `/`, non-folders, managed/system trees, curated exemption), a real fixture emptied with the folder kept, changed-folder refusal, and per-child preflight recheck during emptying.
- Hosted app tests: 34 pass — two new: scan roots queue as clean contents and reach the plan as `.emptyContents`, and active-cache contents guard themselves while root cleaning stays queued. Universal Release build (`generic/platform=macOS`, `CODE_SIGNING_ALLOWED=NO`) and test-bundle compilation (including the UI target) pass. The automated UI suite was not executed (desktop-automation limitation below).

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

## Bug fixes: post-cleanup navigation and queued-item container sizes — 2026-11-01

- **After deleting, return to the start screen:** `WorkspaceViewModel.performCleanup` now navigates to the location chooser (`phase = .choosing`), resets the stale explorer, and discards the stale index instead of re-scanning. The deletion report is preserved.
- **Queued items shrink their containers:** `MapScene.mapScene` now computes each tile's *visible* size (its aggregate minus queued subtrees), so a container shrinks when a nested item is added to the deletion queue and the map total excludes queued bytes. Folder tiles previously used the stored aggregate, which still counted queued (hidden) descendants — so a container stayed large after its only big file was queued.

Regression tests: `hiddenPathsShrinkContainerSizes` (core) and `performCleanupReturnsToStartScreenInsteadOfRescanning` (hosted — it queues the item directly because the sandboxed fixture lives under the managed container tree). All 37 core tests, 32 hosted tests, the universal Release build, test compilation, and `Tools/audit-localization.py` (323 entries) pass.

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
