import Foundation

/// A curated cache or tool-data location with a short human-readable explanation.
/// These entries are shown in the location chooser and in the inspector so users
/// can understand folders whose names are not self-explanatory.
struct KnownLocation: Identifiable, Equatable {
    let id: String
    let url: URL
    let title: String
    let explanation: String
}

extension LocationCatalog {
    /// Curated locations with explanations. Paths are resolved against the real home folder.
    var knownLocations: [KnownLocation] {
        let home = self.home
        func entry(_ id: String, _ relativePath: String, _ title: String, _ explanation: String) -> KnownLocation {
            KnownLocation(id: id, url: home.appendingPathComponent(relativePath), title: L10n.text(title), explanation: L10n.text(explanation))
        }
        return [
            entry("userCaches", "Library/Caches", "User caches", "Temporary application data. Removing it can disrupt apps or require downloads."),
            entry("xcodeDerivedData", "Library/Developer/Xcode/DerivedData", "Xcode Derived Data", "Build intermediates produced by Xcode. Removal requires rebuilding your projects."),
            entry("xcodeDeviceSupport", "Library/Developer/Xcode/iOS DeviceSupport", "Xcode device support", "Debug symbols for connected iOS devices. They can be re-downloaded when needed."),
            entry("watchOSDeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport", "Xcode watchOS device support", "Debug symbols for connected watchOS devices. They can be re-downloaded when needed."),
            entry("tvOSDeviceSupport", "Library/Developer/Xcode/tvOS DeviceSupport", "Xcode tvOS device support", "Debug symbols for connected tvOS devices. They can be re-downloaded when needed."),
            entry("visionOSDeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport", "Xcode visionOS device support", "Debug symbols for connected visionOS devices. They can be re-downloaded when needed."),
            entry("coreSimulator", "Library/Developer/CoreSimulator/Devices", "iOS simulators", "Simulator device data. Removing it deletes simulator contents and requires recreating devices."),
            entry("simulatorCaches", "Library/Developer/CoreSimulator/Caches", "Simulator cache", "System caches built for simulator runtimes. They are rebuilt when simulators run again."),
            entry("previewsCache", "Library/Developer/Xcode/UserData/Previews/Simulator Devices", "SwiftUI preview simulators", "Simulator devices created for Xcode SwiftUI previews. They are recreated when previews run."),
            entry("xctestDevices", "Library/Developer/XCTestDevices", "Xcode test devices", "Simulator clones left behind by parallel test runs. Removing them frees spent test devices."),
            entry("uvCache", ".cache/uv", "uv cache", "Cached Python packages and wheels downloaded by uv. Future installs may need the network."),
            entry("uvArchive", ".cache/uv/archive-v0", "uv package archive", "Unpacked package archives kept by uv for faster installs. Safe to remove; uv re-downloads them."),
            entry("npmCache", ".npm/_cacache", "npm cache", "Cached npm packages and metadata. Future installs may require network access."),
            entry("npmContent", ".npm/_cacache/content-v2", "npm cache contents", "Stored package tarballs inside the npm cache. Removing them forces re-downloading."),
            entry("gradleCaches", ".gradle/caches", "Gradle caches", "Cached Gradle dependencies and build data. Builds may need to download them again."),
            entry("gradleWrapper", ".gradle/wrapper/dists", "Gradle distributions", "Full Gradle installations downloaded by project wrappers. Old versions are removed and re-downloaded on demand."),
            entry("cargoRegistryCache", ".cargo/registry/cache", "Cargo registry cache", "Downloaded .crate archives of Rust dependencies. Cargo re-downloads what a build needs."),
            entry("cargoRegistrySrc", ".cargo/registry/src", "Cargo crate sources", "Unpacked Rust dependency sources kept for builds. Cargo restores them from the cache or re-downloads them."),
            entry("cargoGitCheckouts", ".cargo/git/checkouts", "Cargo git checkouts", "Checked-out copies of Rust git dependencies. Cargo re-clones them when a build needs them."),
            entry("cargoGitDb", ".cargo/git/db", "Cargo git database", "Raw git repositories downloaded for Rust dependencies. Cargo re-fetches them when a build needs them."),
            entry("bunCache", ".bun/install/cache", "Bun package cache", "Cached npm package files used by Bun. Installing again re-downloads what is missing."),
            entry("playwrightCache", "Library/Caches/ms-playwright", "Playwright browsers", "Automation browser builds downloaded by Playwright. Tests re-download the version they need."),
            entry("cypressCache", "Library/Caches/Cypress", "Cypress binary", "Cypress's versioned application bundle. Old versions are removed and re-downloaded on demand."),
            entry("vscodeWebCache", "Library/Application Support/Code - Insiders/Cache", "VS Code Insiders web cache", "The editor's Chromium web cache. Removed entries are rebuilt as needed."),
            entry("vscodeCachedData", "Library/Application Support/Code - Insiders/CachedData", "VS Code Insiders compiled cache", "Cached compiled code used for faster startup. The editor rebuilds it."),
            entry("vscodeGPU", "Library/Application Support/Code - Insiders/GPUCache", "VS Code Insiders GPU cache", "Cached GPU shader data. The editor rebuilds it."),
            entry("vscodeWebStorage", "Library/Application Support/Code - Insiders/WebStorage", "VS Code Insiders web storage", "Cached web content for VS Code Insiders extensions. Can be rebuilt by the editor."),
            entry("vscodeSdkCache", "Library/Application Support/Code - Insiders/agent-host/sdk-cache", "VS Code Insiders SDK cache", "Cached SDK data used by VS Code Insiders. Safe to remove; it is regenerated."),
            entry("vscodeExtensions", "Library/Application Support/Code - Insiders/CachedExtensionVSIXs", "Cached extension packages", "Downloaded VS Code extension packages. Reinstalling extensions re-downloads them."),
            entry("codeWebCache", "Library/Application Support/Code/Cache", "VS Code web cache", "The editor's Chromium web cache. Removed entries are rebuilt as needed."),
            entry("codeCachedData", "Library/Application Support/Code/CachedData", "VS Code compiled cache", "Cached compiled code used for faster startup. The editor rebuilds it."),
            entry("codeGPU", "Library/Application Support/Code/GPUCache", "VS Code GPU cache", "Cached GPU shader data. The editor rebuilds it."),
            entry("codeExtensions", "Library/Application Support/Code/CachedExtensionVSIXs", "Cached extension packages", "Downloaded VS Code extension packages. Reinstalling extensions re-downloads them."),
            entry("cursorWebCache", "Library/Application Support/Cursor/Cache", "Cursor web cache", "The editor's Chromium web cache. Removed entries are rebuilt as needed."),
            entry("cursorCachedData", "Library/Application Support/Cursor/CachedData", "Cursor compiled cache", "Cached compiled code used for faster startup. The editor rebuilds it."),
            entry("cursorGPU", "Library/Application Support/Cursor/GPUCache", "Cursor GPU cache", "Cached GPU shader data. The editor rebuilds it."),
            entry("cursorExtensions", "Library/Application Support/Cursor/CachedExtensionVSIXs", "Cached extension packages", "Downloaded extension packages. Reinstalling extensions re-downloads them."),
            entry("windsurfWebCache", "Library/Application Support/Windsurf/Cache", "Windsurf web cache", "The editor's Chromium web cache. Removed entries are rebuilt as needed."),
            entry("windsurfCachedData", "Library/Application Support/Windsurf/CachedData", "Windsurf compiled cache", "Cached compiled code used for faster startup. The editor rebuilds it."),
            entry("windsurfGPU", "Library/Application Support/Windsurf/GPUCache", "Windsurf GPU cache", "Cached GPU shader data. The editor rebuilds it."),
            entry("windsurfExtensions", "Library/Application Support/Windsurf/CachedExtensionVSIXs", "Cached extension packages", "Downloaded extension packages. Reinstalling extensions re-downloads them."),
            entry("adobeMediaCacheFiles", "Library/Application Support/Adobe/Common/Media Cache Files", "Adobe media cache", "Conformed audio and video previews written by Premiere Pro, After Effects, and Media Encoder. Projects recreate them when they reopen."),
            entry("adobeMediaCache", "Library/Application Support/Adobe/Common/Media Cache", "Adobe media cache database", "Adobe's database of media cache entries. It is rebuilt when apps work with media again."),
            entry("chromeModel", "Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", "Chrome on-device AI model", "On-device AI model files used by Chrome. Removing them may disable AI features until re-downloaded."),
            entry("telegramCache", "Library/Caches/ru.keepcoder.Telegram", "Telegram cache", "Cached Telegram media and data. Removal may require re-downloading media."),
            entry("telegramStable", "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable", "Telegram stable data", "Telegram container data including caches. Review before removing."),
            entry("dockerData", "Library/Containers/com.docker.docker", "Docker data", "Docker images, containers, and volumes. Removal deletes Docker data."),
            entry("androidAvd", ".android/avd", "Android emulators", "Android Virtual Device images and data."),
            entry("parallels", "Parallels", "Parallels virtual machines", "Parallels VM disk images. Large; removal deletes those machines."),
            entry("utm", "Library/Containers/com.utmapp.UTM", "UTM virtual machines", "UTM VM data and disk images."),
            entry("ollama", ".ollama", "Ollama models", "Downloaded local AI models. Removal requires re-pulling them."),
            entry("huggingface", ".cache/huggingface", "Hugging Face cache", "Cached models and datasets. Removal requires re-downloading."),
            entry("lmStudio", ".cache/lm-studio", "LM Studio models", "Local AI model files used by LM Studio."),
            entry("lmStudioModern", ".lmstudio", "LM Studio (modern store)", "LM Studio's newer store: models, hub, and internal caches beside chats and presets. Only the regenerable parts are ever cleaned."),
            entry("goModules", "go/pkg/mod", "Go module cache", "Downloaded and extracted Go module versions. Builds re-fetch what they need; files inside are flagged read-only."),
            entry("pnpmStore", "Library/pnpm/store", "pnpm store", "pnpm's central package store hard-linked into projects. Active projects keep their links; future installs re-download missing packages."),
            entry("mavenRepository", ".m2/repository", "Maven repository", "Local Maven artifacts, including jars your own builds installed. Dependencies re-download when missing; local snapshots need rebuilding."),
            entry("nugetPackages", ".nuget/packages", "NuGet packages", "Global NuGet package folders. Restores re-download them from the configured sources."),
            entry("pubCache", ".pub-cache", "Dart package cache", "Downloaded Dart and Flutter packages. Future pub get runs re-fetch them."),
            entry("torchCache", ".cache/torch", "PyTorch cache", "PyTorch Hub checkpoints and compiled kernel caches. Re-downloaded or recompiled on demand."),
            entry("mlxCache", ".cache/mlx", "MLX cache", "Cached Apple MLX model files. Removed models re-download when used again."),
            entry("whisperCache", ".cache/whisper", "Whisper models", "Whisper speech-to-text model checkpoints. They re-download on demand."),
            entry("tritonCache", ".triton/cache", "Triton cache", "Compiled GPU kernel cache. Kernels recompile when needed."),
            entry("orbstack", ".orbstack", "OrbStack data", "OrbStack's VM image, containers, and volumes. Removal deletes container data."),
            entry("colima", ".colima", "Colima machine", "Colima's VM disk images. Removal deletes container data on that machine."),
            entry("lima", ".lima", "Lima VMs", "Lima Linux VM disk images. Removal deletes those machines."),
            entry("podman", ".local/share/containers", "Podman data", "Podman containers, volumes, and machine images. Removal deletes container data."),
            entry("minikube", ".minikube", "Minikube cluster", "Minikube's Kubernetes cluster VM, node data, and image caches. Removal deletes the cluster; the download caches alone rebuild on demand.")
        ]
    }

    var knownCacheLocations: [KnownLocation] { knownLocations }
    var locationExplanations: [KnownLocation] { knownLocations }
    var explanations: [KnownLocation] { knownLocations }

    func knownLocation(for path: String) -> KnownLocation? {
        knownLocations.first { path.isWithin($0.url.path) }
    }
}
