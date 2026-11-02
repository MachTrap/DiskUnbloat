# Cache, Garbage & Rebuildable Component Expansion Catalog

Research & prioritized backlog for expanding DiskUnbloat's curated cache locations, grouped quick-scan roots (`All caches` / `Dev tools`), project-local rebuildable directory patterns (`CleanupRule.regenerableNames`), hover-card explanations (`KnownLocation`), and two-tier automatic selection (`AutoSelectionSpec`).

---

## How Items Map to DiskUnbloat's Architecture

Every candidate in this catalog is classified along four axes that already exist in `DiskCore` and the app layer:

1. **Where it hooks in:**
   - **`userCaches` root (`CleanupRule.userCaches`):** Included in the **All caches** quick scan, exempted from `CleanupSafety.isManagedData` if inside `~/Library/Application Support`, `~/Library/Containers`, or `~/Library/Group Containers`, and surfaced by the Caches filter.
   - **`devToolRoots` (`LocationCatalog`):** Included in the **Dev tools** quick scan.
   - **`regenerableNames` / `regenerableNamePrefixes` (`CleanupRule`):** Matched by folder name anywhere inside a scanned tree (e.g., project-local build/dependency directories).
   - **`KnownLocation` (`LocationCatalog`):** Gives the map hover card a plain-language title and explanation when hovering the folder.
2. **Auto-Selection Tier (`AutoSelectionSpec`):**
   - **Tier 1 (`safe`):** Pure download/build/shader caches or superseded versions (`previousVersions(keep:)` / `unusedOnly` / `all`) where deletion loses zero user state and rebuilds silently.
   - **Tier 2 (`regenerable`):** Larger stores that can be re-downloaded or rebuilt (full model weights, active package stores, project-local dependency trees) and are gated behind the extensive-cleanup warning.
   - **Scan & Explain Only (No Auto-Select):** Locations that hold high-value artifacts alongside bloat (e.g., VM disks, Xcode `.xcarchive` release builds, Docker volumes) where DiskUnbloat should scan, visualize, and explain the folder on hover, but leave selection strictly manual.
3. **Managed-Data Safety (`CleanupSafety`):**
   - Anything under `~/Library/Application Support`, `~/Library/Containers` (outside `/Data/Library/Caches`), or `~/Library/Group Containers` is blocked by default unless its exact cache subpath is added to `CleanupRule.userCaches` (which travels on `CleanupPlan.exemptCacheRoots`).
   - Mixed directories (like `~/.cargo`, `~/.lmstudio`, `~/.claude`) **must** either target only the cache subdirectory or carry a closed `eligibleChildNames` allowlist so user binaries, configs, and chat transcripts are never touched.

---

## Priority 0 — Highest-Yield Missing Developer & Package Caches (5–100+ GB each)

These are ubiquitous on macOS developer machines, routinely consume tens of gigabytes outside `~/Library/Caches`, and have unambiguous regeneration behavior.

### 1. Rust Cargo Registry & Git Checkouts
- **Paths:**
  - `~/.cargo/registry/cache` (compressed `.crate` archives)
  - `~/.cargo/registry/src` (unpacked crate source trees)
  - `~/.cargo/git/db` and `~/.cargo/git/checkouts` (git dependency clones)
- **Typical Footprint:** 3–25 GB
- **Integration:** `userCaches` + `devToolRoots` + `KnownLocation`
- **Auto-Selection:** **Tier 1 (`safe` — `.all`)** on `registry/cache`, `registry/src`, `git/checkouts`, and `git/db`.
- **Explanation & Safety Note:** Cargo downloads and unpacks every crate version ever compiled into `~/.cargo/registry` and never expires them automatically. Removing `cache`, `src`, and `git` is completely safe; Cargo re-downloads needed crates on the next `cargo build`. **Critical safety boundary:** Never target `~/.cargo` as a whole or `~/.cargo/bin`, because `~/.cargo/bin` contains user-installed CLI binaries (`cargo install`) and `rustup` shims. Either list the four exact subdirectories or use `eligibleChildNames: ["registry", "git"]`.

### 2. Go Module Cache (`GOMODCACHE`)
- **Paths:**
  - `~/go/pkg/mod/cache` (downloaded module zips and metadata)
  - `~/go/pkg/mod` (extracted module versions; note: Go marks extracted module files read-only `0444`)
  - *(Note: Go's build cache at `~/Library/Caches/go-build` is already inside `~/Library/Caches`, so adding a `KnownLocation` hover description for it is a free win.)*
- **Typical Footprint:** 2–20 GB
- **Integration:** `devToolRoots` + `KnownLocation`
- **Auto-Selection:**
  - `~/go/pkg/mod/cache/download`: **Tier 1 (`safe` — `.all`)**
  - `~/go/pkg/mod`: **Tier 2 (`regenerable`)** (Note: extracted directories in `~/go/pkg/mod` have read-only permissions by default; `FileManager.removeItem` / Trash handles user-owned read-only dirs on macOS or may need write-bit restoration if permanently deleted.)
- **Explanation:** Go caches every downloaded module version under `~/go/pkg/mod` and compiled object files under `~/Library/Caches/go-build` (often 5–15 GB on its own). Both are 100% reproducible via `go mod download` / `go build`.

### 3. pnpm Content-Addressable Store
- **Paths:**
  - `~/Library/pnpm/store` (macOS default for pnpm v7+)
  - `~/.local/share/pnpm/store` (XDG fallback used by some setups)
  - `~/.pnpm-store` (legacy v6 path)
- **Typical Footprint:** 5–40 GB
- **Integration:** `userCaches` + `devToolRoots` + `KnownLocation`
- **Auto-Selection:** **Tier 2 (`regenerable`)** (or **Tier 1 (`unusedOnly`)** if unreferenced/old, Tier 2 in full).
- **Explanation:** pnpm hard-links packages from a central content-addressable store into project `node_modules` folders. Because hard links keep the underlying inodes alive for active projects on the same APFS volume, deleting the central store entries only frees space for orphaned packages (or breaks store integrity only in the sense that future `pnpm install` runs re-fetch missing tarballs). Putting it in Tier 2 behind the rebuildable warning matches its role.

### 4. Bun & Deno Package Caches
- **Paths:**
  - `~/.bun/install/cache` (Bun global package cache)
  - `~/Library/Caches/deno` and `~/.deno/cache` (Deno fetched modules, TypeScript compile cache)
- **Typical Footprint:** 1–15 GB
- **Integration:** `userCaches` + `devToolRoots` + `KnownLocation`
- **Auto-Selection:** **Tier 1 (`safe` — `.all`)** for `~/.bun/install/cache` (never `~/.bun/bin`!).
- **Explanation:** Bun stores unpacked npm package versions in `~/.bun/install/cache` while keeping global binaries in `~/.bun/bin`. Targeting `~/.bun/install/cache` directly is completely safe and re-populates on the next `bun install`.

### 5. Xcode SwiftUI Previews, CoreSimulator Caches & XCTestDevices
- **Paths:**
  - `~/Library/Developer/Xcode/UserData/Previews/Simulator Devices` (SwiftUI preview simulator instances)
  - `~/Library/Developer/CoreSimulator/Caches` (dyld shared cache builds & runtime caches — often 5–25 GB!)
  - `~/Library/Developer/XCTestDevices` (ephemeral cloned simulator devices created by parallel `xcodebuild test` runs)
  - `~/Library/Developer/Xcode/watchOS DeviceSupport`, `tvOS DeviceSupport`, `visionOS DeviceSupport` (siblings to `iOS DeviceSupport`)
- **Typical Footprint:** 10–60 GB combined
- **Integration:** `userCaches` + `devToolRoots` + `KnownLocation` + `AutoSelectionSpec`
- **Auto-Selection:**
  - `CoreSimulator/Caches`, `UserData/Previews/Simulator Devices`, and `XCTestDevices`: **Tier 1 (`safe` — `.all`)** (recreated automatically by Xcode/Simulator on next preview or test run).
  - `watchOS DeviceSupport`, `tvOS DeviceSupport`, `visionOS DeviceSupport`: **Tier 1 (`previousVersions(keep: 1)`)**, Tier 2 (`all`) — identical to `iOS DeviceSupport`.
- **Explanation:** Right now DiskUnbloat covers `DerivedData`, `iOS DeviceSupport`, and `CoreSimulator/Devices`, but misses the three other massive Xcode folders: `CoreSimulator/Caches` (dyld caches that routinely balloon to 15+ GB), `UserData/Previews` (separate simulator containers just for SwiftUI Canvas), and `XCTestDevices` (leftover test clone devices). All three are purely transient.

### 6. Java / JVM: Maven (`.m2`), SBT, Ivy & Gradle Wrapper
- **Paths:**
  - `~/.m2/repository` (Maven local artifact repository)
  - `~/.gradle/wrapper/dists` (downloaded Gradle distribution zips & unpacked runtimes)
  - `~/.ivy2/cache` and `~/.sbt` (Scala SBT / Ivy caches)
  - `~/Library/Caches/Coursier` (Scala Coursier artifact cache)
- **Typical Footprint:** 3–30 GB
- **Integration:** `userCaches` (`~/.gradle/wrapper/dists`, `~/.ivy2/cache`) + `devToolRoots` (`~/.m2/repository`) + `KnownLocation`
- **Auto-Selection:**
  - `~/.gradle/wrapper/dists`: **Tier 1 (`previousVersions(keep: 1)`)**, Tier 2 (`all`) — projects download every historical Gradle version ever opened; keeping the newest and purging old dists saves gigabytes.
  - `~/.ivy2/cache`: **Tier 1 (`safe` — `.all`)**.
  - `~/.m2/repository`: **Tier 2 (`regenerable`)** (not Tier 1, because developers occasionally run `mvn install` for local unpublished snapshots, which can be rebuilt from local source).
- **Explanation:** DiskUnbloat currently includes `~/.gradle/caches`, but `~/.gradle/wrapper/dists` (often 2–8 GB of old Gradle versions) and `~/.m2/repository` (often 5–25 GB of JARs) sit right next to it and are untouched.

### 7. Python Ecosystem Beyond `pip` and `uv` (Conda, Poetry, PDM, Pipenv)
- **Paths:**
  - `~/.conda/pkgs`, `~/miniconda3/pkgs`, `~/anaconda3/pkgs`, `~/miniforge3/pkgs`, `/opt/homebrew/Caskroom/miniconda/base/pkgs` (Conda downloaded tarballs & hard-linked package cache)
  - `~/Library/Caches/pypoetry` and `~/.cache/pypoetry` (Poetry cache & wheel artifacts)
  - `~/Library/Caches/pdm` and `~/.cache/pdm` (PDM package cache)
  - `~/Library/Caches/pipenv` (Pipenv wheel/download cache)
- **Typical Footprint:** 3–35 GB (Conda `pkgs` alone is routinely 10–30 GB)
- **Integration:** `userCaches` + `devToolRoots` + `KnownLocation`
- **Auto-Selection:**
  - `pypoetry`, `pdm`, `pipenv` caches: **Tier 1 (`safe` — `.all`)**
  - Conda `pkgs/cache` or unused tarballs: **Tier 2 (`regenerable`)** on `pkgs` (since Conda hard-links active environments into `pkgs`, deleting `pkgs` reclaims unlinked packages while active envs keep their files via APFS links, though `conda` metadata prefers `conda clean --all`).

---

## Priority 1 — AI, Machine Learning & LLM Tooling (10–250+ GB)

Local AI/ML workflows are the fastest-growing disk consumer on Apple Silicon Macs (unified memory makes running 7B–70B models and diffusion pipelines common).

### 8. Modern LM Studio Store (`~/.lmstudio`)
- **Paths:**
  - `~/.lmstudio` (newer LM Studio versions moved from `~/.cache/lm-studio` to `~/.lmstudio`)
  - Eligible regenerable children: `~/.lmstudio/models`, `~/.lmstudio/hub`, `~/.lmstudio/.internal`
- **Typical Footprint:** 10–150 GB
- **Integration:** `devToolRoots` + `KnownLocation` + `AutoSelectionSpec`
- **Auto-Selection:**
  - **Tier 1 (`safe` — `.unusedOnly`)** with `eligibleChildNames: ["models", "hub", ".internal"]`
  - **Tier 2 (`regenerable`)** with the same closed `eligibleChildNames` list.
- **Explanation & Safety Note:** Recent LM Studio releases store models and runtime engines in `~/.lmstudio` alongside `conversations`, `config-presets`, `credentials`, and `extensions`. Just like we did for `~/.cache/lm-studio`, adding `~/.lmstudio` with a strict `eligibleChildNames` allowlist covers modern LM Studio installs while protecting user chats and presets.

### 9. Hugging Face Hub & Datasets Cache (`~/.cache/huggingface`)
- **Paths:**
  - `~/.cache/huggingface/hub` (downloaded model weights, `models--*` folders)
  - `~/.cache/huggingface/datasets` (downloaded & Arrow-processed datasets)
  - `~/.cache/huggingface/xet` (Xet chunk transfer cache)
- **Typical Footprint:** 10–200 GB
- **Integration:** Already in `devToolRoots` and `KnownLocation`; **missing from `AutoSelectionSpec`!**
- **Auto-Selection:**
  - `~/.cache/huggingface/xet`: **Tier 1 (`safe` — `.all`)** (pure transfer chunk cache).
  - `~/.cache/huggingface/hub` and `datasets` children: **Tier 1 (`safe` — `.unusedOnly`)**, **Tier 2 (`regenerable` — all)** (never touch `~/.cache/huggingface/token` or `stored_tokens`!).
- **Explanation:** DiskUnbloat already scans `~/.cache/huggingface` in **Dev tools**, but `AutoSelectionSpec` currently has no rule for it. Targeting `hub`, `datasets`, and `xet` while excluding the auth token file makes long-unused Hugging Face models/datasets selectable in Tier 1 and all of them in Tier 2.

### 10. Ollama Model Blobs (`~/.ollama/models`)
- **Paths:**
  - `~/.ollama/models`
- **Typical Footprint:** 5–150 GB
- **Integration:** Already in `devToolRoots` and `KnownLocation`; candidate for **Tier 2 (`regenerable`)** or **Scan & Explain Only**.
- **Auto-Selection:** **Tier 2 (`regenerable`)** on `~/.ollama/models` (never `~/.ollama` root, because `~/.ollama/id_ed25519` is the user's Ollama keypair!).
- **Explanation:** Ollama stores manifests in `~/.ollama/models/manifests` and content-addressed layer blobs in `~/.ollama/models/blobs`. Because multiple models can share base blobs, per-model age selection in the filesystem is unsafe (deleting one blob can break another model), whereas selecting `~/.ollama/models` as a whole in **Tier 2 (`regenerable`)** (or keeping it manual) cleanly resets the model store while preserving `~/.ollama/id_ed25519`.

### 11. PyTorch, TorchInductor, Triton, MLX & Whisper Caches
- **Paths:**
  - `~/.cache/torch` (PyTorch Hub models, `hub/checkpoints`, TorchInductor C++/Metal compiled kernels)
  - `~/.triton/cache` (OpenAI Triton compiled GPU kernels)
  - `~/.cache/mlx` (Apple MLX framework cache)
  - `~/.cache/whisper` (OpenAI Whisper speech-to-text model checkpoints)
  - `~/.cache/clip` (CLIP vision model weights)
  - `~/.cache/ wandering` / `~/.cache/wandb` and `~/Library/Application Support/wandb` (Weights & Biases artifact & run upload cache)
  - `~/.keras/models` and `~/.keras/datasets` (Keras/TensorFlow pretrained weights)
- **Typical Footprint:** 2–40 GB
- **Integration:** `userCaches` + `devToolRoots` + `KnownLocation` + `AutoSelectionSpec`
- **Auto-Selection:**
  - `~/.triton/cache`: **Tier 1 (`safe` — `.all`)** (compiled kernel cache).
  - `~/.cache/torch`, `~/.cache/mlx`, `~/.cache/whisper`, `~/.cache/clip`, `~/.cache/wandb`: **Tier 1 (`unusedOnly`)**, **Tier 2 (`all`)**.
- **Explanation:** Anyone running Python ML scripts, local transcription (Whisper), or Apple Silicon MLX models accumulates gigabytes of checkpoint files and compiled kernels in these exact directories. All of them re-download or recompile automatically.

---

## Priority 2 — Professional Creative, Video, Audio, 3D & Game Engines (10–500+ GB)

Creative professionals (video editors, motion designers, photographers, 3D artists, game developers) experience even worse disk bloat than software engineers, often hidden deep inside `~/Library/Application Support`.

### 12. Adobe Creative Cloud Media & Disk Caches (Premiere Pro, After Effects, Media Encoder, Camera Raw)
- **Paths:**
  - `~/Library/Application Support/Adobe/Common/Media Cache Files` (decoded audio/video `.cfa` / `.pek` files)
  - `~/Library/Application Support/Adobe/Common/Media Cache` (`.mcdb` cache database)
  - `~/Library/Application Support/Adobe/Common/Peak Files` and `PTX`
  - `~/Library/Caches/Adobe/After Effects` and `~/Library/Caches/Adobe Camera Raw` (already under `~/Library/Caches`, add `KnownLocation` explanations)
- **Typical Footprint:** 20–200+ GB
- **Integration:** `userCaches` (with `candidate: .children` so the folders stay and their contents are emptied, as After Effects/Premiere prefer the directory to remain) + `KnownLocation` + `ApplicationActivityService` guard (block while Premiere/After Effects/Media Encoder are running).
- **Auto-Selection:** **Tier 1 (`safe` — `.all`)**
- **Explanation:** Adobe stores its shared video/audio media cache inside `~/Library/Application Support/Adobe/Common/Media Cache Files` rather than `~/Library/Caches`. Because `CleanupSafety` protects `Application Support` by default, users currently *cannot* clean Adobe's media cache unless it is explicitly added to `CleanupRule.userCaches`! Adding those exact subpaths unlocks tens to hundreds of gigabytes of completely regenerable frame/audio caches while keeping presets, workspaces, and plugins in sibling Adobe folders 100% protected.

### 13. DaVinci Resolve Render Cache (`CacheClip`)
- **Paths:**
  - `~/Movies/CacheClip` and `/Volumes/*/CacheClip` (or name-matched `CacheClip` folders containing `.dvcc` render cache files)
  - `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/DiskCache` (Fusion node disk cache)
- **Typical Footprint:** 20–300+ GB
- **Integration:** `userCaches` (`Fusion/DiskCache`) + `KnownLocation` + optional `regenerableNames` (`CacheClip`)
- **Auto-Selection:**
  - `Fusion/DiskCache`: **Tier 1 (`safe` — `.all`)**
  - `CacheClip`: **Tier 2 (`regenerable`)** (Never touch `.gallery` or `Resolve Disk Database`!).
- **Explanation:** DaVinci Resolve pre-renders timeline effects and color grades into `CacheClip` (`.dvcc` files) and Fusion node caches into `Fusion/DiskCache`. Both are purely disposable render caches that Resolve regenerates on timeline playback. **Safety boundary:** Never select `.gallery` (contains color grading stills) or `Resolve Disk Database` (contains the actual user projects!).

### 14. Apple Final Cut Pro & Motion Render Files
- **Paths / Bundle Structure:**
  - Inside `.fcpbundle` libraries: `*/Render Files/High Quality Media`, `*/Render Files/Thumbnail Media`, `*/Render Files/Peaks Data` (and `Analysis Files`)
- **Typical Footprint:** 20–500 GB per video library
- **Integration:** `KnownLocation` explanation (Note: `.fcpbundle` is a macOS package bundle, so `CleanupSafety` blocks deleting internal package files unless `inspectPackages` is enabled or a dedicated bundle-cache rule is used).
- **Explanation:** Final Cut Pro libraries (`.fcpbundle`) frequently swell to hundreds of gigabytes because of `Render Files`. Highlighting and explaining `.fcpbundle` in hover cards ("Final Cut Pro Library — To reclaim render space safely, use File → Delete Generated Library Files inside Final Cut Pro") gives users honest, non-destructive guidance without risking corrupting an `.fcpbundle` SQLite database.

### 15. Unity & Unreal Engine Caches
- **Paths:**
  - `~/Library/Unity/cache` (Unity Package Manager global cache: `npm`, `packages`, `git-lfs`)
  - `~/Library/Unity/Asset Store-5.x` (downloaded `.unitypackage` archives from Unity Asset Store)
  - `~/Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache` and `~/Library/Application Support/Epic/Zen/Data` (Unreal Engine 4/5 shared local Derived Data Cache / Zen storage)
- **Typical Footprint:** 10–150 GB
- **Integration:** `userCaches` + `devToolRoots` + `KnownLocation` + `AutoSelectionSpec`
- **Auto-Selection:**
  - `~/Library/Unity/cache` and Unreal `DerivedDataCache`: **Tier 1 (`safe` — `.all`)**
  - `~/Library/Unity/Asset Store-5.x`: **Tier 2 (`regenerable`)** (re-downloadable from Asset Store).
- **Explanation:** Game engines compile thousands of shader permutations and asset formats into Derived Data Caches (DDC) and UPM caches. They are 100% disposable and regenerated from project `.uasset` / Unity source assets.

### 16. Figma, Sketch & Blender Caches
- **Paths:**
  - `~/Library/Application Support/Figma/DesktopProfile` → specifically `Cache`, `Code Cache`, `GPUCache` (Electron Chromium caches inside Application Support)
  - `~/Library/Application Support/Blender/*/cache` (fluid/smoke/cloth simulation caches and Cycles/EEVEE shader caches)
- **Typical Footprint:** 2–15 GB
- **Integration:** `userCaches` + `KnownLocation`
- **Auto-Selection:** **Tier 1 (`safe` — `.all`)**

---

## Priority 3 — Browsers/Testing Automation, IDEs, Containers & VMs (5–80 GB)

### 17. Automated Browser Binaries (Playwright, Puppeteer, Cypress, Selenium)
- **Paths:**
  - `~/Library/Caches/ms-playwright` and `~/.cache/ms-playwright` (Playwright Chromium/Firefox/WebKit builds — ~1.5 GB per version)
  - `~/.cache/puppeteer` (Puppeteer downloaded Chrome-for-Testing builds)
  - `~/Library/Caches/Cypress` (Cypress versioned Electron/browser bundles)
  - `~/.cache/selenium` (Selenium Manager driver & browser cache)
- **Typical Footprint:** 3–25 GB
- **Integration:** `userCaches` + `devToolRoots` + `KnownLocation` + `AutoSelectionSpec`
- **Auto-Selection:**
  - **Tier 1 (`previousVersions(keep: 1)`)**: Every Playwright/Cypress/Puppeteer upgrade downloads a brand-new 1–2 GB browser bundle and leaves every older version behind forever. Keeping the single newest version in Tier 1 and selecting all versions in Tier 2 (`regenerable`) is a huge, frictionless win.

### 18. VS Code, Cursor & Windsurf Caches in `Application Support`
- **Paths:**
  - For each editor root in `~/Library/Application Support/{Code, Code - Insiders, Cursor, Windsurf}`:
    - `Cache`
    - `CachedData` (V8 bytecode cache)
    - `CachedExtensionVSIXs` (downloaded `.vsix` installers)
    - `Code Cache`
    - `GPUCache`
    - `Service Worker/CacheStorage`
    - `logs`
- **Typical Footprint:** 2–15 GB across editors
- **Integration:** `userCaches` + `KnownLocation` + `ApplicationActivityService` (block while the matching editor is running)
- **Auto-Selection:** **Tier 1 (`safe` — `.all`)**
- **Explanation:** DiskUnbloat currently has 3 paths hardcoded only for `Code - Insiders` (`WebStorage`, `agent-host/sdk-cache`, `CachedExtensionVSIXs`), missing stable VS Code (`Code`), `Cursor`, and `Windsurf`, as well as `CachedData` and `CachedExtensionVSIXs` across them. Adding these exact cache subfolders (while leaving `User/settings.json`, `User/globalStorage`, and `User/workspaceStorage` strictly protected!) makes editor cleanup comprehensive and safe.

### 19. Container & Linux VM Runtimes (OrbStack, Colima, Lima, Podman, Minikube)
- **Paths:**
  - `~/.orbstack` (OrbStack sparse VM image & container data)
  - `~/.colima` and `~/.lima` (Colima / Lima `diffdisk` qcow2 VM images)
  - `~/.local/share/containers/podman` (Podman Machine VM disk images)
  - `~/.minikube` (Minikube Kubernetes cluster VM/container images & cache; `~/.minikube/cache` is pure download cache)
- **Typical Footprint:** 10–100 GB
- **Integration:** `devToolRoots` + `KnownLocation` (plus `~/.minikube/cache` in `userCaches` / Tier 1)
- **Auto-Selection:** **Scan & Explain Only** for the VM disks (just like Docker, Parallels, and UTM today — never auto-selected because deleting a VM disk destroys container volumes and databases). `~/.minikube/cache` (downloaded ISO/tarballs) can be **Tier 2 (`regenerable`)**.
- **Explanation:** Many macOS developers have migrated from Docker Desktop to OrbStack, Colima/Lima, or Podman. Adding them to `devToolRoots` and `KnownLocation` gives **Dev tools** complete visibility over container runtimes.

### 20. Cloud, Infrastructure & Polyglot Build Caches (Terraform, Bazel, CCache, CocoaPods, Composer, NuGet, Dart Pub)
- **Paths:**
  - `~/.terraform.d/plugin-cache` (Terraform / OpenTofu provider binary cache — each provider is 100–500 MB)
  - `/private/var/tmp/_bazel_<username>` and `~/.cache/bazel` (Bazel build outputs & repository cache)
  - `~/Library/Caches/ccache`, `~/.ccache`, and `~/.cache/sccache` (C/C++/Rust compiler object caches)
  - `~/.nuget/packages` (.NET NuGet global packages folder)
  - `~/.pub-cache` (Dart / Flutter package cache)
  - `~/.composer/cache` and `~/Library/Caches/composer` (PHP Composer archive cache)
  - `~/.bundle/cache` (Ruby Bundler gem cache)
  - `~/Library/Caches/CocoaPods` and `~/.cocoapods/repos` (CocoaPods spec repos & pod tarballs)
  - `~/Library/Caches/Carthage` (Carthage dependency build cache)
- **Typical Footprint:** 2–40 GB
- **Integration:** `userCaches` + `devToolRoots` + `KnownLocation` + `AutoSelectionSpec`
- **Auto-Selection:**
  - `ccache`, `sccache`, `composer/cache`, `bundle/cache`, `CocoaPods`, `Carthage`, `.terraform.d/plugin-cache`: **Tier 1 (`safe` — `.all`)**
  - `~/.nuget/packages`, `~/.pub-cache`: **Tier 2 (`regenerable`)**

---

## Priority 4 — Project-Local Rebuildable Directory Names (`CleanupRule.regenerableNames`)

Currently `CleanupRule.regenerableNames` only matches 7 names:
`["node_modules", "Pods", "DerivedData", ".cache", ".artifacts", ".build", ".build-cache"]`.

Expanding this list allows the **Rebuildable** filter and **Tier 2 (`Select rebuildable items`)** to find gigabytes of stale build outputs and local environments across any scanned project folder.

### 21. High-Confidence Project Build & Cache Directories (Zero Ambiguity)
These directory names are exclusively generated by compilers, bundlers, linters, or test runners and never hold hand-written source files:

| Directory Name | Ecosystem / Tool | What It Holds & Why It's Rebuildable |
| :--- | :--- | :--- |
| `.next` | Next.js | Webpack/Turbopack build cache and server/client bundles (often 0.5–5 GB per project). Rebuilt by `next dev` / `next build`. |
| `.nuxt` / `.output` | Nuxt (Vue) | Generated Nuxt build & Nitro server output. Rebuilt by `nuxt build`. |
| `.svelte-kit` | SvelteKit | Generated route types and Vite build intermediates. |
| `.astro` | Astro | Content layer and Vite build cache. |
| `.angular` | Angular CLI | Angular persistent disk build cache (`.angular/cache`). |
| `.turbo` | Turborepo | Local monorepo task execution cache. |
| `.parcel-cache` | Parcel | Parcel bundler transformation cache. |
| `.vite` | Vite | Pre-bundled dependency chunks. |
| `.docusaurus` | Docusaurus | Static site generator build cache. |
| `__pycache__` | Python | Compiled `.pyc` bytecode files. |
| `.pytest_cache` | Python (pytest) | Test runner state and assertion cache. |
| `.mypy_cache` | Python (mypy) | Static type-checker incremental cache. |
| `.ruff_cache` | Python (Ruff) | Linter/formatter cache. |
| `.tox` / `.nox` | Python (tox/nox) | Ephemeral test virtual environments (often 500 MB–3 GB). |
| `.dart_tool` | Dart / Flutter | Dart build system cache, package config, and codegen intermediates. |
| `.gradle` | Gradle (project-local) | Project-specific task history and configuration cache. |
| `zig-cache` / `.zig-cache` / `zig-out` | Zig | Zig compiler incremental artifact cache and build output. |
| `cmake-build-debug` / `cmake-build-release` | CMake / CLion | Out-of-source C/C++ build trees created by CLion and CMake presets. |
| `.serverless` | Serverless Framework | Packaged deployment zip artifacts. |
| `.terragrunt-cache` | Terragrunt | Cloned Terraform modules and provider copies (notoriously huge). |

### 22. Context-Aware Project Directories (High Yield, Needs Sibling Marker or Tier 2 Care)
These folders are often the single biggest project bloat (5–30 GB per repo), but because generic names like `target` or `build` could occasionally be used as a normal folder name outside a project, they are best matched either in **Tier 2 (`regenerable`)** or verified by a sibling manifest file:

| Directory Name | Sibling Marker (if checked) | Ecosystem | Typical Size & Explanation |
| :--- | :--- | :--- | :--- |
| `target` | `Cargo.toml` or `pom.xml` | Rust / Maven | Rust's `target/` directory easily hits **5–30 GB per project** due to debug symbols and incremental rlibs. Rebuilt via `cargo build`. |
| `.venv` / `venv` | `pyproject.toml` or `requirements.txt` | Python | Local Python virtual environments (0.5–8 GB each when PyTorch/SciPy are installed). Recreated via `uv sync` / `pip install`. |
| `Carthage/Build` | `Cartfile` | iOS / macOS | Prebuilt Carthage frameworks. |
| `DerivedDataCache` / `Intermediate` | `*.uproject` | Unreal Engine | Per-project compiled shaders and C++ intermediates (often 10–50 GB). |
| `Library` | `ProjectSettings` & `Assets` | Unity | Unity's local imported asset cache (rebuilt automatically on project open; warning: generic name `Library` must **only** match when `Assets` & `ProjectSettings` are siblings, never `~/Library`!). |

---

## Priority 5 — Guardrails & Traps: Locations That Must Be Protected or Handled Carefully

Researching competitor tools and macOS developer setups reveals several dangerous traps where naive cleaners cause data loss. DiskUnbloat should **explicitly avoid** auto-selecting these (or use `eligibleChildNames` / hover explanations only):

1. **`~/Library/Developer/Xcode/Archives`:**
   - **Why it's a trap:** Contains signed `.xcarchive` bundles and `.dSYM` debug symbols for App Store releases. Deleting an archive for a shipped version makes crash symbolication impossible unless backed up elsewhere.
   - **Recommendation:** Include in `devToolRoots` and `KnownLocation` so users can see and manually clean old archives on the map, but **never** include in Tier 1 or Tier 2 auto-selection.
2. **`~/.claude`, `~/.codex`, `~/.cursor` root folders:**
   - **Why it's a trap:** `~/.claude/projects` and `~/.codex/sessions` contain the user's conversation transcripts, custom slash commands, `CLAUDE.md` memory, and MCP configurations.
   - **Recommendation:** Never auto-select agent roots. Only pure cache directories like `~/Library/Caches/claude-cli-nodejs` belong in cache cleanup.
3. **`~/.cargo/bin` and `~/.bun/bin`:**
   - **Why it's a trap:** Sit inside `~/.cargo` and `~/.bun` alongside gigabytes of cache, but hold user-installed executables.
   - **Recommendation:** Always target `~/.cargo/registry`, `~/.cargo/git`, and `~/.bun/install/cache` specifically.
4. **DaVinci Resolve `Resolve Disk Database` & `.gallery`, Lightroom `*.lrcat`:**
   - **Why it's a trap:** `Resolve Disk Database` is the user's actual video editing projects database; `.lrcat` is the Lightroom photo catalog and edit history.
   - **Recommendation:** Only target `CacheClip`, `Fusion/DiskCache`, and `Adobe Camera Raw` cache; keep databases protected under `CleanupSafety.isManagedData`.
5. **Telegram Desktop / Messenger Group Containers:**
   - **Note:** DiskUnbloat already lists `~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram`. Note that deleting the entire group container logs the user out of Telegram Desktop, whereas targeting `.../stable/account-*/postbox/media` only clears downloaded media cache while keeping the session alive. Refining this path in a future pass is a great UX improvement.

---

## Recommended Implementation Roadmap

1. **Phase A — Safe Caches & Xcode/Browser/Editor Completion (Low Risk, Immediate High Value) — ✅ SHIPPED 2026-11-02**:
   - ✅ Xcode `CoreSimulator/Caches` (rootItself), `UserData/Previews/Simulator Devices` (children), `XCTestDevices` (children), and `watchOS`/`tvOS`/`visionOS DeviceSupport` (`childrenKeepingNewest`, tier 1 keeps one version).
   - ✅ Cargo (`~/.cargo/registry/cache`, `~/.cargo/registry/src`, `~/.cargo/git/checkouts`, `~/.cargo/git/db` as `rootItself`; `~/.cargo/bin` never listed), Bun (`~/.bun/install/cache`, `rootItself`; `~/.bun/bin` never listed).
   - ✅ Gradle wrapper (`~/.gradle/wrapper/dists`, `childrenKeepingNewest`, tier 1 keeps the newest distribution).
   - ✅ Playwright (`~/Library/Caches/ms-playwright`) via a new `Tier1Coverage.previousVersionsPerFamily(keep: 1)` — one kept build per browser (`chromium-1148` family = `chromium`), because a flat keep-newest would delete whole browser families; Cypress (`~/Library/Caches/Cypress`) with plain `previousVersions(keep: 1)`.
   - ✅ VS Code / Code - Insiders / Cursor / Windsurf `Cache`, `CachedData`, `CachedExtensionVSIXs`, `GPUCache` (rootItself; the editors' `User/` settings trees stay protected), with running-app guards keyed by bundle ID (`com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92`, `com.exafunction.windsurf`) using segmented owner matching.
   - ✅ Adobe `Common/Media Cache Files` + `Common/Media Cache` in `CleanupRule.userCaches` (children), blocked by the app-activity guard while Premiere (`com.adobe.Premiere.Pro`), After Effects (`com.adobe.AfterEffects`), Media Encoder (`com.adobe.mediaencoder.*`, including background queue runs), or Audition are running.
   - ⏸ **Deferred: Puppeteer** (`~/.cache/puppeteer`) — its layout is two-level (`<browser>/<platform-version>` subfolders), which does not fit the current one-level rule model. A flat keep-newest over `~/.cache/puppeteer`'s direct children would keep exactly one browser family and delete every other family outright (e.g. keep `chrome`, lose all of `firefox`), and per-browser roots would multiply scan-issue noise for users without those families. Revisit together with a two-level descent rule, ideally alongside Phase B.
2. **Phase B — AI/ML & Language Store Completion — ✅ SHIPPED 2026-11-02:**
   - ✅ `~/.lmstudio` (modern store) with `eligibleChildNames: ["models", "hub", ".internal"]` as a tier-1 `unusedOnly` rule, mirroring the legacy `.cache/lm-studio` precedent; the legacy rule stays.
   - ✅ AutoSelectionSpec rules: `~/.cache/huggingface` (`hub`, `datasets` eligible, tokens excluded; tier 1 `unusedOnly`, tier 2 full), `~/.cache/huggingface/xet` (tier 1 `.all`), `~/.cache/torch` (`hub`/`inductor` eligible, tier 1 `unusedOnly`), `~/.cache/mlx` and `~/.cache/whisper` (tier 1 `unusedOnly`), `~/.triton/cache` (tier 1 `.all`).
   - ✅ Go: tier 1 clears `~/go/pkg/mod/cache` (location itself); tier 2 additionally takes every extracted module tree under `~/go/pkg/mod` (the queue's topmost-only normalization folds the nested cache).
   - ✅ Tier-2-only package stores: pnpm (`~/Library/pnpm/store`, `~/.local/share/pnpm/store`, legacy `~/.pnpm-store`), NuGet (`~/.nuget/packages`), Dart (`~/.pub-cache`) — never in tier 1.
   - ✅ Maven `~/.m2/repository` stays scan-only (devToolRoots + KnownLocation, no rule).
   - ✅ OrbStack (`~/.orbstack`), Colima (`~/.colima`), Lima (`~/.lima`), and Podman (`~/.local/share/containers`) join `devToolRoots` + `KnownLocation` as scan-explain-only (VM disks are real container data, never auto-selected, matching the Docker/Parallels/UTM precedent). `~/.minikube` is intentionally omitted per the roadmap's Phase B list.
3. **Phase C — Project-Local `regenerableNames` Expansion:**
   - Expand `CleanupRule.regenerableNames` with the 20 unambiguous build/cache directory names (`.next`, `.nuxt`, `.svelte-kit`, `.astro`, `.angular`, `.turbo`, `.parcel-cache`, `.vite`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `.dart_tool`, `.gradle`, `.zig-cache`, `zig-cache`, `.terragrunt-cache`, etc.).
