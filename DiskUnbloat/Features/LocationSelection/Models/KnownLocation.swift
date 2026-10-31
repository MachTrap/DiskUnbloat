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
            entry("coreSimulator", "Library/Developer/CoreSimulator/Devices", "iOS simulators", "Simulator device data. Removing it deletes simulator contents and requires recreating devices."),
            entry("uvCache", ".cache/uv", "uv cache", "Cached Python packages and wheels downloaded by uv. Future installs may need the network."),
            entry("uvArchive", ".cache/uv/archive-v0", "uv package archive", "Unpacked package archives kept by uv for faster installs. Safe to remove; uv re-downloads them."),
            entry("npmCache", ".npm/_cacache", "npm cache", "Cached npm packages and metadata. Future installs may require network access."),
            entry("npmContent", ".npm/_cacache/content-v2", "npm cache contents", "Stored package tarballs inside the npm cache. Removing them forces re-downloading."),
            entry("gradleCaches", ".gradle/caches", "Gradle caches", "Cached Gradle dependencies and build data. Builds may need to download them again."),
            entry("vscodeWebStorage", "Library/Application Support/Code - Insiders/WebStorage", "VS Code Insiders web storage", "Cached web content for VS Code Insiders extensions. Can be rebuilt by the editor."),
            entry("vscodeSdkCache", "Library/Application Support/Code - Insiders/agent-host/sdk-cache", "VS Code Insiders SDK cache", "Cached SDK data used by VS Code Insiders. Safe to remove; it is regenerated."),
            entry("vscodeExtensions", "Library/Application Support/Code - Insiders/CachedExtensionVSIXs", "Cached extension packages", "Downloaded VS Code extension packages. Reinstalling extensions re-downloads them."),
            entry("chromeModel", "Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", "Chrome on-device AI model", "On-device AI model files used by Chrome. Removing them may disable AI features until re-downloaded."),
            entry("telegramCache", "Library/Caches/ru.keepcoder.Telegram", "Telegram cache", "Cached Telegram media and data. Removal may require re-downloading media."),
            entry("telegramStable", "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable", "Telegram stable data", "Telegram container data including caches. Review before removing."),
            entry("dockerData", "Library/Containers/com.docker.docker", "Docker data", "Docker images, containers, and volumes. Removal deletes Docker data."),
            entry("androidAvd", ".android/avd", "Android emulators", "Android Virtual Device images and data."),
            entry("parallels", "Parallels", "Parallels virtual machines", "Parallels VM disk images. Large; removal deletes those machines."),
            entry("utm", "Library/Containers/com.utmapp.UTM", "UTM virtual machines", "UTM VM data and disk images."),
            entry("ollama", ".ollama", "Ollama models", "Downloaded local AI models. Removal requires re-pulling them."),
            entry("huggingface", ".cache/huggingface", "Hugging Face cache", "Cached models and datasets. Removal requires re-downloading."),
            entry("lmStudio", ".cache/lm-studio", "LM Studio models", "Local AI model files used by LM Studio.")
        ]
    }

    var knownCacheLocations: [KnownLocation] { knownLocations }
    var locationExplanations: [KnownLocation] { knownLocations }
    var explanations: [KnownLocation] { knownLocations }

    func knownLocation(for path: String) -> KnownLocation? {
        knownLocations.first { path.isWithin($0.url.path) }
    }
}
